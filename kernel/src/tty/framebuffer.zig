const std = @import("std");
const limine = @import("limine");
const font = @import("font.zig");

/// A pixel value
pub const Pixel = u32;

/// An enumeration of RGB hex color values.
pub const Color = enum(Pixel) {
    Red = 0xFF0000,
    Green = 0x00FF00,
    Blue = 0x0000FF,
    White = 0xFFFFFF,
    Black = 0x000000,
    Yellow = 0xFFFF00,
    Cyan = 0x00FFFF,
    Magenta = 0xFF00FF,
    Gray = 0x808080,
    Orange = 0xFFA500,
    Pink = 0xFFC0CB,

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
    /// width in pixels
    width: usize,
    /// height in pixels
    height: usize,

    font: font.Terminus,

    pub fn init() ?Framebuffer {
        if (framebuffer_request.response) |framebuffer_response| {
            if (framebuffer_response.framebuffer_count < 1) {
                return null;
            }
            const framebuffer = framebuffer_response.framebuffers()[0];
            const fb_len = framebuffer.width * framebuffer.height;
            const buffer: []volatile Pixel = @as([*]volatile Pixel, @ptrCast(@alignCast(framebuffer.address)))[0..fb_len];
            return Framebuffer{
                .buffer = buffer,
                .width = framebuffer.width,
                .height = framebuffer.height,
                .font = font.Terminus.init(),
            };
        }
        return null;
    }

    pub fn fill(self: Framebuffer, color: Color) void {
        @memset(self.buffer, color.toPixel());
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
                try self.putPixel(x + j, y + i, color);
            }
        }
    }

    /// Color the current pixel with given `color` at given x and y
    pub fn putPixel(self: Framebuffer, x: usize, y: usize, color: Color) Error!void {
        const offset = y * self.width + x;
        if (offset >= self.buffer.len) {
            return Error.OutOfBounds;
        }
        self.buffer[offset] = color.toPixel();
    }
};
