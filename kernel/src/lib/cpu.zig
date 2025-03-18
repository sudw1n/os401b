const std = @import("std");
const gdt = @import("gdt.zig");

// TODO: modularize this. maybe registers stuff in a separate module?

pub const SystemTableRegister = packed struct {
    limit: u16,
    base: u64,
};

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

/// Values pushed when an interrupt occurs.
pub const InterruptFrame = packed struct {
    /// Extra Segment Selector
    es: u64,
    /// Data Segment Selector
    ds: u64,
    /// General purpose register R15
    r15: u64,
    /// General purpose register R14
    r14: u64,
    /// General purpose register R13
    r13: u64,
    /// General purpose register R12
    r12: u64,
    /// General purpose register R11
    r11: u64,
    /// General purpose register R10
    r10: u64,
    /// General purpose register R9
    r9: u64,
    /// General purpose register R8
    r8: u64,
    /// Destination index for string operations
    rdi: u64,
    /// Source index for string operations
    rsi: u64,
    /// Base Pointer (meant for stack frames)
    rbp: u64,
    /// Data (commonly extends the A register)
    rdx: u64,
    /// Counter
    rcx: u64,
    /// Base
    rbx: u64,
    /// Accumulator
    rax: u64,

    /// Interrupt Number
    vector_number: u64,
    /// Error code
    error_code: u64,

    // values pushed by the CPU which get popped with iret
    /// Instruction Pointer
    rip: u64,
    /// Code Segment
    cs: u64,
    /// RFLAGS
    rflags: RFLAGS,
    /// Stack Pointer
    rsp: u64,
    /// Stack Segment
    ss: u64,

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

pub inline fn iret() noreturn {
    asm volatile ("iret");
    unreachable;
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
            : // no outputs
            : [port] "N{dx}" (port),
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outb %[data], %[port]"
            : // no outputs
            : [port] "N{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outb %[data], %[port]"
            : // no outputs
            : [port] "N{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("The `out` instruction only supports u8, u16 or u32 but found: " ++ @typeName(T)),
    };
}

pub fn rdtsc() u64 {
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
pub fn cpuid(leaf_id: u32, subid: u32) Leaf {
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

/// RFLAGS Register
pub const RFLAGS = packed struct(u64) {
    /// Carry Flag
    cf: bool,
    /// Reserved
    res1: u1 = 1,
    /// Parity Flag
    pf: bool,
    /// Reserved
    res2: u1 = 0,
    /// Auxiliary Carry Flag
    af: bool,
    /// Reserved
    res3: u1 = 0,
    /// Zero Flag
    zf: bool,
    /// Sign Flag
    sf: bool,
    /// Trap Flag
    tf: bool,
    /// Interrupt Enable Flag
    @"if": bool,
    /// Direction Flag
    df: bool,
    /// Overflow Flag
    of: bool,
    /// I/O Privilege Level
    iopl: u2,
    /// Nested Task
    nt: bool,
    /// Reserved
    res4: u1 = 0,
    /// Resume Flag
    rf: bool,
    /// Virtual-8086 Mode
    vm: bool,
    /// Alignment Check / Access Control
    ac: bool,
    /// Virtual Interrupt Flag
    vif: bool,
    /// Virtual Interrupt Pending
    vip: bool,
    /// ID Flag
    id: bool,
    /// Reserved
    res5: u42,
};

/// Get RFLAGS
pub inline fn getRFLAGS() RFLAGS {
    return asm volatile (
        \\pushfq
        \\pop %[ret]
        : [ret] "={rax}" (-> RFLAGS),
    );
}

/// Set RFLAGS
pub inline fn setRFLAGS(rflags: RFLAGS) void {
    asm volatile (
        \\push %[val]
        \\popfq
        :
        : [val] "{rax}" (rflags),
    );
}
