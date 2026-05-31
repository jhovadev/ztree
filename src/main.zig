const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
// const ztree = @import("ztree");

// const ANSI_RESET = "\x1b[0m";
// const ANSI_BLUE = "\x1b[34m";
// const ANSI_GREEN = "\x1b[32m";
// const ANSI_GRAY = "\x1b[90m";

pub fn tree_directory(io: Io, allocator: Allocator, cwd: Dir) !void {
    const actual_dir = try cwd.openDir(io, "./", .{
        .iterate = true,
    });
    defer actual_dir.close(io);

    // const iterator =
    var walker = try actual_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        //solo archivos
        for (0..entry.depth()) |_| {
            std.debug.print("|  ", .{});
        }

        const prefix = if (entry.kind == .directory) "" else "";
        print("{s}", .{prefix});
        // solo directorios
        if (entry.kind == Io.File.Kind.directory) {
            print(" {s} \n", .{entry.basename});
        }
        if (entry.kind == Io.File.Kind.file) {
            print(" {s}\t\n", .{entry.basename});
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    try tree_directory(io, arena, Dir.cwd());
    // const args = try init.minimal.args.toSlice(arena);
    // for (args,0..) |arg| {
    //     std.log.info("arg: {s}", .{arg});
    // }
    // const cmd = args[1];
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    // var stdout_buffer: [1024]u8 = undefined;
    // var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    // const stdout_writer = &stdout_file_writer.interface;

    // try ztree.printAnotherMessage(stdout_writer);

    // try stdout_writer.flush(); // Don't forget to flush!
}
