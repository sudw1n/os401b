const std = @import("std");
const lib = @import("os401b");
const build_options = @import("build_options");

const term = lib.term;
const serial = lib.serial;

const cpu = lib.cpu;
const registers = lib.registers;

const gdt = lib.gdt;
const idt = lib.idt;

const pmm = lib.pmm;
const paging = lib.paging;
const vmm_heap = lib.vmm_heap;
const vmm = lib.vmm;

const acpi = lib.acpi;

const lapic = lib.lapic;
const ioapic = lib.ioapic;

const pit = lib.pit;
const hpet = lib.hpet;
const lapic_timer = lib.lapic_timer;
const tsc = lib.tsc;
const Hpet = lib.hpet.Hpet;

const ps2 = lib.ps2;

const Error = lib.Error;

const KERNEL_VERSION = "0.0.1";

const HEAP_SIZE = 0x21000;

/// Standard Library Options
pub const std_options = std.Options{
    .log_level = .debug,
    .log_scope_levels = &.{
        .{
            .scope = .pmm,
            .level = .info,
        },
        .{
            .scope = .paging,
            .level = .info,
        },
        .{
            .scope = .vmm,
            .level = .info,
        },
        .{
            .scope = .lapic,
            .level = .info,
        },
        .{
            .scope = .acpi,
            .level = .info,
        },
        .{
            .scope = .idt,
            .level = .info,
        },
        .{
            .scope = .pit,
            .level = .info,
        },
    },
    .logFn = serial.log,
};

const log = std.log.scoped(.kernel);

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    log.err("kernel panic: {s}", .{msg});

    _ = error_return_trace;
    _ = ret_addr;

    // Halt the CPU indefinitely.
    cpu.hlt();
}

export fn _start() noreturn {
    if (!lib.base_revision.isSupported()) {
        @panic("Base revision not supported");
    }

    kmain() catch {};

    cpu.hlt();
}

pub fn kmain() Error!void {
    try init();
    try term.print("\n", .{});

    // print welcome message
    log.info("printing welcome message", .{});
    try welcome();

    // spawn a shell
    log.info("spawning the shell", .{});
    try shell();
}

fn init() Error!void {
    // perform initialization routines
    // initialize the serial console because all logging functionality depends on it
    serial.init() catch cpu.hlt(); // nothing we can log if this fails

    const framebuffer = lib.framebuffer_request.response orelse @panic("failed to get framebuffer response from Limine");
    log.info("initializing framebuffer and tty", .{});
    try term.init(framebuffer, lib.Color.White, lib.Color.Black);
    log.info("initialized successfully", .{});

    try term.logStepBegin("Initializing the GDT", .{});
    gdt.init();
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the IDT", .{});
    idt.init();
    try term.logStepEnd(true);

    const memmap = lib.memmap_request.response orelse @panic("failed to get memory map response from Limine");
    if (memmap.entry_count == 0) {
        @panic("No memory map entries found from Limine");
    }
    const executable_address_response = lib.executable_address_request.response orelse @panic("failed to get executable address response from Limine");

    try term.logStepBegin("Initializing the Physical Memory Manager", .{});
    pmm.init(memmap, executable_address_response);
    try term.logStepEnd(true);

    try term.logStepBegin("Setting up Virtual Memory Manager and Kernel Page Tables", .{});
    vmm_heap.init();
    vmm.init(memmap, executable_address_response);
    // switch to the kernel's newly setup PML4
    vmm.global_vmm.switchTo();
    try term.logStepEnd(true);

    const rsdp_response = lib.rsdp_request.response orelse @panic("failed to get RSDP response from Limine");
    if (rsdp_response.address == 0) {
        @panic("RSDP address is null");
    }

    try term.logStepBegin("Initializing APICs", .{});
    lapic.init();
    ioapic.init(rsdp_response);
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the Keyboard", .{});
    ps2.init();
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the PIT Timer", .{});
    pit.init();
    try term.logStepEnd(true);

    try term.logStepBegin("Unmasking IRQ lines", .{});
    ioapic.routeVectors();
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the Kernel Heap Allocator", .{});
    lib.allocator.init(HEAP_SIZE);
    defer lib.allocator.global_allocator.deinit();
    try term.logStepEnd(true);

    const kernel_allocator = lib.allocator.allocator();
    _ = kernel_allocator;
}

fn welcome() Error!void {
    try term.print("Welcome to ", .{});
    try term.colorPrint(lib.Color.BrightCyan, "OS401b v{s}!\n\n", .{KERNEL_VERSION});
}

// dummy shell for now
fn shell() Error!void {
    try term.colorPrint(lib.Color.BrightRed, "$ ", .{});
}
