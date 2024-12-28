const std = @import("std");

const fblib = @import("framebuffer.zig");

const Framebuffer = fblib.Framebuffer;
const Color = fblib.Color;

pub const Terminal = struct {
    framebuffer: Framebuffer,
    width: usize,
    height: usize,
    fg: Color,
    bg: Color,

    // current row
    row: usize,
    // current column
    col: usize,

    pub const Error = error{Unimplemented} || fblib.Framebuffer.Error;

    // 50x50
    pub fn init(width: usize, height: usize, foreground_color: Color, background_color: Color) ?Terminal {
        const framebuffer = Framebuffer.init() orelse return null;
        framebuffer.fill(background_color);
        return Terminal{
            .framebuffer = framebuffer,
            .width = width,
            .height = height,
            .fg = foreground_color,
            .bg = background_color,
            .row = 0,
            .col = 0,
        };
    }

    pub fn print(self: *Terminal, bytes: []const u8) Error!void {
        for (bytes) |char| {
            if (!std.ascii.isPrint(char)) {
                return Error.Unimplemented;
            }
            switch (char) {
                '\r', '\n' => {
                    self.row += 1;
                    self.col = 0;
                    continue;
                },
                else => {
                    try self.framebuffer.drawChar(char, self.col + self.width, self.row + self.height, self.fg, self.bg);
                    self.col += self.framebuffer.font.hdr.width;
                },
            }
        }
    }
};
