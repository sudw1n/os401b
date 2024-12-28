const std = @import("std");
const limine = @import("limine");
const fblib = @import("tty/framebuffer.zig");
const terminallib = @import("tty/terminal.zig");

const Color = fblib.Color;
const Terminal = terminallib.Terminal;

pub export var base_revision: limine.BaseRevision = .{ .revision = 3 };

fn hcf() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

export fn _start() callconv(.C) noreturn {
    if (!base_revision.is_supported()) {
        hcf();
    }

    kmain() catch hcf();

    hcf();
}

pub fn kmain() !void {
    var terminal = Terminal.init(50, 50, Color.White, Color.Black) orelse hcf();
    try terminal.print("Hello world!");
}
