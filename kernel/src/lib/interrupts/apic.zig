const std = @import("std");
const cpu = @import("../cpu.zig");
const acpi = @import("../acpi.zig");
const registers = @import("../registers.zig");
const paging = @import("../memory/paging.zig");
const term = @import("../tty/terminal.zig");
const limine = @import("limine");

const log = std.log.scoped(.apic);
const pagingLog = std.log.scoped(.paging);

const Leaf = cpu.Leaf;

const Msr = registers.Msr;

var lapic_base: u64 = 0;
var ioapic_base: u64 = 0;

// TODO: handle X2APIC and come up with better abstraction designs for this module

/// Offsets for the APIC registers from the base address
pub const ApicOffsets = enum(u32) {
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
    LInt0 = 0x350,
    /// Specifies the interrupt delivery when an interrupt is signaled on LINT1 pin
    /// (usually NMI)
    ///
    /// This is 32-bits wide
    LInt1 = 0x360,
    /// Configures how the local APIC should report an internal error.
    ///
    /// This is 32-bits wide
    Error = 0x370,

    pub fn get(self: ApicOffsets, comptime T: type, base: u64) *T {
        return @ptrFromInt(base + @intFromEnum(self));
    }
};

pub fn init(rsdp_response: *limine.RsdpResponse) void {
    log.info("Checking APIC support", .{});
    if (!checkApic()) {
        log.err("APIC not supported", .{});
        return;
    }

    log.info("Disabling the 8259 PIC", .{});
    disablePic();

    log.info("Initializing LAPIC", .{});
    initLApic();

    log.info("Initializing I/O APIC", .{});
    if (!initIoApic(rsdp_response)) {
        log.err("Failed to initialize I/O APIC", .{});
        return;
    }
}

fn initLApic() void {
    const apic_msr = cpu.rdmsr(Msr.IA32_APIC_BASE);
    // extract the base address from the MSR (bits 12-31)
    const apic_base_phys = apic_msr & 0xfffff000;
    log.debug("Retrieved LAPIC base address: {x:0>16}", .{apic_base_phys});
    lapic_base = paging.physToVirtRaw(apic_base_phys);
    pagingLog.info("Mapping LAPIC registers virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{
        lapic_base,
        lapic_base + paging.PAGE_SIZE,
        apic_base_phys,
    });
    paging.mapPage(lapic_base, apic_base_phys, &.{ .Present, .Writable, .NoCache, .NoExecute });
}

const IOAPICVER = 0x01;

fn initIoApic(rsdp_response: *limine.RsdpResponse) bool {
    const rsdp = acpi.Rsdp2Descriptor.init(rsdp_response);
    const xsdt = rsdp.getXSDT();
    if (xsdt.findSdtHeader("APIC")) |header| {
        const madt: *acpi.Madt = @ptrCast(header);

        var iterator = madt.iterator();
        if (iterator.findNext(acpi.MadtEntryType.IoApic)) |entry| {
            const ioapic_base_phys = entry.IoApic.address;
            log.debug("Retrieved I/O APIC base address: {x:0>16}", .{ioapic_base_phys});
            ioapic_base = paging.physToVirtRaw(entry.IoApic.address);
            pagingLog.info("Mapping I/O APIC registers virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{
                ioapic_base,
                ioapic_base + paging.PAGE_SIZE,
                ioapic_base_phys,
            });
            paging.mapPage(ioapic_base, ioapic_base_phys, &.{ .Present, .Writable, .NoCache, .NoExecute });
            return true;
        }
    }
    return false;
}

/// Offset for I/O register select to be added to I/O APIC base
///
/// Used to select the I/O register to access
const IOREGSEL: u8 = 0x00;
/// Offset for I/O register window to be added to I/O APIC base
///
/// Used to access data selected by IoRegSel
const IOWIN: u8 = 0x10;

// I/O APIC registers that can be accessed using the IOREGSEL and IOWIN registers
const IoRegisters = enum(u8) {
    /// I/O APIC ID register
    IoApicId = 0x00,
    /// I/O APIC version register
    IoApicVersion = 0x01,
    /// I/O APIC arbitration ID register
    IoApicArbitrationId = 0x02,
    /// I/O APIC redirection table base address
    IoApicRedirectionTableBase = 0x10,

    pub fn get(self: IoRegisters) u8 {
        return @intFromEnum(self);
    }
};

// if we want to read/write a register of the I/O APIC, we need to:
// 1. write the register number to the IOREGSEL register
// 2. read/write the value to the IOWIN register

fn readIoApicRegister(comptime T: type, reg: u8) T {
    const regsel: *u8 = @ptrFromInt(ioapic_base + IOREGSEL);
    const window: *T = @ptrFromInt(ioapic_base + IOWIN);
    regsel.* = reg;
    return window.*;
}

fn writeIoApicRegister(comptime T: type, reg: u8, value: T) void {
    const regsel: *u8 = @ptrFromInt(ioapic_base + IOREGSEL);
    const window: *T = @ptrFromInt(ioapic_base + IOWIN);
    regsel.* = reg;
    window.* = value;
}

/// Write a single I/O APIC redirection entry.
///
///
/// pin: GSI number (0..number_of_inputs-1) i.e. the target pin for APIC
/// lvt: LVT entry to be written
/// dest_apic: the LAPIC ID to forward the interrupts to
fn setIoRedirection(pin: u32, lvt: Lvt, dest_apic: u8) void {
    const base = @intFromEnum(IoRegisters.IoApicRedirectionTableBase);
    const low_index = base + @as(u8, @intCast(pin)) * 2;
    const high_index = low_index + 1;

    // write the low dword i.e. LVT
    writeIoApicRegister(u32, low_index, @bitCast(lvt));
    // write high dword i.e. destination APIC ID (overall bits 56-63, but for the dword this would
    // mean position 24)
    const high_dword = @as(u32, dest_apic) << 24;
    writeIoApicRegister(u32, high_index, high_dword);
}

/// The various interrupt vectors handled by APIC
pub const LApicInterrupt = enum(u8) {
    Spurious = 0xFF,
    /// Retrieve the vector as an u8
    pub fn get(self: LApicInterrupt) u8 {
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

/// LVT entries.
//
/// For the 32-bit entries (all except Timer's upper half), bits are laid out as:
/// Bits 0-7:  Interrupt Vector. This is the IDT entry that will be invoked.
/// Bits 8-10: Delivery mode. Determines how the APIC should present the interrupt to the
///            processor. The fixed mode (0b000) is for normal interrupts and others (NMI, SMI,
///            INIT) are special. Fixed mode is fine in almost all cases.
/// Bit 11:    Destination mode, can be either physical or logical addressing (rarely changed).
/// Bit 12:    Delivery status (read only), whether the interrupt has been served or not.
/// Bit 13:    Pin polarity: 0 is active-high, 1 is level-triggered.
/// Bit 14:    Remote IRR (read only) used by the APIC for tracking level-triggered interrupts state.
/// Bit 15:    Trigger mode: 0 is edge-triggered, 1 is level-triggered.
/// Bit 16:    Interrupt mask, 1 means the interrupt is disabled, 0 is enabled.
///
/// All higher bits are reserved.
const Lvt = packed struct {
    /// Interrupt vector
    vector: u8,
    /// Delivery mode
    delivery_mode: u3,
    /// Destination mode
    destination_mode: u1,
    /// Delivery status (read-only)
    delivery_status: u1,
    /// Pin polarity
    pin_polarity: u1,
    /// Remote IRR (read-only)
    remote_irr: u1,
    /// Trigger mode
    trigger_mode: u1,
    /// Interrupt mask
    interrupt_mask: u1,
    reserved: u16,
    pub fn init(vector: u8, mask: bool) Lvt {
        return Lvt{
            .vector = vector,
            // fixed
            .delivery_mode = 0b000,
            // physical
            .destination_mode = 0b0,
            // active-high
            .pin_polarity = 0,
            // edge-triggered
            .trigger_mode = 0,
            .interrupt_mask = @intFromBool(mask),

            // read-only / reserved bits
            // APIC spec requires to zero out all of the read‑only and reserved bits
            .delivery_status = 0,
            .remote_irr = 0,
            .reserved = 0,
        };
    }
};

fn setupVectors() void {
    log.debug("enabling LAPIC {d} and setting spurious vector entry as {x:0>2}", .{ ApicOffsets.LocalId.get(u8, lapic_base).*, LApicInterrupt.Spurious.get() });
    const svt = ApicOffsets.SpuriousInterruptVector.get(u32, lapic_base);
    svt.* |= (1 << 8) | (LApicInterrupt.Spurious); // set the APIC enabled bit (bit 8) and the spurious interrupt vector (bits 0-7)
    log.debug("enabled LAPIC", .{});
}

pub fn sendEoi() void {
    log.debug("sending EOI to LAPIC", .{});
    const eoi = ApicOffsets.Eoi.get(u32, lapic_base);
    eoi.* = 0; // send EOI
    log.debug("EOI sent", .{});
}

/// There is a shorthand field in the ICR which overrides the destination id. It's available
/// in bits 19:18 and has the following definition:
const IcrShorthand = enum(u2) {
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

pub fn lapicSendIpi(dest_id: u32, vector: u8) void {
    log.debug("sending IPI to LAPIC {d} with vector {x:0>2}", .{ dest_id, vector });
    const high = ApicOffsets.ICR_HIGH.get(u32, lapic_base);
    const low = ApicOffsets.ICR_LOW.get(u32, lapic_base);
    //  0b00: no shorthand, use the destination id.
    //  0b01: send this IPI to ourselves, no one else.
    //  0b10: send this IPI to all LAPICs, including ourselves.
    //  0b11: send this IPI to all LAPICs, but not ourselves.

    // the IPI is sent when the lower half is written to, so we should setup the destination in the
    // higher half first before writing the vector in the lower half.

    // we are going to send the IPI to ourselves, so we set the shorthand field to 0b01
    // which also means we don't need to set the destination id.
    high.* = 0;

    low.* = @as(u32, vector) | IcrShorthand.AllExcludingSelf.get();
    // poll Delivery Status (bit 12) until it clears
    while ((low.* & (1 << 12)) != 0) {
        // wait
    }
    log.debug("IPI sent", .{});
}

fn checkApic() bool {
    const leaf = cpu.cpuid(1, 0);
    // check the 9th bit
    return (leaf.edx & (1 << 8)) != 0;
}

// PIC "master" and "slave" command/data ports
const PIC_COMMAND_MASTER = 0x20;
const PIC_DATA_MASTER = 0x21;
const PIC_COMMAND_SLAVE = 0xA0;
const PIC_DATA_SLAVE = 0xA1;

// ICW (Initialization Command Words) for the PICs

// indicates start of initialization sequence, same for master and slave
const ICW_1: u8 = 0x11;
// interrupt vector address values (IDT entries) for master and slave
// this is since the first 31 interrupts are exceptions/reserved,
// both PICs occupy 8 IRQs each
const ICW_2_M: u8 = 0x20;
const ICW_2_S: u8 = 0x28;
// used to indicate if the pin has a slave or not.
// since the slave pic will be connected to one of the interrupt pins of the master, we need to
// indicate which one it is. On x86, the slave is connected to second IRQ pin of the master.
// for the slave, the value will be its id.
const ICW_3_M: u8 = 0x2;
const ICW_3_S: u8 = 0x4;
// contains some configuration bits for the mode of operation, in this case we just tell we are
// going to use the 8086 mode.
const ICW_4: u8 = 0;

// mask all interrupts
const MASK_INTERRUPTS: u8 = 0xff;
fn disablePic() void {
    const out = cpu.out;

    out(PIC_COMMAND_MASTER, ICW_1);
    out(PIC_COMMAND_SLAVE, ICW_1);

    out(PIC_DATA_MASTER, ICW_2_M);
    out(PIC_DATA_SLAVE, ICW_2_S);

    out(PIC_DATA_MASTER, ICW_3_M);
    out(PIC_DATA_SLAVE, ICW_3_S);

    out(PIC_DATA_MASTER, ICW_4);
    out(PIC_DATA_SLAVE, ICW_4);

    out(PIC_DATA_MASTER, MASK_INTERRUPTS);
    out(PIC_DATA_SLAVE, MASK_INTERRUPTS);
}
