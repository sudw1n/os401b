const gdt = @import("gdt.zig");

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

pub fn out(port: u16, data: anytype) void {
    const T: type = @TypeOf(data);
    return switch (T) {
        u8 => asm volatile ("outb %[data], %[port]"
            : [port] "N{dx}" (port),
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outb %[data], %[port]"
            : [port] "N{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outb %[data], %[port]"
            : [port] "N{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("The `out` instruction only supports u8, u16 or u32 but found: " ++ @typeName(T)),
    };
}
