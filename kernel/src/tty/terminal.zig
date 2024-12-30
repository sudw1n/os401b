const std = @import("std");

const fblib = @import("framebuffer.zig");

const Framebuffer = fblib.Framebuffer;
const Color = fblib.Color;

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

    // current row
    row: usize,
    // current column
    col: usize,

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
            .row = 0,
            .col = 0,
        };
    }

    pub fn print(self: *Terminal, bytes: []const u8) Error!void {
        for (bytes) |char| {
            switch (char) {
                '\r', '\n' => try self.newLine(),
                else => {
                    if (!std.ascii.isPrint(char)) {
                        return Error.Unimplemented;
                    }
                    try self.framebuffer.drawChar(char, self.col, self.row, self.fg, self.bg);
                    // increment column by width of the character; move to next column
                    self.col += self.framebuffer.font.hdr.width;
                    // if we've reached end of the line, move to next row
                    if (self.col >= self.width) {
                        self.col = 0;
                        self.row += self.framebuffer.font.hdr.height;

                        // if we reach the last line, trigger scroll
                        if (self.row >= self.height) {
                            try self.scroll();
                        }
                    }
                },
            }
        }
    }

    fn newLine(self: *Terminal) Error!void {
        // check if the current row is the last row
        if (self.row == self.height - 1) {
            // scroll the terminal
            try self.scroll();
        } else {
            // move to the next row
            self.row += self.framebuffer.font.hdr.height;
        }
        // reset the column
        self.col = 0;
    }

    fn scroll(self: *Terminal) Error!void {
        // copy all of the rows upwards, since the first row is going to be overridden by the second
        // one we start the indexing of the rows from 1
        for (1..self.height) |y| {
            for (0..self.width) |x| {
                const color = try self.framebuffer.getColor(x, y);
                try self.framebuffer.putColor(x, y - 1, color);
            }
        }

        // clear the last row
        try self.clearRow(self.height - 1);

        // reset the column and row
        self.col = 0;
        self.row = self.height - 1;
    }

    fn clearRow(self: *Terminal, row: usize) Error!void {
        for (0..self.width) |col| {
            try self.framebuffer.putColor(col, row, self.bg);
        }
    }
};
