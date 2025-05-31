const std = @import("std");
const limine = @import("limine");

const lib = @import("../../os401b.zig");
const fblib = @import("framebuffer.zig");

const Framebuffer = fblib.Framebuffer;
const Color = fblib.Color;

pub const TerminalError = error{
    LogStepFail,
    Unimplemented,
    PrintError,
};

pub const TtyError = TerminalError || Framebuffer.Error;

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

var writer: TerminalWriter = TerminalWriter{};

/// Initialize the terminal
pub fn init(raw_framebuffer: *limine.FramebufferResponse, foreground_color: Color, background_color: Color) TtyError!void {
    framebuffer = try Framebuffer.init(raw_framebuffer);
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
pub fn print(comptime fmt: []const u8, args: anytype) TtyError!void {
    std.fmt.format(writer, fmt, args) catch return TtyError.PrintError;
}

/// Write to screen with standard formatting, with the specified color
pub fn colorPrint(color: Color, comptime fmt: []const u8, args: anytype) TtyError!void {
    const old_fg = fg;

    // set the new colour
    fg = color;

    try print(fmt, args);

    // restore the old foreground color
    fg = old_fg;
}

/// Print a kernel loading step message
pub fn logStepBegin(comptime fmt: []const u8, args: anytype) TtyError!void {
    try colorPrint(Color.Blue, ">>> ", .{});
    try print(fmt ++ "... ", args);
}

/// For printing out end of a kernel loading step
pub fn logStepEnd(success: bool) TtyError!void {
    try print("[", .{});
    const fmt = "{s: ^6}";
    if (success) {
        try colorPrint(Color.BrightGreen, fmt, .{"OK"});
    } else {
        try colorPrint(Color.BrightRed, fmt, .{"FAIL"});
    }
    try print("]\n", .{});
    if (!success) return TtyError.LogStepFail;
}

fn writeStr(bytes: []const u8) TtyError!void {
    for (bytes) |char| {
        switch (char) {
            '\r', '\n' => try newline(),
            '\t' => try tab(),
            '\x0E' => try backspace(),
            else => try writeChar(char),
        }
    }
}

fn writeChar(char: u8) TtyError!void {
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

// TODO: there's a small bug here. if we backspace at the beginning of a line, we can't type anymore
// characters.
fn backspace() TtyError!void {
    // If we're already at the very beginning, go to the previous line
    if (cursor == 0) return;

    // Move the cursor back one position:
    cursor -= 1;

    // Compute the pixel‐coordinates of the “new” cursor location:
    const col = cursor % width;
    const row = cursor / width;
    const x = col * framebuffer.font.hdr.width;
    const y = row * framebuffer.font.hdr.height;

    // Draw a space there (in fg/bg) to “erase” the old character:
    try framebuffer.drawChar(' ', x, y, fg, bg);
}

fn newline() TtyError!void {
    while (true) {
        // add additional spaces to fill the row
        try writeChar(' ');
        if (cursor % width == 0) {
            break;
        }
    }
}

fn tab() TtyError!void {
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
    pub const Error = TtyError;

    pub fn write(_: Self, bytes: []const u8) Error!usize {
        try writeStr(bytes);
        return bytes.len;
    }

    pub fn writeByte(self: Self, byte: u8) Error!void {
        _ = try self.write(&.{byte});
    }

    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) Error!void {
        for (0..n) |_| {
            _ = try self.write(bytes);
        }
    }

    pub fn writeAll(self: Self, bytes: []const u8) Error!void {
        _ = try self.write(bytes);
    }
};
