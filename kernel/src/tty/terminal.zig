const std = @import("std");

const fblib = @import("framebuffer.zig");

const Framebuffer = fblib.Framebuffer;
const Color = fblib.Color;

// how many spaces a tab character should be replaced with
const TAB_WIDTH = 4;

pub const Terminal = struct {
    /// The underlying framebuffer
    framebuffer: Framebuffer,
    /// The width of the terminal
    width: usize,
    /// The height of the terminal
    height: usize,
    /// The foreground color
    fg: Color,
    /// The background color
    bg: Color,

    // linear position of the cursor
    cursor: usize,

    pub const Error = error{Unimplemented} || fblib.Framebuffer.Error;

    pub fn init(foreground_color: Color, background_color: Color) ?Terminal {
        const framebuffer = Framebuffer.init() orelse return null;
        framebuffer.fill(background_color);
        return Terminal{
            .framebuffer = framebuffer,
            // the terminal doesn't care about pixels, it cares about rows and columns of text, so
            // here we translate the pixel dimensions of the framebuffer into text dimensions
            .width = framebuffer.width / framebuffer.font.hdr.width,
            .height = framebuffer.height / framebuffer.font.hdr.height,
            .fg = foreground_color,
            .bg = background_color,
            .cursor = 0,
        };
    }

    pub fn print(self: *Terminal, bytes: []const u8) Error!void {
        for (bytes) |char| {
            switch (char) {
                '\r', '\n' => try self.newLine(),
                '\t' => try self.tab(),
                else => try self.writeChar(char),
            }
        }
    }

    fn writeChar(self: *Terminal, char: u8) Error!void {
        // if we've reached end of the line, move to next row
        if (self.cursor >= (self.width * self.height) - 1) {
            self.framebuffer.scroll(self.bg);
            // we now have an empty row at the bottom
            self.cursor -= self.width;
        }
        // get the current row and column in terms of pixels
        const x = (self.cursor % self.width) * self.framebuffer.font.hdr.width;
        const y = (self.cursor / self.width) * self.framebuffer.font.hdr.height;
        if (!std.ascii.isPrint(char)) {
            // unprintable characters get replaced with ?
            try self.framebuffer.drawChar('?', x, y, self.fg, self.bg);
        } else {
            try self.framebuffer.drawChar(char, x, y, self.fg, self.bg);
        }
        self.cursor += 1;
    }

    fn newLine(self: *Terminal) Error!void {
        while (true) {
            // add additional spaces to fill the row
            try self.writeChar(' ');
            if (self.cursor % self.width == 0) {
                break;
            }
        }
    }

    fn tab(self: *Terminal) Error!void {
        while (true) {
            // add additional spaces to fill the tab character
            try self.writeChar(' ');
            if (self.cursor % TAB_WIDTH == 0) {
                break;
            }
        }
    }
};
