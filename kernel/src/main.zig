const std = @import("std");
const lib = @import("os401b");

fn hcf() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    hcf();
}

export fn _start() callconv(.C) noreturn {
    if (!lib.base_revision.is_supported()) {
        hcf();
    }

    kmain() catch hcf();

    hcf();
}

pub fn kmain() !void {
    lib.terminal.init(lib.Color.White, lib.Color.Blue) catch hcf();
    try lib.terminal.print("Welcome to OS401b!\n\n", .{});
    try lib.terminal.print("$ ", .{});
}
