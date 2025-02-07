// knowledge sources:
// 1. https://wiki.osdev.org/Interrupt_Descriptor_Table
// 2. https://wiki.osdev.org/Interrupts_Tutorial

const gdtlib = @import("../gdt.zig");
const cpu = @import("../cpu.zig");
const term = @import("../tty/terminal.zig");

const SegmentSelector = gdtlib.SegmentSelector;
const Dpl = gdtlib.Dpl;
const SystemTableRegister = cpu.SystemTableRegister;

/// Interrupt Descriptor Gate Type
pub const GateType = enum(u4) {
    Interrupt = 0b1110,
    Trap = 0b1111,
};

pub const InterruptServiceRoutine = *const fn () noreturn;

pub const InterruptDescriptor = packed struct {
    /// offset bits 0..15
    offset_1: u16,
    /// a code segment selector in GDT or LDT
    selector: u16 = @intFromEnum(SegmentSelector.KernelCode),
    /// bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
    ist: u8 = 0,
    /// Gate type.
    gate_type: u4 = @intFromEnum(GateType.Interrupt),
    /// Always zero.
    zero: u1 = 0,
    /// Privilege level.
    dpl: u2 = @intFromEnum(Dpl.Kernel),
    /// Whether the gate is active.
    present: u1 = 1,
    /// offset bits 16..31
    offset_2: u16,
    /// offset bits 32..63
    offset_3: u32,
    /// reserved
    reserved: u32 = 0,

    pub fn init(isr_ptr: InterruptServiceRoutine) InterruptDescriptor {
        const isr: u64 = @intFromPtr(isr_ptr);
        return InterruptDescriptor{
            .offset_1 = @as(u16, @truncate(isr)),
            .offset_2 = @as(u16, @truncate(isr >> 16)),
            .offset_3 = @as(u32, @truncate(isr >> 32)),
        };
    }
};

const IDT_ENTRIES = 256;

var handlers: [IDT_ENTRIES]InterruptDescriptor linksection(".bss") = undefined;

pub fn init() !void {
    try term.logStepBegin("Initializing the Interrupt Descriptor Table", .{});
    setHandlers();
    setIdtr();
    cpu.sti();
    try term.logStepEnd();
}

fn setHandlers() void {
    idtSet(0, idtZero);
}

fn idtSet(comptime idx: usize, isr: InterruptServiceRoutine) void {
    if (comptime idx > IDT_ENTRIES) {
        @compileError("Overflow when setting IDT");
    }
    handlers[idx] = InterruptDescriptor.init(isr);
}

fn setIdtr() void {
    const idtr = SystemTableRegister{
        .base = @intFromPtr(&handlers[0]),
        .limit = @sizeOf(@TypeOf(handlers)) - 1,
    };
    cpu.lidt(idtr);
}

fn isrStub() noreturn {
    cpu.cli();
    term.print("\n\nUnhandled interrupt!\n\n", .{}) catch cpu.hlt();
    cpu.hlt();
    cpu.iret();
}

fn idtZero() noreturn {
    cpu.cli();
    term.print("\n\nDivide by zero!\n\n", .{}) catch cpu.hlt();
    cpu.iret();
}
