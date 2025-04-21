// knowledge sources:
// 1. https://wiki.osdev.org/Interrupt_Descriptor_Table
// 2. https://wiki.osdev.org/Interrupts_Tutorial
// 3. https://github.com/dreamportdev/Osdev-Notes
//
// The implementation is mostly based from:
// https://codeberg.org/loup-os/kernel/

const std = @import("std");
const gdtlib = @import("../gdt.zig");
const cpu = @import("../cpu.zig");
const apic = @import("apic.zig");
const registers = @import("../registers.zig");
const Cr2 = registers.Cr2;
const Rflags = registers.Rflags;

const log = std.log.scoped(.idt);

const ApicInterrupt = apic.ApicInterrupt;

const SegmentSelector = gdtlib.SegmentSelector;
const Dpl = gdtlib.Dpl;
const SystemTableRegister = cpu.SystemTableRegister;

const CallingConvention = std.builtin.CallingConvention;

/// Interrupt Descriptor Gate Type
pub const GateType = enum(u4) {
    Interrupt64 = 0b1110,
    Trap64 = 0b1111,
};

pub const InterruptServiceRoutine = *const fn () callconv(.Naked) noreturn;

// TODO: consider encapsulating all of the global stuff in the IDT struct

pub const InterruptDescriptor = packed struct {
    /// offset bits 0..15
    offset_low: u16 = 0,
    /// a code segment selector in GDT or LDT
    selector: u16 = @intFromEnum(SegmentSelector.KernelCode),
    /// bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
    /// IST is used in combination with the TSS to force the cpu to switch stacks when handling a
    /// specific interrupt.
    ist: u3 = 0,
    reserved1: u5 = 0,
    /// Gate type.
    gate_type: u4 = @intFromEnum(GateType.Interrupt64),
    /// Reserved
    reserved2: u1 = 0,
    /// Privilege level allowed to access this interrupt.
    dpl: u2 = @intFromEnum(Dpl.Kernel),
    /// Whether the gate is active.
    present: u1 = 1,
    /// offset bits 16..31
    offset_mid: u16 = 0,
    /// offset bits 32..63
    offset_high: u32 = 0,
    /// reserved
    reserved3: u32 = 0,

    pub fn setOffset(self: *InterruptDescriptor, isr_ptr: InterruptServiceRoutine) void {
        const isr: u64 = @intFromPtr(isr_ptr);
        self.offset_low = @as(u16, @truncate(isr));
        self.offset_mid = @as(u16, @truncate(isr >> 16));
        self.offset_high = @as(u32, @truncate(isr >> 32));
    }
};

// x86-64 has 256 interrupt vectors
const IDT_ENTRIES = 256;

var handlers: [IDT_ENTRIES]InterruptDescriptor linksection(".data") = .{InterruptDescriptor{}} ** IDT_ENTRIES;

pub fn init() void {
    setHandlers();
    setIdtr();
    cpu.sti();
}

fn setIdtr() void {
    const idtr = SystemTableRegister{
        .base = @intFromPtr(&handlers[0]),
        // should be 0xfff: 16 bytes (128 bits) per descriptor * 256 descriptors - 1
        .limit = @sizeOf(@TypeOf(handlers)) - 1,
    };
    cpu.lidt(idtr);
}

fn setHandlers() void {
    inline for (0..0xff) |i| {
        if (getVector(i)) |vector| {
            handlers[i].setOffset(vector);
            if (Exception.is(i)) {
                handlers[i].gate_type = @intFromEnum(GateType.Trap64);
            } else {
                handlers[i].gate_type = @intFromEnum(GateType.Interrupt64);
            }
        } else {
            handlers[i].present = 0;
        }
    }
}

fn getVector(comptime vector: u8) ?InterruptServiceRoutine {
    return switch (vector) {
        inline 2, 9, 15, 20...31 => null,
        else => blk: {
            break :blk struct {
                fn func() callconv(.Naked) noreturn {
                    const is_exception = Exception.is(vector);
                    // if the interrupt is an exception with a vector number, then don't push a
                    // dummy error code and only push the vector number.
                    if (is_exception and @as(Exception, @enumFromInt(vector)).hasErrorCode()) {
                        asm volatile (
                            \\pushq %[vec]
                            \\jmp interruptCommon
                            :
                            : [vec] "{rax}" (@as(u64, vector)),
                        );
                    } else {
                        asm volatile (
                        // no (dummy) error code == 0x00
                            \\pushq $0
                            // the vector number
                            \\pushq %[vec]
                            \\jmp interruptCommon
                            :
                            : [vec] "{rax}" (@as(u64, vector)),
                        );
                    }
                }
            }.func;
        },
    };
}

export fn interruptCommon() callconv(.Naked) void {
    // save general purpose registers
    asm volatile (
        \\pushq   %%rax
        \\pushq   %%rbx
        \\pushq   %%rcx
        \\pushq   %%rdx
        \\pushq   %%rbp
        \\pushq   %%rsi
        \\pushq   %%rdi
        \\pushq   %%r8
        \\pushq   %%r9
        \\pushq   %%r10
        \\pushq   %%r11
        \\pushq   %%r12
        \\pushq   %%r13
        \\pushq   %%r14
        \\pushq   %%r15
    );
    // push segment registers
    asm volatile (
        \\mov %%ds, %%rax
        \\pushq %%rax
        \\mov %%es, %%rax
        \\pushq %%rax
    );
    // set segment to run in
    asm volatile (
        \\mov %[kernel_data], %%rax
        \\mov %%ax, %%es
        \\mov %%ax, %%ds
        :
        : [kernel_data] "i" (SegmentSelector.KernelData),
    );
    // handle the interrupt and pass the current stack pointer as a interrupt frame
    asm volatile (
        \\mov %%rsp, %%rdi
        \\call interruptDispatch
    );

    // restore segment registers
    asm volatile (
        \\pop %rax
        \\mov %rax, %%es
        \\pop %%rax
        \\mov %%rax, %%ds
    );

    // Restore general purpose registers
    asm volatile (
        \\popq   %r15
        \\popq   %r14
        \\popq   %r13
        \\popq   %r12
        \\popq   %r11
        \\popq   %r10
        \\popq   %r9
        \\popq   %r8
        \\popq   %rdi
        \\popq   %rsi
        \\popq   %rbp
        \\popq   %rdx
        \\popq   %rcx
        \\popq   %rbx
        \\popq   %rax
    );

    // remove the vector number + error code
    asm volatile (
        \\addq   $0x10, %%rsp
    );
    // return from interrupt
    asm volatile ("iretq");
}

export fn interruptDispatch(frame: *InterruptFrame) void {
    if (frame.vector_number == ApicInterrupt.Spurious.get()) {
        log.info("Received spurious interrupt, ignoring...");
        // this is a spurious interrupt, so we can ignore it
        return;
    }

    log.info("Received interrupt 0x{x}", .{frame.vector_number});

    const panicMsg = switch (Exception.is(frame.vector_number)) {
        true => blk: {
            const exception: Exception = @enumFromInt(frame.vector_number);
            log.err("Exception: #{s}", .{@tagName(exception)});
            break :blk "Reached unrecoverable exception";
        },
        false => "unhandled interrupt",
    };

    switch (frame.vector_number) {
        apic.SPURIOUS_VECTOR...0xFF => {
            // since this is an APIC interrupt, we need to send EOI
            apic.sendEoi();
        },
        else => {},
    }

    const cleanLog = std.log.scoped(.none);
    cleanLog.debug("{}", .{frame});
    @panic(panicMsg);
}

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
