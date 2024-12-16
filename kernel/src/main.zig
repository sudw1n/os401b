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

    kmain();
}

pub fn kmain() noreturn {
    hcf();
}
