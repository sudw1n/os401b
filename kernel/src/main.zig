const std = @import("std");
const limine = @import("limine");

pub export const base_revision: limine.BaseRevision = .{ .revision = 3 };

inline fn hcf() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

export fn _start() callconv(.C) noreturn {
    if (!base_revision.is_supported()) {
        hcf();
    }

    if (framebuffer_request.response) |framebuffer_response| {
        if (framebuffer_response.framebuffer_count < 1) {
            hcf();
        }

        const framebuffer = framebuffer_response.framebuffers()[0];

        for (0..100) |i| {
            const pixel_offset = i * framebuffer.pitch + i * 4;
            @as(*u32, @ptrCast(@alignCast((framebuffer.address + pixel_offset)))).* = 0xffffffff;
        }
    }

    hcf();
}
