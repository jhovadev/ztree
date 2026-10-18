//! Command-line parsing for the `ztree` executable.
//!
//! The parser is intentionally allocation-light: it only allocates a message
//! when parsing fails, and every slice in a successful `Config` points into
//! the caller-provided argument list.

const std = @import("std");

pub const version = "0.1.0";

pub const ColorMode = enum { auto, always, never };

/// Fully resolved options for one invocation. Defaults describe `ztree`
/// without arguments: list the current directory, no hidden entries, colors
/// chosen automatically.
pub const Config = struct {
    /// Directory to list.
    path: []const u8 = ".",
    /// Include entries whose name starts with a dot.
    show_hidden: bool = false,
    /// Skip files and symlinks; only directories are listed.
    dirs_only: bool = false,
    /// Fetch and display file sizes (one extra stat per file).
    show_size: bool = false,
    /// Use `|--`/`` `-- `` instead of the Unicode box-drawing characters.
    ascii: bool = false,
    /// Print the final "N directories, M files" line.
    summary: bool = true,
    /// Maximum recursion depth; `null` means "until the tree ends".
    max_depth: ?usize = null,
    /// Requested color policy. `resolveColor` turns it into a boolean.
    color: ColorMode = .auto,
};

pub const Command = union(enum) {
    run: Config,
    help,
    version,
};

pub const Failure = struct {
    /// Human-readable diagnostic, allocated with the parser's allocator.
    message: []const u8,
};

pub const Result = union(enum) {
    command: Command,
    failure: Failure,
};

/// Inputs used to decide whether ANSI colors should be emitted. Keeping this
/// as a plain value (instead of reading the environment globally) makes the
/// policy deterministic and easy to unit test.
pub const ColorEnvironment = struct {
    no_color: ?[]const u8 = null,
    clicolor_force: ?[]const u8 = null,
    term: ?[]const u8 = null,
    stdout_is_tty: bool = false,
};

/// Parses command-line arguments, excluding the executable name.
///
/// Accepted forms:
///   * Long options: `--all`, `--depth 2`, `--depth=2`, `--color=never`.
///   * Short options: `-a`, `-L2`, `-L 2`, `-calways`, and bundles (`-asd`).
///   * `--` terminates option parsing; everything after it is a PATH.
///
/// On failure the returned `Failure.message` is owned by `allocator` and must
/// be freed by the caller. Successful parses allocate nothing.
pub fn parse(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) error{OutOfMemory}!Result {
    var config: Config = .{};
    var path: ?[]const u8 = null;
    var positional_only = false;
    var index: usize = 0;

    while (index < argv.len) : (index += 1) {
        const arg = argv[index];

        // A bare "-" is a path; empty arguments are treated as paths too so
        // that callers get a clear filesystem error rather than a confusing
        // usage error.
        if (positional_only or arg.len == 0 or arg[0] != '-' or std.mem.eql(u8, arg, "-")) {
            if (path != null) return fail(allocator, "only one PATH may be provided", .{});
            path = arg;
            continue;
        }

        // Everything after "--" is positional, even if it looks like a flag.
        if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }

        if (std.mem.startsWith(u8, arg, "--")) {
            // Long options may carry their value with '='. The option name is
            // matched without the value so both `--depth=2` and `--depth 2`
            // share the same code path.
            const equals = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[0 .. equals orelse arg.len];
            const inline_value: ?[]const u8 = if (equals) |position| arg[position + 1 ..] else null;

            if (std.mem.eql(u8, name, "--help")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                return .{ .command = .help };
            }
            if (std.mem.eql(u8, name, "--version")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                return .{ .command = .version };
            }
            if (std.mem.eql(u8, name, "--all")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                config.show_hidden = true;
                continue;
            }
            if (std.mem.eql(u8, name, "--dirs-only")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                config.dirs_only = true;
                continue;
            }
            if (std.mem.eql(u8, name, "--size")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                config.show_size = true;
                continue;
            }
            if (std.mem.eql(u8, name, "--ascii")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                config.ascii = true;
                continue;
            }
            if (std.mem.eql(u8, name, "--no-summary")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                config.summary = false;
                continue;
            }
            if (std.mem.eql(u8, name, "--no-color")) {
                if (try rejectInlineValue(allocator, inline_value, name)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                config.color = .never;
                continue;
            }
            if (std.mem.eql(u8, name, "--depth")) {
                const value = switch (takeValue(argv, &index, inline_value)) {
                    .value => |value| value,
                    .missing => return fail(allocator, "option '{s}' requires a value", .{name}),
                };
                if (try setDepth(&config, allocator, value)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                continue;
            }
            if (std.mem.eql(u8, name, "--color")) {
                const value = switch (takeValue(argv, &index, inline_value)) {
                    .value => |value| value,
                    .missing => return fail(allocator, "option '{s}' requires a value", .{name}),
                };
                if (try setColor(&config, allocator, value)) |failure_value| {
                    return .{ .failure = failure_value };
                }
                continue;
            }

            return fail(allocator, "unknown option '{s}'", .{name});
        }

        // Short options may be bundled (for example `-as`). Value-taking
        // options consume the rest of the bundle (`-L2`) or the next argument
        // (`-L 2`); either way they end the current bundle.
        var short_index: usize = 1;
        while (short_index < arg.len) : (short_index += 1) {
            switch (arg[short_index]) {
                'a' => config.show_hidden = true,
                'd' => config.dirs_only = true,
                's' => config.show_size = true,
                'h' => return .{ .command = .help },
                'V' => return .{ .command = .version },
                'L', 'c' => {
                    const option_name = if (arg[short_index] == 'L') "-L" else "-c";
                    const inline_value: ?[]const u8 =
                        if (short_index + 1 < arg.len) arg[short_index + 1 ..] else null;
                    const value = switch (takeValue(argv, &index, inline_value)) {
                        .value => |value| value,
                        .missing => return fail(allocator, "option '{s}' requires a value", .{option_name}),
                    };

                    if (arg[short_index] == 'L') {
                        if (try setDepth(&config, allocator, value)) |failure_value| {
                            return .{ .failure = failure_value };
                        }
                    } else {
                        if (try setColor(&config, allocator, value)) |failure_value| {
                            return .{ .failure = failure_value };
                        }
                    }
                    break;
                },
                else => return fail(allocator, "unknown option '-{c}'", .{arg[short_index]}),
            }
        }
    }

    config.path = path orelse ".";
    return .{ .command = .{ .run = config } };
}

/// Writes the help screen. Kept next to the parser so both stay in sync.
pub fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.print("ztree {s}\n\n{s}", .{ version, help_body });
}

/// Resolves the requested color policy against the environment.
///
/// Explicit `always`/`never` win over the environment. For `auto`, the
/// de-facto conventions are honored in this order:
///   1. a non-empty `NO_COLOR` disables colors;
///   2. a non-zero `CLICOLOR_FORCE` forces them;
///   3. `TERM=dumb` disables them;
///   4. otherwise colors are used only when stdout is a terminal.
pub fn resolveColor(mode: ColorMode, env: ColorEnvironment) bool {
    switch (mode) {
        .always => return true,
        .never => return false,
        .auto => {},
    }

    if (env.no_color) |value| {
        if (value.len != 0) return false;
    }
    if (env.clicolor_force) |value| {
        if (!std.mem.eql(u8, value, "0")) return true;
    }
    if (env.term) |term| {
        if (std.mem.eql(u8, term, "dumb")) return false;
    }
    return env.stdout_is_tty;
}

/// Value consumed by an option, or an error marker when the option was the
/// last argument of the command line.
const TakenValue = union(enum) {
    value: []const u8,
    missing,
};

/// Returns the inline value (`--opt=value`, `-Lvalue`) or consumes the next
/// argument (`--opt value`). Empty inline values (`--opt=`) are rejected.
fn takeValue(argv: []const []const u8, index: *usize, inline_value: ?[]const u8) TakenValue {
    if (inline_value) |value| {
        if (value.len == 0) return .missing;
        return .{ .value = value };
    }
    if (index.* + 1 >= argv.len) return .missing;
    index.* += 1;
    return .{ .value = argv[index.*] };
}

/// Distinguishes the two invalid-depth diagnostics without allocating before
/// the caller knows which message is needed.
const DepthParse = union(enum) {
    value: usize,
    not_a_number,
    zero,
};

fn parseDepth(value: []const u8) DepthParse {
    const depth = std.fmt.parseInt(usize, value, 10) catch return .not_a_number;
    if (depth == 0) return .zero;
    return .{ .value = depth };
}

fn parseColor(value: []const u8) ?ColorMode {
    if (std.mem.eql(u8, value, "auto")) return .auto;
    if (std.mem.eql(u8, value, "always")) return .always;
    if (std.mem.eql(u8, value, "never")) return .never;
    return null;
}

/// Applies `--depth`/`-L`, returning a failure only for invalid values.
fn setDepth(
    config: *Config,
    allocator: std.mem.Allocator,
    value: []const u8,
) error{OutOfMemory}!?Failure {
    switch (parseDepth(value)) {
        .value => |depth| config.max_depth = depth,
        .not_a_number => return try makeFailure(
            allocator,
            "invalid depth '{s}': expected a positive integer",
            .{value},
        ),
        .zero => return try makeFailure(allocator, "invalid depth '0': must be at least 1", .{}),
    }
    return null;
}

/// Applies `--color`/`-c`, returning a failure only for invalid values.
fn setColor(
    config: *Config,
    allocator: std.mem.Allocator,
    value: []const u8,
) error{OutOfMemory}!?Failure {
    config.color = parseColor(value) orelse return try makeFailure(
        allocator,
        "invalid color mode '{s}': expected auto, always, or never",
        .{value},
    );
    return null;
}

/// Boolean options must not receive an inline value.
fn rejectInlineValue(
    allocator: std.mem.Allocator,
    inline_value: ?[]const u8,
    name: []const u8,
) error{OutOfMemory}!?Failure {
    if (inline_value == null) return null;
    return try makeFailure(allocator, "option '{s}' does not take a value", .{name});
}

fn makeFailure(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!Failure {
    return .{ .message = try std.fmt.allocPrint(allocator, format, args) };
}

fn fail(
    allocator: std.mem.Allocator,
    comptime format: []const u8,
    args: anytype,
) error{OutOfMemory}!Result {
    return .{ .failure = try makeFailure(allocator, format, args) };
}

const help_body =
    \\Usage: ztree [OPTIONS] [PATH]
    \\
    \\Recursively list the contents of a directory as a tree.
    \\
    \\Arguments:
    \\  PATH                  Directory to list [default: .]
    \\
    \\Options:
    \\  -a, --all             Include hidden entries (names starting with '.')
    \\  -d, --dirs-only       List directories only
    \\  -s, --size            Show human-readable file sizes
    \\  -L, --depth <N>       Limit recursion to N levels (1 = direct children)
    \\  -c, --color <WHEN>    Colorize output: auto, always, never [default: auto]
    \\      --no-color        Alias for --color=never
    \\      --ascii           Use ASCII branch characters
    \\      --no-summary      Do not print the summary line
    \\  -h, --help            Print this help and exit
    \\  -V, --version         Print version information and exit
    \\
    \\Environment:
    \\  NO_COLOR              Disable colors when --color=auto
    \\  CLICOLOR_FORCE        Force colors when set to a non-zero value
    \\
    \\Exit status:
    \\  0  Success
    \\  1  Invalid command-line usage
    \\  2  The path could not be read
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectRun(argv: []const []const u8) !Config {
    const result = try parse(std.testing.allocator, argv);
    switch (result) {
        .command => |command| switch (command) {
            .run => |config| return config,
            else => return error.TestUnexpectedResult,
        },
        .failure => |failure| {
            std.testing.allocator.free(failure.message);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectCommandTag(argv: []const []const u8, expected: std.meta.Tag(Command)) !void {
    const result = try parse(std.testing.allocator, argv);
    switch (result) {
        .command => |command| try std.testing.expectEqual(expected, std.meta.activeTag(command)),
        .failure => |failure| {
            std.testing.allocator.free(failure.message);
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFailure(argv: []const []const u8, expected: []const u8) !void {
    const result = try parse(std.testing.allocator, argv);
    switch (result) {
        .failure => |failure| {
            defer std.testing.allocator.free(failure.message);
            try std.testing.expectEqualStrings(expected, failure.message);
        },
        .command => return error.TestUnexpectedResult,
    }
}

test "defaults" {
    const argv: []const []const u8 = &.{};
    const config = try expectRun(argv);

    try std.testing.expectEqualStrings(".", config.path);
    try std.testing.expect(!config.show_hidden);
    try std.testing.expect(!config.dirs_only);
    try std.testing.expect(!config.show_size);
    try std.testing.expect(!config.ascii);
    try std.testing.expect(config.summary);
    try std.testing.expectEqual(@as(?usize, null), config.max_depth);
    try std.testing.expectEqual(ColorMode.auto, config.color);
}

test "short boolean flags and path" {
    const argv: []const []const u8 = &.{ "-a", "-d", "-s", "src" };
    const config = try expectRun(argv);

    try std.testing.expect(config.show_hidden);
    try std.testing.expect(config.dirs_only);
    try std.testing.expect(config.show_size);
    try std.testing.expectEqualStrings("src", config.path);
}

test "long boolean flags" {
    const argv: []const []const u8 = &.{
        "--all",
        "--dirs-only",
        "--size",
        "--ascii",
        "--no-summary",
    };
    const config = try expectRun(argv);

    try std.testing.expect(config.show_hidden);
    try std.testing.expect(config.dirs_only);
    try std.testing.expect(config.show_size);
    try std.testing.expect(config.ascii);
    try std.testing.expect(!config.summary);
}

test "bundled short options" {
    const argv: []const []const u8 = &.{"-asd"};
    const config = try expectRun(argv);

    try std.testing.expect(config.show_hidden);
    try std.testing.expect(config.show_size);
    try std.testing.expect(config.dirs_only);
}

test "depth accepts separate, attached and inline forms" {
    const separate: []const []const u8 = &.{ "-L", "3" };
    try std.testing.expectEqual(@as(?usize, 3), (try expectRun(separate)).max_depth);

    const attached: []const []const u8 = &.{"-L4"};
    try std.testing.expectEqual(@as(?usize, 4), (try expectRun(attached)).max_depth);

    const long: []const []const u8 = &.{"--depth=2"};
    try std.testing.expectEqual(@as(?usize, 2), (try expectRun(long)).max_depth);
}

test "the last depth wins" {
    const argv: []const []const u8 = &.{ "-L", "1", "--depth=3" };
    try std.testing.expectEqual(@as(?usize, 3), (try expectRun(argv)).max_depth);
}

test "color modes" {
    const never: []const []const u8 = &.{ "--color", "never" };
    try std.testing.expectEqual(ColorMode.never, (try expectRun(never)).color);

    const always: []const []const u8 = &.{"--color=always"};
    try std.testing.expectEqual(ColorMode.always, (try expectRun(always)).color);

    const attached: []const []const u8 = &.{"-cauto"};
    try std.testing.expectEqual(ColorMode.auto, (try expectRun(attached)).color);

    const no_color: []const []const u8 = &.{"--no-color"};
    try std.testing.expectEqual(ColorMode.never, (try expectRun(no_color)).color);
}

test "resolveColor honors explicit modes" {
    try std.testing.expect(resolveColor(.always, .{ .no_color = "1", .stdout_is_tty = false }));
    try std.testing.expect(!resolveColor(.never, .{ .clicolor_force = "1", .stdout_is_tty = true }));
}

test "resolveColor follows the environment for auto" {
    try std.testing.expect(!resolveColor(.auto, .{}));
    try std.testing.expect(resolveColor(.auto, .{ .stdout_is_tty = true }));
    try std.testing.expect(!resolveColor(.auto, .{ .stdout_is_tty = true, .no_color = "1" }));
    // An empty NO_COLOR variable is ignored, matching the NO_COLOR convention.
    try std.testing.expect(resolveColor(.auto, .{ .stdout_is_tty = true, .no_color = "" }));
    try std.testing.expect(resolveColor(.auto, .{ .clicolor_force = "1" }));
    try std.testing.expect(!resolveColor(.auto, .{ .clicolor_force = "0", .stdout_is_tty = true }));
    try std.testing.expect(!resolveColor(.auto, .{ .term = "dumb", .stdout_is_tty = true }));
}

test "help and version commands" {
    try expectCommandTag(&.{"--help"}, .help);
    try expectCommandTag(&.{"-h"}, .help);
    try expectCommandTag(&.{"--version"}, .version);
    try expectCommandTag(&.{"-V"}, .version);
}

test "double dash ends option parsing" {
    const argv: []const []const u8 = &.{ "--", "-a" };
    const config = try expectRun(argv);

    try std.testing.expectEqualStrings("-a", config.path);
    try std.testing.expect(!config.show_hidden);
}

test "single dash is a path" {
    const argv: []const []const u8 = &.{"-"};
    const config = try expectRun(argv);
    try std.testing.expectEqualStrings("-", config.path);
}

test "rejects unknown options" {
    try expectFailure(&.{"--bogus"}, "unknown option '--bogus'");
    try expectFailure(&.{"-x"}, "unknown option '-x'");
}

test "rejects missing values" {
    try expectFailure(&.{"-L"}, "option '-L' requires a value");
    try expectFailure(&.{"--color"}, "option '--color' requires a value");
    try expectFailure(&.{"--depth="}, "option '--depth' requires a value");
    try expectFailure(&.{"--color="}, "option '--color' requires a value");
}

test "rejects invalid values" {
    try expectFailure(&.{"--depth", "0"}, "invalid depth '0': must be at least 1");
    try expectFailure(
        &.{ "--depth", "many" },
        "invalid depth 'many': expected a positive integer",
    );
    try expectFailure(
        &.{ "--depth", "999999999999999999999999999" },
        "invalid depth '999999999999999999999999999': expected a positive integer",
    );
    try expectFailure(
        &.{ "--color", "rainbow" },
        "invalid color mode 'rainbow': expected auto, always, or never",
    );
}

test "rejects values for boolean options" {
    try expectFailure(&.{"--all=yes"}, "option '--all' does not take a value");
    try expectFailure(&.{"--no-summary=1"}, "option '--no-summary' does not take a value");
    try expectFailure(&.{"--help=1"}, "option '--help' does not take a value");
}

test "rejects multiple paths" {
    try expectFailure(&.{ "one", "two" }, "only one PATH may be provided");
}

test "help text documents the interface" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try writeHelp(&output.writer);
    const text = output.written();
    try std.testing.expect(std.mem.startsWith(u8, text, "ztree " ++ version));
    try std.testing.expect(std.mem.indexOf(u8, text, "Usage: ztree [OPTIONS] [PATH]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--dirs-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--ascii") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "--no-summary") != null);
}
