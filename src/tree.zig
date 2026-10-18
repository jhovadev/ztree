//! Recursive directory tree rendering.
//!
//! The walker is built directly on `Io.Dir.iterate` instead of
//! `Io.Dir.walk` so that each directory can be sorted before it is printed
//! and so that the renderer knows which entry is the last sibling (required
//! for correct branch connectors).
//!
//! Symbolic links are shown with their target but are never followed, which
//! makes directory cycles impossible by construction.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const colors = @import("colors.zig");

/// Defensive bound for recursion. It only matters for pathologically deep
/// trees; `--depth` values above it are clamped and reported.
pub const max_supported_depth: usize = 1024;

pub const Options = struct {
    show_hidden: bool = false,
    dirs_only: bool = false,
    show_size: bool = false,
    color: bool = false,
    ascii: bool = false,
    summary: bool = true,
    max_depth: ?usize = null,
};

pub const Stats = struct {
    directories: usize = 0,
    files: usize = 0,
    symlinks: usize = 0,
    others: usize = 0,
    errors: usize = 0,
};

pub const Root = struct {
    /// Text printed above the tree (usually the path the user requested).
    label: []const u8,
    /// Directory to iterate. Must have been opened with `iterate = true`.
    dir: Dir,
};

const Entry = struct {
    name: []const u8,
    kind: Io.File.Kind,
    size: ?u64 = null,
};

const Branch = struct {
    tee: []const u8,
    last: []const u8,
    pipe: []const u8,
    blank: []const u8,
};

const unicode_branches: Branch = .{
    .tee = "├── ",
    .last = "└── ",
    .pipe = "│   ",
    .blank = "    ",
};

const ascii_branches: Branch = .{
    .tee = "|-- ",
    .last = "`-- ",
    .pipe = "|   ",
    .blank = "    ",
};

const State = struct {
    io: Io,
    allocator: std.mem.Allocator,
    out: *Io.Writer,
    err: ?*Io.Writer,
    options: Options,
    stats: Stats = .{},
    branch: Branch,
    prefix: std.ArrayList(u8) = .empty,
    rel_path: std.ArrayList(u8) = .empty,
    depth_limit_warned: bool = false,

    fn deinit(self: *State) void {
        self.prefix.deinit(self.allocator);
        self.rel_path.deinit(self.allocator);
    }

    fn renderDir(self: *State, dir: Dir, depth: usize) !void {
        // Entries are read up-front because the directory iterator borrows its
        // buffer, and because sorting requires the complete set before the
        // first line (and therefore the last-sibling connector) can be drawn.
        var entries = try self.readEntries(dir);
        defer {
            for (entries.items) |entry| self.allocator.free(entry.name);
            entries.deinit(self.allocator);
        }

        std.mem.sort(Entry, entries.items, {}, entryLessThan);

        for (entries.items, 0..) |entry, index| {
            const is_last = index + 1 == entries.items.len;
            try self.writeEntry(dir, entry, is_last);
            self.count(entry.kind);

            // Only real directories are descended into. Symlinks are reported
            // with their target but never followed, which rules out cycles.
            if (entry.kind != .directory) continue;
            if (depth + 1 >= self.depthLimit()) {
                if (depth + 1 >= max_supported_depth and !self.depth_limit_warned) {
                    self.depth_limit_warned = true;
                    try self.warn(
                        "warning: maximum supported depth ({d}) reached; output truncated\n",
                        .{max_supported_depth},
                    );
                }
                continue;
            }

            const child = dir.openDir(self.io, entry.name, .{ .iterate = true }) catch |err| {
                // An unreadable child is not fatal: report it and keep walking
                // the rest of the tree.
                try self.warnEntry(entry.name, err);
                continue;
            };
            defer child.close(self.io);

            // Each recursion level appends either a vertical continuation or
            // blank space to the prefix, then restores it on the way out.
            const saved_prefix = self.prefix.items.len;
            const saved_path = self.rel_path.items.len;
            try self.prefix.appendSlice(self.allocator, if (is_last) self.branch.blank else self.branch.pipe);
            try self.rel_path.appendSlice(self.allocator, entry.name);
            try self.rel_path.append(self.allocator, '/');

            try self.renderDir(child, depth + 1);

            self.prefix.shrinkRetainingCapacity(saved_prefix);
            self.rel_path.shrinkRetainingCapacity(saved_path);
        }
    }

    /// Reads and filters the entries of one directory. Keeping the (large)
    /// directory iterator in this function instead of `renderDir` keeps
    /// recursive stack frames small.
    fn readEntries(self: *State, dir: Dir) !std.ArrayList(Entry) {
        var entries: std.ArrayList(Entry) = .empty;
        errdefer {
            for (entries.items) |entry| self.allocator.free(entry.name);
            entries.deinit(self.allocator);
        }

        var iterator = dir.iterate();
        while (true) {
            const next = iterator.next(self.io) catch |err| {
                try self.warnDirectory(err);
                break;
            } orelse break;

            if (!self.options.show_hidden and isHidden(next.name)) continue;
            if (self.options.dirs_only and next.kind != .directory) continue;

            const name = try self.allocator.dupe(u8, next.name);
            errdefer self.allocator.free(name);

            var entry: Entry = .{ .name = name, .kind = next.kind };
            // Sizes are opt-in because they cost one extra `stat` per file.
            if (self.options.show_size and next.kind == .file) {
                const stat = dir.statFile(self.io, next.name, .{ .follow_symlinks = false }) catch null;
                if (stat) |value| entry.size = value.size;
            }

            try entries.append(self.allocator, entry);
        }

        return entries;
    }

    /// Draws one entry: prefix, connector, colored name, optional link target
    /// and optional size. The newline is written here so every entry is
    /// self-contained.
    fn writeEntry(self: *State, dir: Dir, entry: Entry, is_last: bool) !void {
        const colored = self.options.color;

        if (colored) try self.out.writeAll(colors.branch);
        try self.out.writeAll(self.prefix.items);
        try self.out.writeAll(if (is_last) self.branch.last else self.branch.tee);
        if (colored) try self.out.writeAll(colors.reset);

        const style = switch (entry.kind) {
            .directory => colors.directory,
            .sym_link => colors.symlink,
            .file => colors.file,
            else => colors.other,
        };
        if (colored and style.len != 0) try self.out.writeAll(style);
        try self.out.writeAll(entry.name);
        if (colored and style.len != 0) try self.out.writeAll(colors.reset);

        if (entry.kind == .sym_link) {
            var target_buffer: [Dir.max_path_bytes]u8 = undefined;
            const target_len = dir.readLink(self.io, entry.name, &target_buffer) catch null;
            if (target_len) |len| {
                if (colored) try self.out.writeAll(colors.dim);
                try self.out.print(" -> {s}", .{target_buffer[0..len]});
                if (colored) try self.out.writeAll(colors.reset);
            }
        }

        if (self.options.show_size) {
            if (entry.size) |size| {
                var size_buffer: [32]u8 = undefined;
                if (colored) try self.out.writeAll(colors.size);
                try self.out.print(" ({s})", .{formatSize(&size_buffer, size)});
                if (colored) try self.out.writeAll(colors.reset);
            }
        }

        try self.out.writeAll("\n");
    }

    /// Prints the final statistics block. It starts with a blank line so it is
    /// visually separate from the tree, and `--dirs-only` omits the file count
    /// because files were intentionally skipped.
    fn writeSummary(self: *State) !void {
        if (!self.options.summary) return;

        if (self.options.color) try self.out.writeAll(colors.summary);
        try self.out.writeAll("\n");
        try self.out.print("{d} {s}", .{
            self.stats.directories,
            plural(self.stats.directories, "directory", "directories"),
        });
        if (!self.options.dirs_only) {
            try self.out.print(", {d} {s}", .{
                self.stats.files,
                plural(self.stats.files, "file", "files"),
            });
        }
        if (self.stats.symlinks > 0) {
            try self.out.print(", {d} {s}", .{
                self.stats.symlinks,
                plural(self.stats.symlinks, "symlink", "symlinks"),
            });
        }
        if (self.stats.others > 0) {
            try self.out.print(", {d} {s}", .{
                self.stats.others,
                plural(self.stats.others, "other entry", "other entries"),
            });
        }
        if (self.stats.errors > 0) {
            try self.out.print(", {d} {s}", .{
                self.stats.errors,
                plural(self.stats.errors, "error", "errors"),
            });
        }
        if (self.options.color) try self.out.writeAll(colors.reset);
        try self.out.writeAll("\n");
    }

    fn count(self: *State, kind: Io.File.Kind) void {
        switch (kind) {
            .directory => self.stats.directories += 1,
            .file => self.stats.files += 1,
            .sym_link => self.stats.symlinks += 1,
            else => self.stats.others += 1,
        }
    }

    /// Effective depth limit. User-provided values are clamped to the
    /// defensive maximum so recursion can never exhaust the stack.
    fn depthLimit(self: *const State) usize {
        return @min(self.options.max_depth orelse max_supported_depth, max_supported_depth);
    }

    fn warnEntry(self: *State, name: []const u8, err: anyerror) !void {
        self.stats.errors += 1;
        try self.warn("warning: cannot read '{s}{s}': {s}\n", .{
            self.rel_path.items,
            name,
            @errorName(err),
        });
    }

    fn warnDirectory(self: *State, err: anyerror) !void {
        self.stats.errors += 1;
        const relative = std.mem.trimEnd(u8, self.rel_path.items, "/");
        try self.warn("warning: cannot read directory '{s}': {s}\n", .{
            if (relative.len == 0) "." else relative,
            @errorName(err),
        });
    }

    fn warn(self: *State, comptime format: []const u8, args: anytype) !void {
        const stderr = self.err orelse return;
        // Keep warnings in order with respect to already-rendered output.
        try self.out.flush();
        try stderr.print(format, args);
        try stderr.flush();
    }
};

/// Renders `root` and its descendants, returning the collected statistics.
///
/// The caller owns the writers; this function flushes `out` before returning,
/// but not `err`. Errors from individual directories are reported through
/// `err` (when provided) and counted in `Stats.errors` instead of aborting the
/// whole listing.
pub fn render(
    io: Io,
    out: *Io.Writer,
    err: ?*Io.Writer,
    allocator: std.mem.Allocator,
    root: Root,
    options: Options,
) !Stats {
    var state: State = .{
        .io = io,
        .allocator = allocator,
        .out = out,
        .err = err,
        .options = options,
        .branch = if (options.ascii) ascii_branches else unicode_branches,
    };
    defer state.deinit();

    if (options.color) try out.writeAll(colors.bold);
    try out.writeAll(if (root.label.len == 0) "." else root.label);
    if (options.color) try out.writeAll(colors.reset);
    try out.writeAll("\n");

    try state.renderDir(root.dir, 0);
    try state.writeSummary();
    try out.flush();

    return state.stats;
}

/// Opens `path` and renders it. The caller keeps ownership of the writers.
pub fn renderPath(
    io: Io,
    out: *Io.Writer,
    err: ?*Io.Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) !Stats {
    const dir = if (std.fs.path.isAbsolute(path))
        try Dir.openDirAbsolute(io, path, .{ .iterate = true })
    else
        try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    return render(io, out, err, allocator, .{ .label = path, .dir = dir }, options);
}

fn isHidden(name: []const u8) bool {
    return name.len != 0 and name[0] == '.';
}

/// Directories first, then case-insensitive name order. The byte comparison
/// is a deterministic tie-breaker for names differing only by case.
fn entryLessThan(_: void, lhs: Entry, rhs: Entry) bool {
    const lhs_is_dir = lhs.kind == .directory;
    const rhs_is_dir = rhs.kind == .directory;
    if (lhs_is_dir != rhs_is_dir) return lhs_is_dir;

    const common = @min(lhs.name.len, rhs.name.len);
    for (lhs.name[0..common], rhs.name[0..common]) |lhs_byte, rhs_byte| {
        const lhs_lower = std.ascii.toLower(lhs_byte);
        const rhs_lower = std.ascii.toLower(rhs_byte);
        if (lhs_lower != rhs_lower) return lhs_lower < rhs_lower;
    }
    if (lhs.name.len != rhs.name.len) return lhs.name.len < rhs.name.len;
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn plural(count: usize, one: []const u8, many: []const u8) []const u8 {
    return if (count == 1) one else many;
}

/// Formats a byte count with binary units, for example `512 B` or `1.5 KiB`.
///
/// Integer arithmetic is used on purpose: no floating-point formatting, no
/// rounding surprises, and the result fits in a 32-byte buffer.
fn formatSize(buffer: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch unreachable;

    var unit: usize = 0;
    var divisor: u64 = 1;
    while (unit + 1 < units.len and bytes / divisor >= 1024) {
        divisor *= 1024;
        unit += 1;
    }

    const whole = bytes / divisor;
    const remainder = bytes % divisor;
    const tenths = @as(u128, remainder) * 10 / divisor;
    return std.fmt.bufPrint(buffer, "{d}.{d} {s}", .{ whole, tenths, units[unit] }) catch unreachable;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const builtin = @import("builtin");

const Fixture = struct {
    tmp: std.testing.TmpDir,

    /// Creates the same small tree for every rendering test:
    /// two directories, four visible files and one hidden file.
    fn init() !Fixture {
        const io = std.testing.io;
        var fixture: Fixture = .{ .tmp = std.testing.tmpDir(.{ .iterate = true }) };
        errdefer fixture.tmp.cleanup();

        try fixture.tmp.dir.createDirPath(io, "docs");
        try fixture.tmp.dir.createDirPath(io, "empty");
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "docs/a.md", .data = "# A\n" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "docs/b.md", .data = "# B\n" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "one.txt", .data = "one" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = "zeta.log", .data = "z" });
        try fixture.tmp.dir.writeFile(io, .{ .sub_path = ".hidden", .data = "hidden" });
        return fixture;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }
};

fn expectRender(fixture: *Fixture, options: Options, expected: []const u8) !Stats {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const stats = try render(
        std.testing.io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = fixture.tmp.dir },
        options,
    );
    try std.testing.expectEqualStrings(expected, output.written());
    return stats;
}

test "renders a sorted tree with a summary" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const stats = try expectRender(&fixture, .{ .ascii = true },
        \\.
        \\|-- docs
        \\|   |-- a.md
        \\|   `-- b.md
        \\|-- empty
        \\|-- one.txt
        \\`-- zeta.log
        \\
        \\2 directories, 4 files
        \\
    );

    try std.testing.expectEqual(@as(usize, 2), stats.directories);
    try std.testing.expectEqual(@as(usize, 4), stats.files);
    try std.testing.expectEqual(@as(usize, 0), stats.errors);
}

test "hidden entries are opt-in" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    _ = try expectRender(&fixture, .{ .ascii = true, .show_hidden = true },
        \\.
        \\|-- docs
        \\|   |-- a.md
        \\|   `-- b.md
        \\|-- empty
        \\|-- .hidden
        \\|-- one.txt
        \\`-- zeta.log
        \\
        \\2 directories, 5 files
        \\
    );
}

test "max depth stops recursion" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const stats = try expectRender(&fixture, .{ .ascii = true, .max_depth = 1 },
        \\.
        \\|-- docs
        \\|-- empty
        \\|-- one.txt
        \\`-- zeta.log
        \\
        \\2 directories, 2 files
        \\
    );

    try std.testing.expectEqual(@as(usize, 2), stats.files);
}

test "dirs only listing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    const stats = try expectRender(&fixture, .{ .ascii = true, .dirs_only = true },
        \\.
        \\|-- docs
        \\`-- empty
        \\
        \\2 directories
        \\
    );

    try std.testing.expectEqual(@as(usize, 0), stats.files);
}

test "sizes are human readable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "tiny.txt", .data = "hello world" });
    const payload = [_]u8{'x'} ** 1536;
    try tmp.dir.writeFile(io, .{ .sub_path = "big.bin", .data = &payload });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true, .show_size = true, .summary = false },
    );

    try std.testing.expectEqualStrings(
        \\.
        \\|-- big.bin (1.5 KiB)
        \\`-- tiny.txt (11 B)
        \\
    , output.written());
}

test "symlinks are displayed but not followed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "docs");
    try tmp.dir.writeFile(io, .{ .sub_path = "docs/a.md", .data = "# A\n" });
    try tmp.dir.symLink(io, "a.md", "docs/link.md", .{});

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const stats = try render(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true, .summary = false },
    );

    try std.testing.expectEqualStrings(
        \\.
        \\`-- docs
        \\    |-- a.md
        \\    `-- link.md -> a.md
        \\
    , output.written());
    try std.testing.expectEqual(@as(usize, 1), stats.directories);
    try std.testing.expectEqual(@as(usize, 1), stats.files);
    try std.testing.expectEqual(@as(usize, 1), stats.symlinks);
}

test "color output contains ANSI sequences" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(
        std.testing.io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = fixture.tmp.dir },
        .{ .ascii = true, .color = true, .summary = false },
    );

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "docs") != null);
}

test "renderPath reports missing directories" {
    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.FileNotFound,
        renderPath(
            std.testing.io,
            &output.writer,
            null,
            std.testing.allocator,
            "ztree-path-that-must-not-exist-4f8c1a",
            .{},
        ),
    );
}

test "renderPath walks a real path" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "data" });

    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const stats = try renderPath(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        path,
        .{ .ascii = true, .summary = false },
    );

    try std.testing.expectEqual(@as(usize, 1), stats.files);
    try std.testing.expect(std.mem.endsWith(u8, output.written(), "`-- file.txt\n"));
}

test "formatSize handles boundaries and larger units" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatSize(&buffer, 0));
    try std.testing.expectEqualStrings("1023 B", formatSize(&buffer, 1023));
    try std.testing.expectEqualStrings("1.0 KiB", formatSize(&buffer, 1024));
    try std.testing.expectEqualStrings("1.5 KiB", formatSize(&buffer, 1536));
    try std.testing.expectEqualStrings("1.0 MiB", formatSize(&buffer, 1024 * 1024));
    try std.testing.expectEqualStrings("1.5 MiB", formatSize(&buffer, 1024 * 1024 + 512 * 1024));
    try std.testing.expectEqualStrings("10.5 MiB", formatSize(&buffer, 10 * 1024 * 1024 + 512 * 1024));
    try std.testing.expectEqualStrings("1.0 GiB", formatSize(&buffer, 1024 * 1024 * 1024));
}

test "renders an empty directory and falls back to a dot label" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const stats = try render(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = "", .dir = tmp.dir },
        .{ .ascii = true },
    );

    try std.testing.expectEqualStrings(".\n\n0 directories, 0 files\n", output.written());
    try std.testing.expectEqual(@as(usize, 0), stats.directories);
    try std.testing.expectEqual(@as(usize, 0), stats.files);
}

test "unicode branches are the default" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    _ = try expectRender(&fixture, .{},
        \\.
        \\├── docs
        \\│   ├── a.md
        \\│   └── b.md
        \\├── empty
        \\├── one.txt
        \\└── zeta.log
        \\
        \\2 directories, 4 files
        \\
    );
}

test "sorting is case-insensitive and directories come first" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "Zulu");
    try tmp.dir.createDirPath(io, "alpha");
    try tmp.dir.writeFile(io, .{ .sub_path = "beta.txt", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "Alpha.txt", .data = "a" });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true },
    );

    try std.testing.expectEqualStrings(
        \\.
        \\|-- alpha
        \\|-- Zulu
        \\|-- Alpha.txt
        \\`-- beta.txt
        \\
        \\2 directories, 2 files
        \\
    , output.written());
}

test "hidden directories are skipped entirely unless shown" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".secret");
    try tmp.dir.writeFile(io, .{ .sub_path = ".secret/inner.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "visible.txt", .data = "v" });

    var visible_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer visible_output.deinit();
    _ = try render(
        io,
        &visible_output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true },
    );
    try std.testing.expectEqualStrings(
        \\.
        \\`-- visible.txt
        \\
        \\0 directories, 1 file
        \\
    , visible_output.written());

    var all_output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer all_output.deinit();
    _ = try render(
        io,
        &all_output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true, .show_hidden = true },
    );
    try std.testing.expectEqualStrings(
        \\.
        \\|-- .secret
        \\|   `-- inner.txt
        \\`-- visible.txt
        \\
        \\1 directory, 2 files
        \\
    , all_output.written());
}

test "symlinked directories are not followed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "target");
    try tmp.dir.writeFile(io, .{ .sub_path = "target/file.txt", .data = "data" });
    try tmp.dir.symLink(io, "target", "link", .{});

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const stats = try render(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true },
    );

    try std.testing.expectEqualStrings(
        \\.
        \\|-- target
        \\|   `-- file.txt
        \\`-- link -> target
        \\
        \\1 directory, 1 file, 1 symlink
        \\
    , output.written());
    try std.testing.expectEqual(@as(usize, 1), stats.directories);
    try std.testing.expectEqual(@as(usize, 1), stats.files);
    try std.testing.expectEqual(@as(usize, 1), stats.symlinks);
}

test "depth counts from the requested directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "a/b/c");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/b/c/file.txt", .data = "data" });

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    const stats = try render(
        io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = tmp.dir },
        .{ .ascii = true, .max_depth = 2 },
    );

    try std.testing.expectEqualStrings(
        \\.
        \\`-- a
        \\    `-- b
        \\
        \\2 directories
        \\
    , output.written());
    try std.testing.expectEqual(@as(usize, 2), stats.directories);
    try std.testing.expectEqual(@as(usize, 0), stats.files);
}

test "plain output contains no escape sequences" {
    var fixture = try Fixture.init();
    defer fixture.deinit();

    var output: Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(
        std.testing.io,
        &output.writer,
        null,
        std.testing.allocator,
        .{ .label = ".", .dir = fixture.tmp.dir },
        .{ .ascii = true },
    );

    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b[") == null);
}
