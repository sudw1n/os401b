const std = @import("std");
const lib = @import("os401b");

const cpu = lib.cpu;
const term = lib.term;
const idt = lib.idt;
const apic = lib.apic;
const serial = lib.serial;

const Error = lib.Error;

const VERSION = "0.0.1";

/// Standard Library Options
pub const std_options = std.Options{
    .log_level = .debug,
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
    // perform initialization routines
    // initialize the serial console because all logging functionality depends on it
    serial.init() catch cpu.hlt(); // nothing we can log if this fails

    log.info("initializing framebuffer and tty", .{});
    try term.init(lib.Color.White, lib.Color.Black);
    log.info("initialized successfully", .{});

    try term.logStepBegin("Initializing the IDT", .{});
    idt.init();
    try term.logStepEnd(true);

    try term.logStepBegin("Initializing the APIC", .{});
    apic.init();
    try term.logStepEnd(true);
    try term.print("\n", .{});

    // print welcome message
    log.info("printing welcome message", .{});
    try welcome();

    // spawn a shell
    log.info("spawning the shell", .{});
    try shell();
}

fn welcome() Error!void {
    try term.print("Welcome to ", .{});
    try term.colorPrint(lib.Color.BrightCyan, "OS401b v{s}!\n\n", .{VERSION});
}

// dummy shell for now
fn shell() Error!void {
    try term.colorPrint(lib.Color.BrightRed, "$ ", .{});
}
