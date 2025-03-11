const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Linkage to build library with",
    ) orelse .static;

    const lib_mod = b.addModule("zipper", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = linkage,
        .name = "zipper",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // For lsp
    const lib_check = b.addLibrary(.{
        .linkage = .static,
        .name = "zipper",
        .root_module = lib_mod,
    });

    const check_step = b.step("check", "Check if compiles successfully.");
    check_step.dependOn(&lib_check);
}
