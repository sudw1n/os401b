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

const log = std.log.scoped(.idt);

const SegmentSelector = gdtlib.SegmentSelector;
const Dpl = gdtlib.Dpl;
const SystemTableRegister = cpu.SystemTableRegister;
const InterruptFrame = cpu.InterruptFrame;

const CallingConvention = std.builtin.CallingConvention;
const Exception = cpu.Exception;

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
    log.info("Received interrupt {}", .{frame.vector_number});

    const panicMsg = switch (Exception.is(frame.vector_number)) {
        true => blk: {
            const exception: Exception = @enumFromInt(frame.vector_number);
            log.err("Exception: {s}", .{@tagName(exception)});
            break :blk "Reached unrecoverable exception";
        },
        false => "unhandled interrupt",
    };

    const cleanLog = std.log.scoped(.none);
    cleanLog.debug("{}", .{frame});
    @panic(panicMsg);
}
