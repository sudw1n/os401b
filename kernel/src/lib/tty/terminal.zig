const std = @import("std");

const fblib = @import("framebuffer.zig");

const Framebuffer = fblib.Framebuffer;
const Color = fblib.Color;

pub const Error = error{ Unimplemented, FramebufferInitFailed } || fblib.Framebuffer.Error;
const TerminalError = Error;

/// The underlying framebuffer
var framebuffer: Framebuffer = undefined;
/// The width of the terminal
var width: usize = undefined;
/// The height of the terminal
var height: usize = undefined;
/// The foreground color
var fg: Color = undefined;
/// The background color
var bg: Color = undefined;

// linear position of the cursor
var cursor: usize = undefined;

// how many spaces a tab character should be replaced with
const TAB_WIDTH = 4;

/// Initialize the terminal
pub fn init(foreground_color: Color, background_color: Color) Error!void {
    framebuffer = Framebuffer.init() orelse return Error.FramebufferInitFailed;
    framebuffer.fill(background_color);
    // the terminal doesn't care about pixels, it cares about rows and columns of text, so
    // here we translate the pixel dimensions of the framebuffer into text dimensions
    width = framebuffer.width / framebuffer.font.hdr.width;
    height = framebuffer.height / framebuffer.font.hdr.height;
    fg = foreground_color;
    bg = background_color;
    cursor = 0;
}

/// Write to screen with standard formatting
pub fn print(comptime fmt: []const u8, args: anytype) !void {
    try std.fmt.format(@as(TerminalWriter, undefined), fmt, args);
}

/// Write to screen with standard formatting, with the specified color
pub fn colorPrint(color: Color, comptime fmt: []const u8, args: anytype) !void {
    const old_fg = fg;

    // set the new colour
    fg = color;

    try std.fmt.format(@as(TerminalWriter, undefined), fmt, args);

    // restore the old foreground color
    fg = old_fg;
}

fn writeStr(bytes: []const u8) Error!void {
    for (bytes) |char| {
        switch (char) {
            '\r', '\n' => try newLine(),
            '\t' => try tab(),
            else => try writeChar(char),
        }
    }
}

fn writeChar(char: u8) Error!void {
    // if we've reached end of the line, move to next row
    if (cursor >= (width * height) - 1) {
        framebuffer.scroll(bg);
        // we now have an empty row at the bottom
        cursor -= width;
    }
    // get the current row and column in terms of pixels
    const x = (cursor % width) * framebuffer.font.hdr.width;
    const y = (cursor / width) * framebuffer.font.hdr.height;
    if (!std.ascii.isPrint(char)) {
        // unprintable characters get replaced with ?
        try framebuffer.drawChar('?', x, y, fg, bg);
    } else {
        try framebuffer.drawChar(char, x, y, fg, bg);
    }
    cursor += 1;
}

fn newLine() Error!void {
    while (true) {
        // add additional spaces to fill the row
        try writeChar(' ');
        if (cursor % width == 0) {
            break;
        }
    }
}

fn tab() Error!void {
    while (true) {
        // add additional spaces to fill the tab character
        try writeChar(' ');
        if (cursor % TAB_WIDTH == 0) {
            break;
        }
    }
}

/// Writer interface for the terminal
pub const TerminalWriter = struct {
    const Self = @This();
    pub const Error = TerminalError;

    pub fn write(_: Self, bytes: []const u8) !usize {
        try writeStr(bytes);
        return bytes.len;
    }

    pub fn writeByte(self: Self, byte: u8) !void {
        _ = try self.write(&.{byte});
    }

    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) !void {
        for (0..n) |_| {
            _ = try self.write(bytes);
        }
    }

    pub fn writeAll(self: Self, bytes: []const u8) !void {
        _ = try self.write(bytes);
    }
};
