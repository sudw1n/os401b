const std = @import("std");
const cpu = @import("../cpu.zig");
const registers = @import("../registers.zig");
const paging = @import("../memory/paging.zig");
const term = @import("../tty/terminal.zig");
const limine = @import("limine");

const log = std.log.scoped(.lapic);
const pagingLog = std.log.scoped(.paging);

const Leaf = cpu.Leaf;

const Msr = registers.Msr;

pub const LApic = struct {
    /// Physical base address of the Local APIC
    base_phys: u64,
    /// MMIO pointer
    ///
    /// This is the virtual address of the Local APIC registers.
    regs: [*]volatile u32,

    pub fn init() LApic {
        const apic_msr = Msr.IA32_APIC_BASE.read();
        // extract the base address from the MSR (bits 12-31)
        const apic_base_phys = apic_msr & 0xfffff000;
        log.debug("Retrieved LAPIC base address: {x:0>16}", .{apic_base_phys});
        const apic_base_virt = paging.physToVirtRaw(apic_base_phys);
        pagingLog.info("Mapping LAPIC registers virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{
            apic_base_virt,
            apic_base_virt + paging.PAGE_SIZE,
            apic_base_phys,
        });
        paging.mapPage(apic_base_virt, apic_base_phys, &.{ .Present, .Writable, .NoCache, .NoExecute });
        const regs: [*]volatile u32 = @ptrFromInt(apic_base_virt);
        return LApic{
            .base_phys = apic_base_phys,
            .regs = regs,
        };
    }

    /// Send an Inter-Processor Interrupt to the LAPIC
    pub fn sendIpi(self: *LApic, vector: u8) void {
        log.debug("sending IPI to LAPIC {d} with vector {x:0>2}", .{ self.id(), vector });
        const high = self.get(u32, Registers.ICR_HIGH);
        const low = self.get(u32, Registers.ICR_LOW);

        // the IPI is sent when the lower half is written to, so we should setup the destination in the
        // higher half first before writing the vector in the lower half.

        // we are going to send the IPI to ourselves which means we don't need to set the
        // destination id.
        high.* = 0;

        low.* = @as(u32, vector) | IcrShorthand.Self.get();
        // poll Delivery Status (bit 12) until it clears
        while ((low.* & (1 << 12)) != 0) {
            // wait
        }
    }

    /// Get a pointer to an APIC register
    pub fn get(self: *LApic, comptime T: type, reg: Registers) *volatile T {
        return @ptrFromInt(@intFromPtr(self.regs) + reg.get());
    }

    /// Send EOI to LAPIC
    pub fn sendEoi(self: *LApic) void {
        log.debug("sending EOI to LAPIC {d}", .{self.id()});
        const eoi = self.get(u32, Registers.Eoi);
        eoi.* = 0; // send EOI
    }

    /// Enable the spurious interrupt vector
    pub fn enableSpurious(self: *LApic) void {
        log.debug("enabling LAPIC {d} and setting spurious vector entry as {x:0>2}", .{ self.id(), InterruptVectors.Spurious.get() });
        const svt = self.get(u32, Registers.SpuriousInterruptVector);
        // set the APIC enabled bit (bit 8) and the spurious interrupt vector (bits 0-7)
        svt.* |= (@as(u32, (1 << 8)) | (InterruptVectors.Spurious.get()));
    }

    /// Returns the ID of the Local APIC
    pub fn id(self: *LApic) u8 {
        return self.get(u8, Registers.LocalId).*;
    }
};

// TODO: handle X2APIC and come up with better abstraction designs for this module

/// Offsets for the APIC registers from the base address
pub const Registers = enum(u32) {
    /// Contains the physical ID of the local APIC
    LocalId = 0x20,
    /// Contains some miscellaneous config for the local APIC, including the enable/disable flag.
    ///
    /// The register has the following format:
    /// Bits 0-7 (Spurious vector): Determine vector number (IDT entry) for the spurious interrupt
    /// Bit 8 (APIC Software enable/disable): Software toggle for enabling the local APIC
    /// Bit 9 (Focus Processor checking): Optional feature (may be unavailable) but indicates that
    /// some interrupts can be routed according to a list of priorities. Leave it cleared to
    /// ignore.
    /// Bits 10-31 (Reserved)
    ///
    /// The spurious vector is writable only in the first 9 bits, the rest is read-only.
    /// Also note that the spurious vector entry on old CPUs have the upper 4 bits forced to 1,
    /// meaning the vector must be between 0xF0 and 0xFF.
    SpuriousInterruptVector = 0xF0,
    /// End of Interrupt
    ///
    /// Once an interrupt for the LAPIC is served, it won't send any further interrupts until the
    /// EOI signal is sent. To do this, we write 0 to this EOI register and the LAPIC will resume
    /// sending interrupts to the processor.
    Eoi = 0xB0,

    ICR_LOW = 0x300,
    ICR_HIGH = 0x310,

    /// Used for controlling the LAPIC timer
    ///
    /// This is 64-bits wide split across two 32-bit registers
    Timer = 0x320,
    /// Used for configuring interrupts when certain therman conditions are met
    ///
    /// This is 32-bits wide
    Thermal = 0x330,
    /// Allows an interrupt to be generated when a performance counter overflows
    ///
    /// This is 32-bits wide
    PerfCounter = 0x340,
    /// Specifies the interrupt delivery when an interrupt is signaled on LINT0 pin
    /// (emulates IRQ0 from PIC)
    ///
    /// This is 32-bits wide
    Int0 = 0x350,
    /// Specifies the interrupt delivery when an interrupt is signaled on LINT1 pin
    /// (usually NMI)
    ///
    /// This is 32-bits wide
    Int1 = 0x360,
    /// Configures how the local APIC should report an internal error.
    ///
    /// This is 32-bits wide
    Error = 0x370,

    /// Load this to start the timer
    InitialCount = 0x380,
    /// Read how many ticks remain
    CurrentCount = 0x390,
    /// Divide incoming clock ticks
    Divisor = 0x3E0,

    pub fn get(self: Registers) u32 {
        return @intFromEnum(self);
    }
};

pub var global_lapic: LApic = undefined;

pub fn init() void {
    if (!checkApic()) {
        @panic("APIC not supported");
    }
    log.info("Found APIC support", .{});

    disablePic();
    log.info("Disabled the 8259 PIC", .{});

    global_lapic = LApic.init();
    global_lapic.enableSpurious();
    log.info("Initialized the LAPIC", .{});
}

/// The various interrupt vectors handled by APIC
pub const InterruptVectors = enum(u8) {
    Spurious = 0xFF,
    /// Retrieve the vector as an u8
    pub fn get(self: InterruptVectors) u8 {
        return @intFromEnum(self);
    }
    /// Is the vector handled by APIC
    pub fn is(vector: u8) bool {
        return switch (vector) {
            0xF0...0xFF => true,
            else => false,
        };
    }
};

/// There is a shorthand field in the ICR which overrides the destination id. It's available
/// in bits 19:18 and has the following definition:
pub const IcrShorthand = enum(u2) {
    /// No shorthand, use the destination id.
    NoShorthand = 0b00,
    /// Send this IPI to ourselves, no one else.
    Self = 0b01,
    /// Send this IPI to all LAPICs, including ourselves.
    AllIncludingSelf = 0b10,
    /// Send this IPI to all LAPICs, but not ourselves.
    AllExcludingSelf = 0b11,

    pub fn get(self: IcrShorthand) u32 {
        return @as(u32, @intFromEnum(self)) << 18;
    }
};

fn checkApic() bool {
    const leaf = cpu.cpuid(1, 0);
    // check the 9th bit
    return (leaf.edx & (1 << 8)) != 0;
}

fn disablePic() void {
    // PIC "master" and "slave" command/data ports
    const PIC_COMMAND_MASTER = 0x20;
    const PIC_DATA_MASTER = 0x21;
    const PIC_COMMAND_SLAVE = 0xA0;
    const PIC_DATA_SLAVE = 0xA1;

    // ICW (Initialization Command Words) for the PICs

    // indicates start of initialization sequence, same for master and slave
    const ICW_1 = 0x11;
    // interrupt vector address values (IDT entries) for master and slave
    // this is since the first 31 interrupts are exceptions/reserved,
    // both PICs occupy 8 IRQs each
    const ICW_2_M = 0x20;
    const ICW_2_S = 0x28;
    // used to indicate if the pin has a slave or not.
    // since the slave pic will be connected to one of the interrupt pins of the master, we need to
    // indicate which one it is. On x86, the slave is connected to second IRQ pin of the master.
    // for the slave, the value will be its id.
    const ICW_3_M = 0x2;
    const ICW_3_S = 0x4;
    // contains some configuration bits for the mode of operation, in this case we just tell we are
    // going to use the 8086 mode.
    const ICW_4 = 0;

    // mask all interrupts
    const MASK_INTERRUPTS = 0xff;
    const out = cpu.out;

    // things like the PIT can start firing interrupts after we start the initialization sequence
    // (before we fully disable the PIC), so temporarily disable them.
    cpu.cli();

    out(u8, PIC_COMMAND_MASTER, ICW_1);
    out(u8, PIC_COMMAND_SLAVE, ICW_1);

    out(u8, PIC_DATA_MASTER, ICW_2_M);
    out(u8, PIC_DATA_SLAVE, ICW_2_S);

    out(u8, PIC_DATA_MASTER, ICW_3_M);
    out(u8, PIC_DATA_SLAVE, ICW_3_S);

    out(u8, PIC_DATA_MASTER, ICW_4);
    out(u8, PIC_DATA_SLAVE, ICW_4);

    out(u8, PIC_DATA_MASTER, MASK_INTERRUPTS);
    out(u8, PIC_DATA_SLAVE, MASK_INTERRUPTS);

    cpu.sti();
}
