//! ANSI SGR escape sequences used to colorize tree output.
//!
//! Styles are plain string constants so the renderer can emit them with
//! `writer.writeAll` and no allocation. An empty style means "terminal
//! default", which lets the renderer skip writing a reset sequence.
//!
//! Only the styles actually used by `tree.zig` are declared here: keeping the
//! palette small avoids dead constants drifting out of sync with the output.

const std = @import("std");

/// Restores the terminal's default attributes.
pub const reset = "\x1b[0m";
/// Used for the root label of the tree.
pub const bold = "\x1b[1m";
/// Used for secondary information such as sizes, link targets and summary.
pub const dim = "\x1b[2m";

pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const gray = "\x1b[90m";

/// Bold blue makes directories stand out without implying "error".
pub const directory = "\x1b[1;34m";
/// Files inherit the terminal foreground; the empty style skips reset codes.
pub const file = "";
pub const symlink = cyan;
/// Special files (sockets, pipes, devices, ...).
pub const other = magenta;
/// Branch connectors are intentionally low-contrast.
pub const branch = gray;
pub const size = dim;
pub const summary = dim;

test "styles are valid ANSI SGR sequences" {
    inline for (.{
        reset,   bold,   dim,     magenta, cyan,
        gray,    directory, file, symlink, other,
        branch,  size,   summary,
    }) |style| {
        if (style.len == 0) continue;
        try std.testing.expect(std.mem.startsWith(u8, style, "\x1b["));
        try std.testing.expect(std.mem.endsWith(u8, style, "m"));
    }
}
