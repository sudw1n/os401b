const std = @import("std");
const limine = @import("limine");
const fblib = @import("tty/framebuffer.zig");

const Color = fblib.Color;
const terminal = @import("tty/terminal.zig");

pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };

fn hcf() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    hcf();
}

export fn _start() callconv(.C) noreturn {
    if (!base_revision.is_supported()) {
        hcf();
    }

    kmain() catch hcf();

    hcf();
}

pub fn kmain() !void {
    terminal.init(Color.White, Color.Blue) catch hcf();
    try terminal.print("Welcome to OS401b!\n\n", .{});
    try terminal.print("$ ", .{});
}
