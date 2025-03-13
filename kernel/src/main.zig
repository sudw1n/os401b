const std = @import("std");
const lib = @import("os401b");

const cpu = lib.cpu;
const term = lib.term;
const idt = lib.idt;
const apic = lib.apic;

const Error = lib.Error;

const VERSION = "0.0.1";

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    // TODO: find a way to maintain a single SerialWriter instance so that we don't have to
    // do this so many times
    const writer = lib.SerialWriter.init() catch cpu.hlt();

    // Print the panic message to the serial console.
    writer.print("Kernel Panic: {s}\n", .{msg}) catch {};

    _ = error_return_trace;
    _ = ret_addr;

    // Halt the CPU indefinitely.
    cpu.hlt();
}

export fn _start() callconv(.C) noreturn {
    if (!lib.base_revision.is_supported()) {
        cpu.hlt();
    }

    kmain() catch |err| {
        const writer = lib.SerialWriter.init() catch cpu.hlt();
        writer.print("Kernel terminated with `{any}`\n", .{err}) catch {};
    };

    cpu.hlt();
}

pub fn kmain() Error!void {
    // perform initialization routines
    try term.init(lib.Color.White, lib.Color.Black);
    try idt.init();
    try apic.init();

    try term.print("\n", .{});

    // print welcome message
    try welcome();

    // spawn a shell
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
