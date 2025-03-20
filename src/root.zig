//! An extension to std.zip that includes a zip file writer.
//! Based on a test fixture in std.zip.
const std = @import("std");
const io = std.io;
const File = std.fs.File;
const StreamSource = std.io.StreamSource;
const zip = std.zip;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const flate = std.compress.flate;
const zeit = @import("zeit");

const log = std.log.scoped(.zipper);

const zip_version = 10;

/// Metadata from file writing for use in a central directory record.
pub const FileStore = struct {
    name: []const u8,
    compression: zip.CompressionMethod,
    file_offset: u32,
    crc32: u32,
    compressed_size: u32,
    uncompressed_size: u32,
};

/// WIP
const MsDosDateTime = packed struct {
    /// Day of the month (1-31)
    day_of_month: u5,
    /// Month (1 = Jan, 2 = Feb, so on)
    month: u4,
    /// Year offset from 1980.
    year_offset: u7,
};

/// Helper struct to write .zip data into a std.io.StreamSource.
const Zipper = struct {
    source: StreamSource,
    central_count: u64 = 0,
    first_central_offset: ?u64 = null,

    const Self = @This();

    pub fn init(source: StreamSource) Self {
        return .{
            .source = source,
        };
    }

    pub const WriteFileError =
        error{
            InvalidCompressionMethod,
            InputFileTooBig,
            FileNameTooBig,
            UnfinishedBits,
            OffsetTooLarge,
            /// The CD writing phase already began, cannot write another file.
            FilePhaseOver,
        } || StreamSource.ReadError || StreamSource.SeekError || StreamSource.GetSeekPosError || StreamSource.WriteError;

    /// Writes a file to the zip archive.
    /// Errors out if the end record or cd records have been written.
    pub fn writeFile(
        self: *Self,
        opts: struct {
            name: []const u8,
            content: *StreamSource,
            compression: zip.CompressionMethod,
        },
    ) WriteFileError!FileStore {
        if (self.first_central_offset != null) {
            return error.FilePhaseOver;
        }

        const file_offset = try self.source.getPos();
        var writer = io.bufferedWriter(self.source.writer());
        // We'll write the real local file header later.
        const dummy_header = std.mem.zeroInit(zip.LocalFileHeader, .{});
        try writer.writer().writeStructEndian(dummy_header, .little);
        try writer.writer().writeAll(opts.name);
        try writer.flush();

        // these io objects are scoped in just for the file
        var counting_writer = io.countingWriter(writer);
        var buf_reader = io.bufferedReader(opts.content.reader());
        var counting_reader = io.countingReader(buf_reader.reader());
        var hash_state: std.hash.Crc32 = .init();

        switch (opts.compression) {
            .store => {
                while (counting_reader.reader().readBoundedBytes(4096)) |buf| {
                    if (buf.len == 0) break;

                    hash_state.update(buf.slice());

                    try counting_writer.writer().writeAll(buf.constSlice());
                } else |err| return err;
            },
            .deflate => {
                var compressor = try flate.deflate.compressor(.raw, counting_writer.writer(), .{});
                while (counting_reader.reader().readBoundedBytes(4096)) |buf| {
                    if (buf.len == 0) break;

                    hash_state.update(buf.slice());

                    try compressor.writer().writeAll(buf.constSlice());
                } else |err| return err;
                try compressor.finish();
            },
            else => return error.InvalidCompressionMethod,
        }

        // Now we have enough information to write a file header.
        try counting_writer.child_stream.flush();
        const end_of_file_data = try self.source.getPos();
        try self.source.seekTo(file_offset);

        const cast = std.math.cast;
        const compressed_size = cast(u32, counting_writer.bytes_written) orelse return error.InputFileTooBig;
        const uncompressed_size = cast(u32, counting_reader.bytes_read) orelse return error.InputFileTooBig;
        const filename_len = cast(u16, opts.name.len) orelse return error.FileNameTooBig;
        const crc32 = hash_state.final();
        const hdr: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = zip_version,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = opts.compression,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .crc32 = crc32,
            .extra_len = 0,
            .filename_len = filename_len,
        };

        try writer.writer().writeStructEndian(hdr, .little);
        try writer.flush();
        try self.source.seekTo(end_of_file_data);

        const small_file_offset = cast(u32, file_offset) orelse return error.OffsetTooLarge;

        return .{
            .name = opts.name,
            .compression = opts.compression,
            .file_offset = small_file_offset,
            .crc32 = crc32,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
        };
    }

    pub const WriteCompressedDataError = error{
        FilePhaseOver,
    } || StreamSource.GetSeekPosError || StreamSource.WriteError;

    ///
    pub fn writeCompressedData(
        self: *Self,
        content: anytype,
        opts: struct {
            name: []const u8,
            crc32: u32,
            uncompressed_size: u32,
        },
    ) (WriteCompressedDataError || @TypeOf(content).Error)!FileStore {
        if (self.first_central_offset != null) {
            return error.FilePhaseOver;
        }

        var writer = io.bufferedWriter(self.source.writer());

        const file_offset = try self.source.getPos();
        const dummy_header = std.mem.zeroInit(zip.LocalFileHeader, .{});
        try writer.writer().writeStructEndian(dummy_header, .little);
        try writer.writer().writeAll(opts.name);
        try writer.flush();

        // TODO: Add hash validation?
        const compressed_size = compressed_size: {
            var counting_reader = io.countingReader(content);
            const LinearFifo = std.fifo.LinearFifo;
            var fifo: LinearFifo(u8, .{ .Static = 4096 }) = .init();
            try fifo.pump(&counting_reader, &writer);
            try writer.flush();
            break :compressed_size std.math.cast(u32, counting_reader.bytes_read) orelse return error.FileTooLarge;
        };
        const end_of_data = try self.source.getPos();

        // Now to write the real header
        const cast = std.math.cast;
        const filename_len = cast(u16, opts.name.len) orelse return error.FileNameTooBig;
        const hdr: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = zip_version,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = opts.compression,
            .last_modification_time = 0,
            .last_modification_date = 0,
            .compressed_size = compressed_size,
            .uncompressed_size = opts.uncompressed_size,
            .crc32 = opts.crc32,
            .extra_len = 0,
            .filename_len = filename_len,
        };

        try self.source.seekTo(file_offset);
        try writer.writer().writeStructEndian(hdr, .little);
        try writer.flush();
        try self.source.seekTo(end_of_data);
    }

    pub const WriteCentralRecordError = error{
        CdOffsetOverflow,
    } || StreamSource.WriteError || StreamSource.GetSeekPosError;

    /// Writes a central directory record to the zip file.
    /// Prevents more files from being written to the zip after first call.
    pub fn writeCentralRecord(
        self: *Self,
        store: FileStore,
    ) WriteCentralRecordError!void {
        var writer = io.bufferedWriter(self.source.writer());

        try self.setCdOffset();
        try self.writeCentralRecordInner(store, &writer);
        try writer.flush();
    }

    /// Writes all given FileStores as CD records to the zip file.
    /// Has slightly better buffering than writeCentralRecord.
    pub fn writeAllCentralRecords(
        self: *Self,
        stores: []const FileStore,
    ) WriteCentralRecordError!void {
        var writer = io.bufferedWriter(self.source.writer());

        if (stores.len > 0) try self.setCdOffset();
        for (stores) |store| {
            try self.writeCentralRecordInner(store, &writer);
        }

        try writer.flush();
    }

    fn setCdOffset(self: *Self) StreamSource.GetSeekPosError!void {
        if (self.first_central_offset == null) {
            self.first_central_offset = try self.source.getPos();
        }
    }

    const CdBufWriter = io.BufferedWriter(4096, StreamSource.Writer);

    fn writeCentralRecordInner(self: *Self, store: FileStore, writer: *CdBufWriter) WriteCentralRecordError!void {
        self.central_count += 1;

        // TODO: Add time handling
        const hdr: zip.CentralDirectoryFileHeader = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = 0,
            .version_needed_to_extract = zip_version,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = store.compression,
            .last_modification_date = 0,
            .last_modification_time = 0,
            .crc32 = store.crc32,
            .compressed_size = store.compressed_size,
            .uncompressed_size = store.uncompressed_size,
            // already checked by writeFile
            .filename_len = @intCast(store.name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            .external_file_attributes = 0,
            .local_file_header_offset = store.file_offset,
        };

        try writer.writer().writeStructEndian(hdr, .little);
        try writer.writer().writeAll(store.name);
    }

    pub const WriteEndRecordError = error{
        CdEndOverflow,
        CdCountOverflow,
        CdOffsetOverflow,
        InvalidCdOffset,
    } || StreamSource.GetSeekPosError || StreamSource.WriteError;

    pub fn writeEndRecord(self: *Self) WriteEndRecordError!void {
        const cd_offset = std.math.cast(u32, self.first_central_offset orelse 0) orelse return error.CdOffsetOverflow;
        // lock out file writing
        self.first_central_offset = cd_offset;
        const cd_end = std.math.cast(u32, try self.source.getPos()) orelse return error.CdEndOverflow;
        if (cd_offset > cd_end) return error.InvalidCdOffset;

        const cd_count = std.math.cast(u16, self.central_count) orelse return error.CdCountOverflow;

        const hdr: zip.EndRecord = .{
            .signature = zip.end_record_sig,
            .disk_number = 0,
            .central_directory_disk_number = 0,
            .record_count_disk = cd_count,
            .record_count_total = cd_count,
            .central_directory_offset = cd_offset,
            .central_directory_size = cd_end - cd_offset,
            .comment_len = 0,
        };

        var writer = io.bufferedWriter(self.source.writer());
        try writer.writer().writeStructEndian(hdr, .little);
        try writer.flush();
    }
};

test "expect Zipper.writeFile can write records" {
    var buf: [4096]u8 = undefined;
    const buf_stream = io.fixedBufferStream(&buf);
    var zipper = Zipper.init(.{ .buffer = buf_stream });

    var rng_engine = std.Random.Xoshiro256.init(testing.random_seed);
    var input_buf: [256]u8 = undefined;
    rng_engine.random().bytes(&input_buf);
    var input_stream: StreamSource = .{ .buffer = io.fixedBufferStream(&input_buf) };

    const store = try zipper.writeFile(.{
        .name = "dingus",
        .content = &input_stream,
        .compression = .store,
    });

    try testing.expectEqualStrings("dingus", store.name);
}

test "expect Zipper.writeFile deflate compresses data" {
    var buf: [4096]u8 = undefined;
    const buf_stream = io.fixedBufferStream(&buf);
    var zipper = Zipper.init(.{ .buffer = buf_stream });

    const input_len = 2048;
    var input_buf: [input_len]u8 = [_]u8{ 1, 2, 3, 4 } ** (input_len / 4);

    var input_stream: StreamSource = .{ .buffer = io.fixedBufferStream(&input_buf) };

    const store = try zipper.writeFile(.{
        .name = "dingus",
        .content = &input_stream,
        .compression = .deflate,
    });

    try testing.expect(store.compressed_size < store.uncompressed_size);
}

fn writeData(data: []const u8, subpath: []const u8, filename: []const u8, dir: std.fs.Dir) !FileStore {
    const file = try dir.createFile(subpath, .{});
    defer file.close();
    var zipper: Zipper = .init(.{ .file = file });
    var input_stream: StreamSource = .{ .const_buffer = io.fixedBufferStream(data[0..]) };
    return try zipper.writeFile(.{
        .name = filename,
        .content = &input_stream,
        .compression = .deflate,
    });
}

test "expect Zipper.writeFile deflate data writes can be decompressed" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const data =
        \\#include <stdio.h>
        \\
        \\int main(int argc, char** argv) {
        \\    printf("hello world\n");
        \\    return 0;
        \\}
    ;
    const subpath = "hello_world.zip";
    const filename = "hello_world.c";
    const store = try writeData(data, subpath, filename, dir.dir);

    const file = try dir.dir.openFile(subpath, .{ .mode = .read_only });
    defer file.close();

    const allocator = std.testing.allocator;

    var file_reader = io.bufferedReader(file.reader());
    const header = try file_reader.reader().readStructEndian(zip.LocalFileHeader, .little);
    try testing.expectEqualSlices(u8, &zip.local_file_header_sig, &header.signature);

    const actual_filename = try file_reader.reader().readBoundedBytes(filename.len);
    try testing.expectEqualStrings(filename, actual_filename.constSlice());

    var comp_buf: std.ArrayList(u8) = .init(allocator);
    defer comp_buf.deinit();
    var fifo: std.fifo.LinearFifo(u8, .{ .Static = 256 }) = .init();
    try fifo.pump(file_reader.reader(), comp_buf.writer());

    var decompressed_buf: std.ArrayList(u8) = .init(allocator);
    defer decompressed_buf.deinit();
    var comp_stream = io.fixedBufferStream(comp_buf.items);

    try flate.decompress(comp_stream.reader(), decompressed_buf.writer());

    // test for data accuracy
    try testing.expectEqualStrings(data, decompressed_buf.items);

    // test for header accuracy
    try testing.expectEqual(data.len, header.uncompressed_size);
    try testing.expectEqual(comp_buf.items.len, header.compressed_size);

    // test for store accuracy
    try testing.expectEqual(data.len, store.uncompressed_size);
    try testing.expectEqual(comp_buf.items.len, store.compressed_size);

    // test for hash accuracy
    try testing.expectEqual(std.hash.Crc32.hash(data), store.crc32);
}

test "expect Zipper written headers have len of filename" {
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();
    const data =
        \\#include <stdio.h>
        \\
        \\int main(int argc, char** argv) {
        \\    printf("hello world\n");
        \\    return 0;
        \\}
    ;
    const subpath = "hello_world.zip";
    const filename = "hello_world.c";

    _ = try writeData(data, subpath, filename, dir.dir);

    const file = try dir.dir.openFile(subpath, .{});
    defer file.close();

    var file_reader = io.bufferedReader(file.reader());
    const header = try file_reader.reader().readStructEndian(zip.LocalFileHeader, .little);

    try testing.expectEqualSlices(u8, &zip.local_file_header_sig, &header.signature);
    try testing.expectEqual(filename.len, header.filename_len);
}

test "Zipper results can be read back by std.zip" {
    testing.log_level = .debug;
    var dir = testing.tmpDir(.{});
    defer dir.cleanup();

    const data =
        \\#include <stdio.h>
        \\
        \\int main(int argc, char** argv) {
        \\    printf("hello world\n");
        \\    return 0;
        \\}
    ;
    const subpath = "hello_world.zip";
    const filename = "hello_world.c";

    {
        const file = try dir.dir.createFile(subpath, .{});
        defer file.close();
        var zipper: Zipper = .init(.{ .file = file });
        var input_stream: StreamSource = .{ .const_buffer = io.fixedBufferStream(data[0..]) };
        const store = try zipper.writeFile(.{
            .name = filename,
            .content = &input_stream,
            .compression = .deflate,
        });
        try zipper.writeCentralRecord(store);
        try zipper.writeEndRecord();
    }

    const file = try dir.dir.openFile(subpath, .{ .mode = .read_only });
    defer file.close();

    var res_dir = try dir.dir.makeOpenPath("results", .{});
    defer res_dir.close();

    var diag: zip.Diagnostics = .{ .allocator = testing.allocator };
    defer diag.deinit();

    try zip.extract(res_dir, file.seekableStream(), .{
        .diagnostics = &diag,
    });

    try res_dir.access(filename, .{});
}
