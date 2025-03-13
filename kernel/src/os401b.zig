const std = @import("std");
const limine = @import("limine");

const fblib = @import("lib/tty/framebuffer.zig");
const seriallib = @import("lib/tty/serial.zig");

pub const Color = fblib.Color;

pub const term = @import("lib/tty/terminal.zig");

pub const SerialWriter = seriallib.SerialWriter;

pub const TtyError = term.TtyError;

pub const Error = TtyError;

pub const cpu = @import("lib/cpu.zig");
pub const idt = @import("lib/interrupts/idt.zig");

pub const apic = @import("lib/interrupts/apic.zig");

pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };

comptime {
    std.testing.refAllDecls(@This());
}
