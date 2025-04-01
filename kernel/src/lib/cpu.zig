const std = @import("std");
const gdt = @import("gdt.zig");
const registers = @import("registers.zig");
const Cr2 = registers.Cr2;
const Rflags = registers.Rflags;

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
    rflags: Rflags,
    /// Stack Pointer
    rsp: u64,
    /// Stack Segment
    ss: u64,

    /// Custom formatter that prints the register dump.
    pub fn format(value: InterruptFrame, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("ES: {x:0>4}  DS: {x:0>4}\n" ++
            "R15: {x:0>16} R14: {x:0>16} R13: {x:0>16}\n" ++
            "R12: {x:0>16} R11: {x:0>16} R10: {x:0>16}\n" ++
            "R9 : {x:0>16} R8 : {x:0>16} RDI: {x:0>16}\n" ++
            "RSI: {x:0>16} RBP: {x:0>16} RDX: {x:0>16}\n" ++
            "RCX: {x:0>16} RBX: {x:0>16} RAX: {x:0>16}\n" ++
            "CS: {x:0>4} RIP: {x:0>16}\n" ++
            "SS: {x:0>4} RSP: {x:0>16}\n", .{
            value.es,
            value.ds,
            value.r15,
            value.r14,
            value.r13,
            value.r12,
            value.r11,
            value.r10,
            value.r9,
            value.r8,
            value.rdi,
            value.rsi,
            value.rbp,
            value.rdx,
            value.rcx,
            value.rbx,
            value.rax,
            value.cs,
            value.rip,
            value.ss,
            value.rsp,
        });
        try writer.print("{}", .{value.rflags});
        if (Exception.is(value.vector_number)) {
            const exception: Exception = @enumFromInt(value.vector_number);
            if (exception.hasErrorCode()) {
                try value.dissectErrorCode(writer);
            }
        }
    }
    fn dissectErrorCode(self: InterruptFrame, writer: anytype) !void {
        const error_code = self.error_code;
        const exception: Exception = @enumFromInt(self.vector_number);
        try writer.print("Error code: 0x{x:0>16}\n", .{error_code});
        if (exception.zeroErrorCode()) {
            return;
        }
        try writer.print("Error code bits:\n", .{});
        if (exception == Exception.PF) {
            // If set, means all the page table entries were present,
            // but translation failed due to a protection violation.
            // If cleared, a page table entry was not present.
            try writer.print("  Present: {}\n", .{(error_code & 0b1) != 0});
            // If set, page fault was triggered by a write attempt.
            // Cleared if it was a read attempt.
            try writer.print("  Write: {}\n", .{(error_code & 0b10) != 0});
            // Set if the CPU was in user mode (CPL = 3).
            try writer.print("  User: {}\n", .{(error_code & 0b100) != 0});
            // If set, means a reserved bit was set in a page table entry.
            // Best to walk the page tables manually and see what’s happening.
            try writer.print("  Reserved: {}\n", .{(error_code & 0b1000) != 0});
            // If NX (No-Execute) is enabled in EFER, this bit can be set.
            // If set the page fault was caused by trying to fetch
            // an instruction from an NX page.
            try writer.print("  Instruction fetch: {}\n", .{(error_code & 0b10000) != 0});
            try writer.print("Accessed Address: 0x{x:0>16}\n", .{Cr2.get()});
        } else {
            // If set, means it was a hardware interrupt.
            // Cleared for software interrupts.
            try writer.print("  External: {}\n", .{(error_code & 0b1) != 0});
            // Set if this error code refers to the IDT.
            // If cleared it refers to the GDT or LDT (mostly unused in long mode).
            try writer.print("  IDT: {}\n", .{(error_code & 0b10) != 0});
            // Set if the error code refers to the LDT, cleared if referring to the GDT.
            try writer.print("  Table Index: {}\n", .{(error_code & 0b100) != 0});
            // The index into the table this error code refers to.
            // This can be seen as a byte offset into the table,
            // much like a GDT selector would.
            try writer.print("  Index: 0x{x:0>16}\n", .{(error_code >> 3)});
        }
    }
};

/// x86 Exceptions.
///
/// The first 32 entries in the IDT are reserved for exceptions,
/// which this enum represents.
pub const Exception = enum(u8) {
    /// Divide by Zero Error
    DE = 0,
    /// Debug
    DB = 1,

    // 2 is Non-Maskable Interrupt, which we don't consider an exception

    /// Breakpoint
    BP = 3,
    /// Overflow
    OF = 4,
    /// Bound Range Exceeded
    BR = 5,
    /// Invalid Opcode
    UD = 6,
    /// Device Not Available
    NM = 7,
    /// Double Fault
    DF = 8,

    // 9 is unused; was x87 Segment Overrun

    /// Invalid TSS
    TS = 10,
    /// Segment Not Present
    NP = 11,
    /// Stack-Segment Fault
    SS = 12,
    /// General Protection Fault
    GP = 13,
    /// Page Fault
    PF = 14,

    // 15 is currently unused

    /// x87 FPU Error
    MF = 16,
    /// Alignment Check
    AC = 17,
    /// Machine Check
    MC = 18,
    /// SIMD (SSE/AVX) Error
    XF = 19,

    // 20-31 currently unused

    /// Is the interrupt an exception/
    pub inline fn is(interrupt: u64) bool {
        return switch (interrupt) {
            0, 1, 3...8, 10...14, 16...19 => true,
            else => false,
        };
    }

    /// Has the exception an error code?
    pub inline fn hasErrorCode(self: Exception) bool {
        return switch (self) {
            .DF, .TS, .NP, .SS, .GP, .PF, .AC => true,
            else => false,
        };
    }

    /// Does the exception have an error code of always zero?
    pub inline fn zeroErrorCode(self: Exception) bool {
        return switch (self) {
            .DF, .AC => true,
            else => false,
        };
    }
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
