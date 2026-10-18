//! `ztree` process entry point.
//!
//! This file deliberately stays thin. It owns only the concerns that require a
//! process: creating buffered stdout/stderr writers, bridging
//! `std.process.Init` to the library API, and translating results into exit
//! codes. Parsing lives in `cli.zig` and rendering in `tree.zig`.

const std = @import("std");
const Io = std.Io;
const ztree = @import("ztree");

// Exit codes are part of the public interface and documented in the README.
const exit_success: u8 = 0;
const exit_usage: u8 = 1;
const exit_io: u8 = 2;

// A larger stdout buffer keeps syscalls low on big trees. stderr is only used
// for short diagnostics, so a small buffer is enough.
const stdout_buffer_size = 16 * 1024;
const stderr_buffer_size = 4 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // The arena lives for the whole process, so argument copies and parser
    // diagnostics do not need explicit frees.
    const arena = init.arena.allocator();

    var stdout_buffer: [stdout_buffer_size]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // Best-effort final flush: a consumer may have closed the pipe, and that
    // must not print an error trace when the process is already finishing.
    defer stdout_file_writer.interface.flush() catch {};
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [stderr_buffer_size]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    defer stderr_file_writer.interface.flush() catch {};
    const stderr = &stderr_file_writer.interface;

    // `toSlice` returns sentinel-terminated slices; the parser takes plain
    // slices, so make one shallow copy of the argument vector.
    const raw_args = try init.minimal.args.toSlice(arena);
    const argv = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |arg, index| argv[index] = arg;

    const parsed = try ztree.cli.parse(arena, argv[1..]);
    switch (parsed) {
        .failure => |failure| {
            try stderr.print("error: {s}\n", .{failure.message});
            try stderr.writeAll("Try 'ztree --help' for more information.\n");
            try stderr.flush();
            std.process.exit(exit_usage);
        },
        .command => |command| switch (command) {
            .help => {
                try ztree.cli.writeHelp(stdout);
                try stdout.flush();
            },
            .version => {
                try stdout.print("ztree {s}\n", .{ztree.version});
                try stdout.flush();
            },
            .run => |config| {
                // Only query the terminal when the policy is `auto`; explicit
                // `always`/`never` do not need the syscall.
                const stdout_is_tty = if (config.color == .auto)
                    Io.File.stdout().isTty(io) catch false
                else
                    false;

                const options: ztree.tree.Options = .{
                    .show_hidden = config.show_hidden,
                    .dirs_only = config.dirs_only,
                    .show_size = config.show_size,
                    .color = ztree.cli.resolveColor(config.color, .{
                        .no_color = init.environ_map.get("NO_COLOR"),
                        .clicolor_force = init.environ_map.get("CLICOLOR_FORCE"),
                        .term = init.environ_map.get("TERM"),
                        .stdout_is_tty = stdout_is_tty,
                    }),
                    .ascii = config.ascii,
                    .summary = config.summary,
                    .max_depth = config.max_depth,
                };

                _ = ztree.tree.renderPath(io, stdout, stderr, arena, config.path, options) catch |err| {
                    if (err == error.WriteFailed) {
                        // The consumer closed the pipe (for example `ztree | head`).
                        // This is not an application error.
                        stderr.flush() catch {};
                        std.process.exit(exit_success);
                    }
                    // Show whatever was rendered before the failure, then a
                    // single diagnostic on stderr.
                    stdout.flush() catch {};
                    stderr.print("error: cannot read '{s}': {s}\n", .{
                        config.path,
                        @errorName(err),
                    }) catch {};
                    stderr.flush() catch {};
                    std.process.exit(exit_io);
                };

                // `render` flushes stdout before returning; the deferred flush
                // above is only a safety net for early exits.
            },
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}
