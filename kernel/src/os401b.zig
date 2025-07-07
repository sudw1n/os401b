const std = @import("std");
const build_options = @import("build_options");
const limine = @import("limine");
const fblib = @import("lib/tty/framebuffer.zig");

pub const Color = fblib.Color;

// Framebuffer
pub const term = @import("lib/tty/terminal.zig");
pub const TtyError = term.TtyError;

// Serial logging
pub const serial = @import("lib/tty/serial.zig");
pub const SerialWriter = serial.SerialWriter;
pub const SerialError = serial.SerialError;

// CPU
pub const cpu = @import("lib/cpu.zig");
pub const registers = @import("lib/registers.zig");

// Interrupts
pub const gdt = @import("lib/gdt.zig");
pub const idt = @import("lib/interrupts/idt.zig");

// Memory management
pub const pmm = @import("lib/memory/pmm.zig");
pub const paging = @import("lib/memory/paging.zig");
pub const vmm_heap = @import("lib/memory/vmm_heap.zig");
pub const vmm = @import("lib/memory/vmm.zig");
pub const allocator = @import("lib/memory/allocator.zig");

// ACPI
pub const acpi = @import("lib/acpi.zig");

// APIC
pub const lapic = @import("lib/interrupts/lapic.zig");
pub const ioapic = @import("lib/interrupts/ioapic.zig");

// Timers
pub const pit = @import("lib/timers/pit.zig");
pub const hpet = @import("lib/timers/hpet.zig");
pub const lapic_timer = @import("lib/timers/lapic_timer.zig");
pub const tsc = @import("lib/timers/tsc.zig");

// Keyboard
pub const ps2 = @import("lib/keyboard/ps2.zig");

// Errors
pub const Error = TtyError || SerialError;

// Limine requests
export var start_marker: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var end_marker: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};
pub export var base_revision: limine.BaseRevision linksection(".limine_requests") = .init(3);
pub export var framebuffer_request: limine.FramebufferRequest linksection(".limine_requests") = .{};
pub export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};
pub export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};
pub export var executable_address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};

comptime {
    std.testing.refAllDecls(@This());
}
