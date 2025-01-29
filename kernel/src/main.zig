const std = @import("std");
const lib = @import("os401b");

const VERSION = "0.0.1";

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
    try lib.term.init(lib.Color.White, lib.Color.Black);
    try lib.term.print("Welcome to ", .{});
    try lib.term.colorPrint(lib.Color.Cyan, "OS401b v{s}\n\n", .{VERSION});
    try lib.term.colorPrint(lib.Color.Red, "# ", .{});
}
