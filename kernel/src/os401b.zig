const std = @import("std");
const limine = @import("limine");

const fontlib = @import("lib/tty/font.zig");
const fblib = @import("lib/tty/framebuffer.zig");

pub const Psf2Header = fontlib.Psf2Header;
pub const Terminus = fontlib.Terminus;

pub const Pixel = fblib.Pixel;
pub const Color = fblib.Color;
pub const Framebuffer = fblib.Framebuffer;

pub const terminal = @import("lib/tty/terminal.zig");
pub const TerminalWriter = terminal.TerminalWriter;

pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };

comptime {
    std.testing.refAllDecls(@This());
}
