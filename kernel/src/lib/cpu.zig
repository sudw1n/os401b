const gdt = @import("interrupts/gdt.zig");

pub const SystemTableRegister = packed struct {
    limit: u16,
    base: u64,
};

pub fn hlt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn cli() void {
    asm volatile ("cli");
}

pub fn sti() void {
    asm volatile ("sti");
}

pub fn lidt(idtr: SystemTableRegister) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
    );
}
