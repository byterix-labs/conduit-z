const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const conduit_mod = b.addModule("conduit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const conduit_lib = b.addStaticLibrary(.{
        .name = "conduit",
        .root_module = conduit_mod,
    });

    b.installArtifact(conduit_lib);

    const lib_unit_tests = b.addTest(.{
        .root_module = conduit_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const lib_temp = b.dependency("temp", .{
        .target = target,
        .optimize = optimize,
    });
    const mod_temp = lib_temp.module("temp");
    conduit_mod.addImport("temp", mod_temp);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = conduit_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
