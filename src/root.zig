const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

const Io = std.Io;

test "recursive directory listing" {
    // it should recursively read the Dirpath with folders and files
    const io = testing.io;
    const gpa = testing.allocator;
    const cwd = Io.Dir.cwd();
    const actual_dir = try cwd.openDir(io, "./", .{
        .iterate = true,
    });
    defer actual_dir.close(io);

    // const iterator =
    var walker = try actual_dir.walk(gpa);
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
    // print("{d}\n", .{entry.depth()});

    try testing.expect(true);
    // print("{s}", .{actual_dir.1});
}
