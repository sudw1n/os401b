// knowledge sources:
// 1. https://wiki.osdev.org/Interrupt_Descriptor_Table
// 2. https://wiki.osdev.org/Interrupts_Tutorial

const std = @import("std");
const gdtlib = @import("../gdt.zig");
const cpu = @import("../cpu.zig");

const log = std.log.scoped(.idt);

const SegmentSelector = gdtlib.SegmentSelector;
const Dpl = gdtlib.Dpl;
const SystemTableRegister = cpu.SystemTableRegister;
const InterruptFrame = cpu.InterruptFrame;

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
    offset_low: u16,
    /// a code segment selector in GDT or LDT
    /// TODO: accept these values as parameters in init() rather than hardcoding
    selector: u16 = @intFromEnum(SegmentSelector.KernelCode),
    /// bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
    /// IST is used in combination with the TSS to force the cpu to switch stacks when handling a
    /// specific interrupt.
    ist: u3 = 0,
    reserved1: u5 = 0,
    /// Gate type.
    // TODO: accept this value as a parameter in init() rather than hardcoding
    gate_type: u4 = @intFromEnum(GateType.Interrupt64),
    /// Reserved
    reserved2: u1 = 0,
    /// Privilege level allowed to access this interrupt.
    // TODO: accept this value as a parameter in init() rather than hardcoding
    dpl: u2 = @intFromEnum(Dpl.Kernel),
    /// Whether the gate is active.
    // TODO: set in init()
    present: u1 = 1,
    /// offset bits 16..31
    offset_mid: u16,
    /// offset bits 32..63
    offset_high: u32,
    /// reserved
    reserved3: u32 = 0,

    pub fn init(isr_ptr: InterruptServiceRoutine) InterruptDescriptor {
        const isr: u64 = @intFromPtr(isr_ptr);
        return InterruptDescriptor{
            .offset_low = @as(u16, @truncate(isr)),
            .offset_mid = @as(u16, @truncate(isr >> 16)),
            .offset_high = @as(u32, @truncate(isr >> 32)),
        };
    }
};

// x86-64 has 256 interrupt vectors
const IDT_ENTRIES = 256;

var handlers: [IDT_ENTRIES]InterruptDescriptor linksection(".bss") = undefined;

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
    idtSet(0, idt0);
    idtSet(1, idt1);
    idtSet(13, idt13);
}

fn idtSet(comptime idx: usize, isr: InterruptServiceRoutine) void {
    handlers[idx] = InterruptDescriptor.init(isr);
}

fn idt0() callconv(CallingConvention.Naked) noreturn {
    // no error code == 0x00
    asm volatile (
        \\pushq $0
    );
    // the vector number
    asm volatile (
        \\pushq $0
    );
    asm volatile (
        \\jmp interruptCommon
    );
}

fn idt1() callconv(CallingConvention.Naked) noreturn {
    // no error code == 0x00
    asm volatile (
        \\pushq $0
    );
    // the vector number
    asm volatile (
        \\pushq $1
    );
    asm volatile (
        \\jmp interruptCommon
    );
}

fn idt13() callconv(CallingConvention.Naked) noreturn {
    // vector 13(#GP) does push an error code so we won't.
    // Just push the vector number.
    asm volatile (
        \\pushq $13
    );
    asm volatile (
        \\jmp interruptCommon
    );
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
    log.info("Received interrupt {}", .{frame.vector_number});
    switch (frame.vector_number) {
        0 => {
            log.debug("divide by zero", .{});
            @panic("reached unrecoverable exception");
        },
        1 => log.debug("debug interrupt", .{}),
        13 => log.debug("general protection fault", .{}),
        14 => log.debug("page fault", .{}),
        else => @panic("unhandled interrupt"),
    }
}
