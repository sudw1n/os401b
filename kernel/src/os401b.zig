const std = @import("std");
const limine = @import("limine");
const fblib = @import("lib/tty/framebuffer.zig");

pub const Color = fblib.Color;

pub const serial = @import("lib/tty/serial.zig");
pub const term = @import("lib/tty/terminal.zig");
pub const cpu = @import("lib/cpu.zig");
pub const gdt = @import("lib/gdt.zig");
pub const idt = @import("lib/interrupts/idt.zig");
pub const apic = @import("lib/interrupts/apic.zig");

pub const SerialWriter = serial.SerialWriter;

pub const SerialError = serial.SerialError;
pub const TtyError = term.TtyError;
pub const Error = TtyError || SerialError;

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

pub export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(3);

comptime {
    std.testing.refAllDecls(@This());
}
