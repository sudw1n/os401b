const gdt = @import("gdt.zig");

pub const SystemTableRegister = packed struct {
    limit: u16,
    base: u64,
};

pub inline fn hlt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub inline fn cli() void {
    asm volatile ("cli");
}

pub inline fn sti() void {
    asm volatile ("sti");
}

pub inline fn lidt(idtr: SystemTableRegister) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
    );
}
