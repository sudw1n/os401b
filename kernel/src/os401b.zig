const std = @import("std");
const limine = @import("limine");
const fblib = @import("lib/tty/framebuffer.zig");

pub const Color = fblib.Color;

pub const serial = @import("lib/tty/serial.zig");
pub const term = @import("lib/tty/terminal.zig");
pub const cpu = @import("lib/cpu.zig");
pub const gdt = @import("lib/gdt.zig");
pub const idt = @import("lib/interrupts/idt.zig");
pub const lapic = @import("lib/interrupts/lapic.zig");
pub const ioapic = @import("lib/interrupts/ioapic.zig");
pub const registers = @import("lib/registers.zig");
pub const pmm = @import("lib/memory/pmm.zig");
pub const paging = @import("lib/memory/paging.zig");
pub const acpi = @import("lib/acpi.zig");

pub const pit = @import("lib/timers/pit.zig");
pub const hpet = @import("lib/timers/hpet.zig");
pub const lapic_timer = @import("lib/timers/lapic_timer.zig");
pub const tsc = @import("lib/timers/tsc.zig");

pub const ps2 = @import("lib/keyboard/ps2.zig");

pub const heap = @import("lib/memory/heap.zig");

pub const SerialWriter = serial.SerialWriter;

pub const SerialError = serial.SerialError;
pub const TtyError = term.TtyError;
pub const Error = TtyError || SerialError;

export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

pub export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(3);
pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};

// Expose the memory map request to Limine in the required section.
pub export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};

pub export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};

pub export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};

pub export var executable_address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};

comptime {
    std.testing.refAllDecls(@This());
}
