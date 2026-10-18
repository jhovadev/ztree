const std = @import("std");

/// Build graph for `ztree`.
///
/// Available steps:
///   zig build            compile and install the `ztree` binary
///   zig build run -- ... run it (arguments are forwarded)
///   zig build test       run unit tests
///   zig build fmt        format the source tree in place
///   zig build check      verify formatting and run the tests
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Reusable library module: the CLI parser and the renderer can be
    // embedded in other programs without pulling in `main`.
    const lib = b.addModule("ztree", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ztree",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ztree", .module = lib },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run ztree");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = lib });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const fmt_paths: []const []const u8 = &.{ "build.zig", "src" };

    const fmt_step = b.step("fmt", "Format the source tree");
    const fmt = b.addFmt(.{ .paths = fmt_paths });
    fmt_step.dependOn(&fmt.step);

    const fmt_check = b.addFmt(.{ .paths = fmt_paths, .check = true });

    const check_step = b.step("check", "Verify formatting and run tests");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(&run_lib_tests.step);
    check_step.dependOn(&run_exe_tests.step);
}
