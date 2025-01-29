const std = @import("std");
const limine = @import("limine");
const font = @import("font.zig");

const Terminus = font.Terminus;

/// A pixel value
pub const Pixel = u32;

/// An enumeration of RGB hex color values.
pub const Color = enum(Pixel) {
    // Dark Background Colors
    Black = 0x1A1B26, // Base (Dark)
    BrightBlack = 0x292E42, // Darker foreground

    // Foreground (Text) Colors
    White = 0xC0CAF5, // Primary text color
    BrightWhite = 0xD7DAE0, // Brighter text

    // Primary Colors
    Red = 0xF7768E, // Error / Alerts
    BrightRed = 0xFF7A93,

    Green = 0x9ECE6A, // Success / OK
    BrightGreen = 0xB9F27C,

    Yellow = 0xE0AF68, // Warnings / Highlights
    BrightYellow = 0xFAE3B0,

    Blue = 0x7AA2F7, // Info / Cool elements
    BrightBlue = 0xA9B1D6,

    Magenta = 0xBB9AF7, // Purple (often for keywords)
    BrightMagenta = 0xC678DD,

    Cyan = 0x7DCFFF, // Accents / Standout elements
    BrightCyan = 0x89DDFF,

    pub fn toPixel(self: Color) Pixel {
        return @as(Pixel, @intFromEnum(self));
    }
};

pub const Framebuffer = struct {
    pub export var framebuffer_request: limine.FramebufferRequest = .{};

    pub const Error = error{
        OutOfBounds,
    };

    /// The underlying memory seen as an array of Pixels
    buffer: []volatile Pixel,
    /// Number of visible pixels in one row.
    width: usize,
    /// Number of visible rows in the framebuffer.
    height: usize,
    /// Number of bytes in each pixel
    pixelWidth: usize,
    /// Number of actual bytes in each row.
    ///
    /// This can be more than, but is at least equal to, `width * pixelWidth` because pitch includes padding or
    /// alignment between rows.
    pitch: usize,

    /// The font being used for drawing glyphs in the framebuffer
    font: Terminus,

    pub fn init() ?Framebuffer {
        if (framebuffer_request.response) |framebuffer_response| {
            if (framebuffer_response.framebuffer_count < 1) {
                return null;
            }
            const framebuffer = framebuffer_response.framebuffers()[0];
            // here we need to use the pitch because we need to include the actual allocated buffer
            // including the unused padding bytes
            const fb_len = (framebuffer.height * framebuffer.pitch) / @sizeOf(Pixel);
            const buffer: []volatile Pixel = @as([*]volatile Pixel, @ptrCast(@alignCast(framebuffer.address)))[0..fb_len];
            return Framebuffer{
                .buffer = buffer,
                .width = framebuffer.width,
                .height = framebuffer.height,
                .pixelWidth = framebuffer.bpp / 8,
                .pitch = framebuffer.pitch,
                .font = Terminus.init(),
            };
        }
        return null;
    }

    pub fn fill(self: Framebuffer, color: Color) void {
        @memset(self.buffer, color.toPixel());
    }

    pub fn scroll(self: Framebuffer, bg_color: Color) void {
        const screen_size = self.width * self.height;
        const pixels_per_line = self.width * self.font.hdr.height;

        // treat the buffer as an array of u64s, so we can copy 2 pixels at a time
        const buffer64: [*]volatile u64 = @ptrCast(@alignCast(self.buffer.ptr));

        // since we're copying 2 pixels at a time, we need to divide the number of pixels by 2
        // and we're not copying the first line, so we subtract the number of pixels in one line
        const iterations = (screen_size - pixels_per_line) / 2;

        // Copy the entire screen (except the first line) one line up.
        for (0..iterations) |i| {
            // since we're copying 2 pixels at a time, there will be (pixels_per_line / 2) pixels
            // between the two lines
            buffer64[i] = buffer64[i + (pixels_per_line / 2)];
        }

        // Clear the last line.
        @memset(self.buffer[screen_size - pixels_per_line .. screen_size], bg_color.toPixel());
    }

    /// Draw the given character corresponding with the given foreground color otherwise will be the
    /// background color.
    pub fn drawChar(self: Framebuffer, character: u8, x: usize, y: usize, fg: Color, bg: Color) Error!void {
        const bitmap = self.font.getBitmap(character);
        const fontHeader = self.font.hdr;
        // iterate over the rows
        for (0..fontHeader.height) |i| {
            for (0..fontHeader.width) |j| {
                const bitOffset: u3 = @truncate(((fontHeader.width - 1) - j));
                const mask = @as(u8, 1) << bitOffset;

                const color = if ((bitmap[i] & mask) != 0) fg else bg;
                try self.putColor(x + j, y + i, color);
            }
        }
    }

    /// Get the offset within the buffer for the given (x, y) pixel coordinates.
    fn getOffset(self: Framebuffer, x: usize, y: usize) Error!usize {
        const offset = (y * self.width) + x;
        if (offset >= self.buffer.len) {
            return Error.OutOfBounds;
        }
        return offset;
    }

    /// Get the color of the current pixel at given x and y
    pub fn getColor(self: Framebuffer, x: usize, y: usize) Error!Color {
        const offset = try self.getOffset(x, y);
        const pixel = self.buffer[offset];
        return @enumFromInt(pixel);
    }

    /// Color the current pixel with given `color` at given x and y
    pub fn putColor(self: Framebuffer, x: usize, y: usize, color: Color) Error!void {
        const offset = try self.getOffset(x, y);
        self.buffer[offset] = color.toPixel();
    }
};
