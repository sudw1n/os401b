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
    shell() catch |err| {
        log.err("shell returned error: {}", .{err});
        @panic("shell errored out");
    };
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
    vmm.global_vmm.activate();
    try term.logStepEnd(true);

    const rsdp_response = lib.rsdp_request.response orelse @panic("failed to get RSDP response from Limine");
    if (rsdp_response.address == 0) {
        @panic("RSDP address is null");
    }

    try term.logStepBegin("Initializing the Kernel Heap Allocator", .{});
    lib.allocator.init(HEAP_SIZE);
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing APICs", .{});
    lapic.init();
    ioapic.init(rsdp_response);
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the Keyboard", .{});
    ps2.init(lib.allocator.allocator());
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the PIT Timer", .{});
    pit.init();
    try term.logStepEnd(true);

    try term.logStepBegin("Unmasking IRQ lines", .{});
    ioapic.routeVectors();
    try term.logStepEnd(true);
}

fn welcome() Error!void {
    try term.print("Welcome to ", .{});
    try term.colorPrint(lib.Color.BrightCyan, "OS401b v{s}!\n\n", .{KERNEL_VERSION});
}

// dummy shell for now
fn shell() Error!void {
    try term.colorPrint(lib.Color.BrightRed, "$ ", .{});
    const target_input = "start";
    var buffer: [target_input.len + 1]u8 = undefined;
    var input_count: usize = 0;
    while (true) {
        const c = ps2.ps2_driver.getChar() orelse {
            asm volatile ("pause");
            continue;
        };
        try term.print("{c}", .{c});
        if (c == '\n') {
            // end of input, check if it matches the target input
            buffer[input_count] = 0; // null-terminate the string
            if (std.mem.eql(u8, buffer[0..input_count], target_input)) {
                try term.print("\nStarting scheduler...\n", .{});
                break; // exit the loop to start the process
            } else {
                try term.print("Unknown command: ", .{});
                try term.print("{s}", .{buffer[0..input_count]});
                try term.print("\n", .{});
            }
            input_count = 0; // reset input count for next command
            try term.colorPrint(lib.Color.BrightRed, "$ ", .{});
        } else if (c == '\x0E' and input_count > 0) {
            // handle backspace
            input_count -= 1;
        } else if (input_count < target_input.len) {
            // store character in buffer
            buffer[input_count] = c;
            input_count += 1;
        }
    }
}
