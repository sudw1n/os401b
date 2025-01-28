const std = @import("std");

const PSF_FONT_MAGIC = 0x864ab572;

pub const Psf2Header = packed struct {
    // magic bytes to identify PSF
    magic: u32,
    // zero
    version: u32,
    // offset of bitmaps in file, 32
    headersize: u32,
    // 0 if there's no unicode table
    flags: u32,
    // number of glyphs
    numglyph: u32,
    // size of each glyph
    bytesperglyph: u32,
    // height in pixels
    height: u32,
    // width in pixels
    width: u32,
};

pub const Terminus = struct {
    const fontPath = "assets/Lat2-Terminus16.psfu";
    const rawFontData: []const u8 = @embedFile(fontPath);

    hdr: Psf2Header,
    glyphs: []const u8,

    pub fn init() Terminus {
        const rawhdr = @as(*const Psf2Header, @ptrCast(@alignCast(rawFontData.ptr)));
        const hdr: Psf2Header = rawhdr.*;
        std.debug.assert(hdr.magic == PSF_FONT_MAGIC);
        return Terminus{
            .hdr = hdr,
            .glyphs = rawFontData[hdr.headersize..],
        };
    }

    pub fn getBitmap(self: Terminus, character: u8) []const u8 {
        const glyphStartOffset = character * self.hdr.bytesperglyph;
        const glyphEndOffset = glyphStartOffset + self.hdr.bytesperglyph;
        return self.glyphs[glyphStartOffset..glyphEndOffset];
    }
};
