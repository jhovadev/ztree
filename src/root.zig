//! ztree - a small, dependency-free recursive directory tree lister.
//!
//! The executable lives in `main.zig`; this file is the public library
//! surface, which makes the tree renderer and CLI parser reusable (and
//! testable) independently of the process entry point.

const std = @import("std");

pub const cli = @import("cli.zig");
pub const colors = @import("colors.zig");
pub const tree = @import("tree.zig");

/// Keep this in sync with `build.zig.zon`.
pub const version = cli.version;

test {
    std.testing.refAllDecls(@This());
}
