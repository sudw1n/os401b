const std = @import("std");
const limine = @import("limine");

const fontlib = @import("lib/tty/font.zig");
const fblib = @import("lib/tty/framebuffer.zig");
const gdtlib = @import("lib/gdt.zig");
const seriallib = @import("lib/tty/serial.zig");

pub const Psf2Header = fontlib.Psf2Header;
pub const Terminus = fontlib.Terminus;

pub const Pixel = fblib.Pixel;
pub const Color = fblib.Color;
pub const Framebuffer = fblib.Framebuffer;

pub const term = @import("lib/tty/terminal.zig");
pub const TerminalWriter = term.TerminalWriter;
pub const TerminalError = term.TerminalError;

pub const SerialWriter = seriallib.SerialWriter;
pub const SerialError = seriallib.SerialError;

pub const Error = TerminalError || SerialError;

pub const cpu = @import("lib/cpu.zig");
pub const idt = @import("lib/interrupts/idt.zig");

pub const apic = @import("lib/interrupts/apic.zig");

pub const SegmentSelector = gdtlib.SegmentSelector;
pub const Dpl = gdtlib.Dpl;

pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };

comptime {
    std.testing.refAllDecls(@This());
}
