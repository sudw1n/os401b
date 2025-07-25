const std = @import("std");
const limine = @import("limine");
const acpi = @import("../acpi.zig");
const vmm = @import("../memory/vmm.zig");
const lapic = @import("lapic.zig");

const log = std.log.scoped(.ioapic);

const MadtEntry = acpi.MadtEntry;

const VmObjectFlag = vmm.VmObjectFlag;

pub const IoApic = struct {
    /// Physical base address of the I/O APIC
    base_phys: u64,
    /// MMIO pointer
    ///
    /// This is the virtual address of the I/O APIC registers.
    regs: [*]volatile u32,
    /// The first GSI number that the I/O APIC can handle
    /// (usually just 0)
    gsi_base: u32,

    /// Offset for I/O register select to be added to I/O APIC base
    ///
    /// Used to select the I/O register to access
    const IOREGSEL: u8 = 0x00;
    /// Offset for I/O register window to be added to I/O APIC base
    ///
    /// Used to access data selected by IoRegSel
    const IOWIN: u8 = 0x10;

    /// Initialize an I/O APIC by scanning the ACPI MADT
    pub fn init(entry: acpi.MadtEntry) IoApic {
        const ioapic_base_phys = entry.IoApic.address;
        log.debug("Retrieved I/O APIC base address: {x:0>16}", .{ioapic_base_phys});
        const ioapic_base_virt = vmm.global_vmm.alloc(0x1000, &.{ VmObjectFlag.Write, VmObjectFlag.Mmio, VmObjectFlag.Reserved }, ioapic_base_phys) catch @panic("OOM for MMIO I/O APIC");
        // sanity check: the VMM allocates exactly the requested size if it's page aligned
        log.debug("Retrieved I/O APIC virtual address: {x:0>16}", .{@intFromPtr(ioapic_base_virt.ptr)});
        std.debug.assert(ioapic_base_virt.len == 0x1000);

        const ioapic_regs: [*]volatile u32 = @ptrCast(@alignCast(ioapic_base_virt.ptr));

        return IoApic{
            .base_phys = ioapic_base_phys,
            .regs = ioapic_regs,
            .gsi_base = entry.IoApic.gsi_base,
        };
    }

    // if we want to read/write a register of the I/O APIC, we need to:
    // 1. write the register number to the IOREGSEL register
    // 2. read/write the value to the IOWIN register

    pub fn read(self: *IoApic, comptime T: type, reg: u8) T {
        const regsel: *volatile u8 = @ptrFromInt(@intFromPtr(self.regs) + IOREGSEL);
        const window: *volatile T = @ptrFromInt(@intFromPtr(self.regs) + IOWIN);
        regsel.* = reg;
        return window.*;
    }

    pub fn write(self: *IoApic, comptime T: type, reg: u8, value: T) void {
        const regsel: *volatile u8 = @ptrFromInt(@intFromPtr(self.regs) + IOREGSEL);
        const window: *volatile T = @ptrFromInt(@intFromPtr(self.regs) + IOWIN);
        regsel.* = reg;
        window.* = value;
    }

    /// Read one 64-bit redirection entry
    pub fn readRedir(self: *IoApic, pin: u32) u64 {
        const base = @intFromEnum(Registers.RedirectionTableBase);

        const low_index: u8 = base + @as(u8, @intCast(pin)) * 2;
        const high_index: u8 = base + @as(u8, @intCast(pin)) * 2 + 1;

        // read the low dword
        const lo = self.read(u32, low_index);
        // read high dword
        const hi = self.write(u32, high_index);

        return (@as(u64, hi) << 32) | @as(u64, lo);
    }

    /// Write one 64-bit redirection entry
    pub fn writeRedir(self: *IoApic, pin: u32, val: u64) void {
        const base = @intFromEnum(Registers.RedirectionTableBase);

        const low_index = base + @as(u8, @intCast(pin)) * 2;
        const high_index = base + @as(u8, @intCast(pin)) * 2 + 1;

        // write the low dword
        self.write(u32, low_index, val);
        // write high dword
        self.write(u32, high_index, val >> 32);
    }

    /// Program an I/O APIC redirection entry with the given LVT entry and destination APIC ID.
    ///
    /// pin: GSI number (0..number_of_inputs-1) i.e. the target pin for APIC
    /// lvt: LVT entry to be written
    /// dest_apic: the LAPIC ID to forward the interrupts to
    pub fn program(self: *IoApic, pin: u32, lvt: Lvt, dest_apic: u8) void {
        // If gsi_base == 24, then for the redirection table:
        // GSI 24 -> entry 0
        // GSI 25 -> entry 1
        //
        // In most cases, there will only be a single I/O APIC so the GSI base will be 0, but just
        // in case there are multiple, we need to subtract so that we get the index relative to our
        // I/O APIC redirection table.
        const idx = pin - self.gsi_base;

        const redir_count = self.redirCount();
        if (idx > redir_count) {
            @branchHint(.unlikely);
            log.err("I/O APIC redirection index {d} out of bounds, count = {d}", .{ idx, redir_count });
        }

        const base = @intFromEnum(Registers.RedirectionTableBase);
        const low_index = base + @as(u8, @intCast(idx)) * 2;
        const high_index = low_index + 1;

        // write the low dword i.e. LVT
        self.write(u32, low_index, @bitCast(lvt));
        // write high dword i.e. destination APIC ID (overall bits 56-63, but for the dword this would
        // mean position 24)
        const high_dword = @as(u32, dest_apic) << 24;
        self.write(u32, high_index, high_dword);
        log.debug("I/O APIC programmed pin {d} with vector {x} and destination APIC ID {x:0>2}", .{
            pin, lvt.vector, dest_apic,
        });
    }

    /// How many redirection entries this I/O APIC supports
    pub fn redirCount(self: *IoApic) u32 {
        const version = self.read(u32, Registers.Version.get());
        return ((version >> 16) & 0xFF) + 1;
    }
};

/// I/O APIC registers that can be accessed using the IOREGSEL and IOWIN registers
pub const Registers = enum(u8) {
    /// I/O APIC ID register
    Id = 0x00,
    /// I/O APIC version register
    Version = 0x01,
    /// I/O APIC arbitration ID register
    ArbitrationId = 0x02,
    /// I/O APIC redirection table base address
    RedirectionTableBase = 0x10,

    pub fn get(self: Registers) u8 {
        return @intFromEnum(self);
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
pub const Lvt = packed struct(u32) {
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
    /// 00=one-shot, 01=periodic, 10=TSC-deadline
    timer_mode: u2,
    reserved: u13,
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
            .timer_mode = 0b00,
            .reserved = 0,
        };
    }
};

/// Interrupt vectors handled by the I/O APIC
pub const InterruptVectors = enum(u8) {
    PitTimer = 0x20,
    Keyboard = 0x21,
    HpetTimer = 0x30,
    pub fn get(self: InterruptVectors) u8 {
        return @intFromEnum(self);
    }
    /// Is the vector handled by the I/O APIC
    pub fn is(vector: u8) bool {
        return switch (vector) {
            0x20...0x30 => true,
            else => false,
        };
    }
};

pub var global_ioapic: IoApic = undefined;

pub fn init(rsdp_response: *limine.RsdpResponse) void {
    log.info("Initializing I/O APIC", .{});
    const rsdp = acpi.Rsdp2Descriptor.init(rsdp_response);
    const xsdt = rsdp.getXSDT();
    const madt_signature = "APIC";
    // find the MADT table
    const madt_hdr = xsdt.findSdtHeader(madt_signature) orelse @panic("MADT not found in XSDT");
    const madt: *acpi.Madt = @ptrCast(madt_hdr);
    var it = madt.iterator();
    // find the I/O APIC entry
    const entry = it.findNext(acpi.MadtEntryType.IoApic) orelse @panic("I/O APIC not found in MADT");
    global_ioapic = IoApic.init(entry);
}

/// Program the I/O APIC to route all the necessary interrupts to the LAPIC
pub fn routeVectors() void {
    routePit();
    routeKeyboard();
}

/// Program the I/O APIC to route the PIT timer interrupts to the LAPIC
fn routePit() void {
    // since we're using UEFI the PIT should appear as IRQ 2
    const pin = 2;
    const lvt = Lvt.init(InterruptVectors.PitTimer.get(), false);
    global_ioapic.program(pin, lvt, lapic.global_lapic.id());
}

/// Program the I/O APIC to route the keyboard interrupts to the LAPIC
fn routeKeyboard() void {
    // The PS/2 Keyboard is IRQ 1
    const pin = 1;
    const lvt = Lvt.init(InterruptVectors.Keyboard.get(), false);
    global_ioapic.program(pin, lvt, lapic.global_lapic.id());
}
