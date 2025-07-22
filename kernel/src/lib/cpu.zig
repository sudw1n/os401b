const std = @import("std");
const gdt = @import("gdt.zig");
const registers = @import("registers.zig");

// TODO: modularize this. maybe registers stuff in a separate module?

pub const SystemTableRegister = packed struct {
    limit: u16,
    base: u64,
};

/// Tell the CPU to stop fetching instructions.
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

pub inline fn iret() noreturn {
    asm volatile ("iret");
    unreachable;
}

pub fn lgdt(gdtr: SystemTableRegister) void {
    asm volatile ("lgdt (%[gdt])"
        :
        : [gdt] "r" (&gdtr),
    );
}

pub fn lidt(idtr: SystemTableRegister) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
    );
}

pub fn in(comptime T: type, port: u16) T {
    return switch (T) {
        u8 => asm volatile ("inb %[port], %[result]"
            // the -> T syntax specifies that the expression returns a value, whose type is given by
            // T
            : [result] "={al}" (-> T),
              // the constraint allows the given port to be an immediate value if comptime known and
              // between 0-255, or supplied in the dx register
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> T),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("The `in` instruction only supports u8, u16 or u32 but found: " ++ @typeName(T)),
    };
}

pub inline fn out(comptime T: type, port: u16, data: T) void {
    switch (T) {
        u8 => asm volatile ("outb %[data], %[port]"
            : // no outputs
            : [data] "{al}" (data),
              [port] "{dx}" (port),
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            : // no outputs
            : [data] "{ax}" (data),
              [port] "{dx}" (port),
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            : // no outputs
            : [data] "{eax}" (data),
              [port] "{dx}" (port),
        ),
        else => @compileError("The `out` instruction only supports u8, u16 or u32 but found: " ++ @typeName(T)),
    }
}

pub inline fn invlpg(addr: u64) void {
    asm volatile (
        \\ invlpg (%[page])
        :
        : [page] "r" (addr),
        : "memory"
    );
}

pub inline fn rdtsc() u64 {
    var high: u32 = 0;
    var low: u32 = 0;
    asm volatile ("rdtsc"
        : [eax] "={eax}" (low),
          [edx] "={edx}" (high),
    );
    return @as(u64, (@as(u64, high) << 32) | (low));
}

pub const Leaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Calls CPUID with the given value of EAX and ECX.
pub inline fn cpuid(leaf_id: u32, subid: u32) Leaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
