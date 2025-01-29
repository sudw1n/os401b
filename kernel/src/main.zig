const std = @import("std");
const lib = @import("os401b");

const VERSION = "0.0.1";

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    lib.cpu.hlt();
}

export fn _start() callconv(.C) noreturn {
    if (!lib.base_revision.is_supported()) {
        lib.cpu.hlt();
    }

    kmain() catch lib.cpu.hlt();

    lib.cpu.hlt();
}

pub fn kmain() !void {
    // perform initialization routines
    try lib.term.init(lib.Color.White, lib.Color.Black);
    try lib.idt.init();

    try lib.term.print("\n", .{});

    // print welcome message
    try welcome();

    // spawn a shell
    try shell();
}

fn welcome() !void {
    try lib.term.print("Welcome to ", .{});
    try lib.term.colorPrint(lib.Color.BrightCyan, "OS401b v{s}!\n\n", .{VERSION});
}

// dummy shell for now
fn shell() !void {
    try lib.term.colorPrint(lib.Color.BrightRed, "# ", .{});
}
