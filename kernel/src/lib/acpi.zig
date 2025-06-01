const std = @import("std");
const limine = @import("limine");
const paging = @import("memory/paging.zig");
const log = std.log.scoped(.acpi);

/// Root System Descriptor Pointer
pub const Rsdp2Descriptor = extern struct {
    signature: [8]u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    revision: u8 align(1),
    rsdt_address: u32 align(1),
    length: u32 align(1),
    xsdt_address: u64 align(1),
    extended_checksum: u8 align(1),
    reserved: [3]u8 align(1),
    pub fn init(response: *limine.RsdpResponse) *Rsdp2Descriptor {
        // convert the address to virtual
        const responseVirt = paging.physToVirt(response.address);
        const self = @as(*Rsdp2Descriptor, @ptrFromInt(responseVirt));
        if (!self.validateChecksum()) {
            @panic("RSDP validation failed");
        }
        return self;
    }
    pub fn getXSDT(self: *Rsdp2Descriptor) *Xsdt {
        if (self.xsdt_address == 0) {
            @panic("XSDT address is null");
        }
        const xsdtVirt = paging.physToVirt(self.xsdt_address);
        return @ptrFromInt(xsdtVirt);
    }
    fn validateChecksum(self: *Rsdp2Descriptor) bool {
        var sum: u8 = 0;
        const bytes = @as([*]u8, @ptrCast(self))[0..self.length];
        for (bytes) |byte| {
            sum +%= byte;
        }
        return (sum == 0);
    }
};

/// Represents the ACPI Extended System Description Table (XSDT),
/// which holds a header plus a variable array of 64‑bit physical pointers
/// to other ACPI tables (SDTs)
pub const Xsdt = extern struct {
    /// Standard ACPI table header common to all SDTs.
    sdt_header: AcpiSdtHeader,
    /// Returns a slice of the 64‑bit physical addresses of each entry in the XSDT.
    pub fn getEntries(self: *Xsdt) []align(1) u64 {
        const entry_count = self.getEntryCount();
        return @as([*]align(1) u64, @ptrFromInt(@intFromPtr(self) + @sizeOf(AcpiSdtHeader)))[0..entry_count];
    }
    /// Returns a pointer to the ACPI SDT header at index `n`, or null if out of range.
    ///
    /// Also converts the physical entry to a virtual address.
    pub fn getSdtHeader(self: *Xsdt, n: usize) ?*AcpiSdtHeader {
        const entries = self.getEntries();
        if (n >= entries.len) {
            log.err("XSDT entry index {d} out of range", .{n});
            return null;
        }
        const entry_virt = paging.physToVirt(entries[n]);
        const hdr: *AcpiSdtHeader = @ptrFromInt(entry_virt);
        log.debug("Retrieving XSDT entry at index {d} with signature {s}", .{ n, hdr.signature });
        return hdr;
    }
    /// Scans all entries for an SDT whose signature matches `signature` or null if not found.
    pub fn findSdtHeader(self: *Xsdt, signature: []const u8) ?*AcpiSdtHeader {
        const entries = self.getEntries();
        log.info("Searching XSDT for signature {s}", .{signature});
        for (0.., entries) |i, entry_addr| {
            log.debug("Examining entry {d} at phys 0x{x:0>16}", .{ i, entry_addr });
            const entry_virt = paging.physToVirt(entry_addr);
            const entry: *AcpiSdtHeader = @ptrFromInt(entry_virt);
            if (std.mem.eql(u8, &entry.signature, signature)) {
                log.info("Found signature {s} at index {d}", .{ signature, i });
                return entry;
            }
        }
        log.err("No XSDT entry with signature {s} found", .{signature});
        return null;
    }
    fn getEntryCount(self: *Xsdt) u64 {
        return (self.sdt_header.length - @sizeOf(AcpiSdtHeader)) / @sizeOf(u64);
    }
};

// source: https://wiki.osdev.org/MADT

/// Represents the ACPI Multiple APIC Description Table (MADT)
pub const Madt = extern struct {
    /// Standard ACPI table header common to all SDTs.
    sdt_header: AcpiSdtHeader align(1),
    /// Local APIC address
    local_apic_address: u32 align(1),
    /// Flags
    ///
    /// - Bit 0: 1 if the local APIC is enabled
    flags: u32 align(1),

    /// Iterator for the MADT entries
    pub fn iterator(self: *Madt) MadtIterator {
        return MadtIterator.init(self);
    }
    pub fn start(self: *Madt) u64 {
        return @intFromPtr(self) + @sizeOf(Madt);
    }
    pub fn end(self: *Madt) u64 {
        return @intFromPtr(self) + self.sdt_header.length;
    }
};

pub const MadtIterator = struct {
    madt: *Madt,
    current: u64,
    end: u64,
    pub fn init(madt: *Madt) MadtIterator {
        return MadtIterator{
            .madt = madt,
            .current = madt.start(),
            .end = madt.end(),
        };
    }
    /// Returns the next entry in the MADT or null if there are no more entries.
    ///
    /// Only use this if you are not using findNext() otherwise make sure to reset().
    pub fn next(self: *MadtIterator) ?MadtEntry {
        if (self.current >= self.end) {
            return null;
        }
        const hdr: *MadtEntryHeader = @ptrFromInt(self.current);
        const entry_ptr = self.current + @sizeOf(MadtEntryHeader);
        self.current += hdr.record_length;
        return switch (hdr.entry_type) {
            .ProcessorLocalApic => .{ .ProcessorLocalApic = @ptrFromInt(entry_ptr) },
            .IoApic => .{ .IoApic = @ptrFromInt(entry_ptr) },
            .IoApicIntSrcOverride => .{ .IoApicIntSrcOverride = @ptrFromInt(entry_ptr) },
            .IoApicNmiSrc => .{ .IoApicNmiSrc = @ptrFromInt(entry_ptr) },
            .LApicNmi => .{ .LApicNmi = @ptrFromInt(entry_ptr) },
            .LApicAddrOverride => .{ .LApicAddrOverride = @ptrFromInt(entry_ptr) },
            .LX2Apic => .{ .LX2Apic = @ptrFromInt(entry_ptr) },
        };
    }
    /// Returns the next entry in the MADT of the specified type or null if there are no more
    /// entries.
    ///
    /// Only use this if you are not using next() otherwise make sure to reset().
    pub fn findNext(self: *MadtIterator, entry_type: MadtEntryType) ?MadtEntry {
        while (self.current < self.end) {
            const hdr: *MadtEntryHeader = @ptrFromInt(self.current);
            const entry_ptr = self.current + @sizeOf(MadtEntryHeader);
            self.current += hdr.record_length;
            if (hdr.entry_type == entry_type) {
                return switch (hdr.entry_type) {
                    .ProcessorLocalApic => .{ .ProcessorLocalApic = @ptrFromInt(entry_ptr) },
                    .IoApic => .{ .IoApic = @ptrFromInt(entry_ptr) },
                    .IoApicIntSrcOverride => .{ .IoApicIntSrcOverride = @ptrFromInt(entry_ptr) },
                    .IoApicNmiSrc => .{ .IoApicNmiSrc = @ptrFromInt(entry_ptr) },
                    .LApicNmi => .{ .LApicNmi = @ptrFromInt(entry_ptr) },
                    .LApicAddrOverride => .{ .LApicAddrOverride = @ptrFromInt(entry_ptr) },
                    .LX2Apic => .{ .LX2Apic = @ptrFromInt(entry_ptr) },
                };
            }
        }
        return null;
    }
    pub fn reset(self: *MadtIterator) void {
        self.current = self.madt.start();
    }
};

pub const MadtEntry = union(MadtEntryType) {
    ProcessorLocalApic: *LApic,
    IoApic: *IoApic,
    IoApicIntSrcOverride: *IoApicIntSrcOverride,
    IoApicNmiSrc: *IoApicNmiSrc,
    LApicNmi: *LApicNmi,
    LApicAddrOverride: *LApicAddrOverride,
    LX2Apic: *LX2Apic,
};

/// Processor Local APIC
///
/// This type represents a single logical processor and its local interrupt controller.
pub const LApic = extern struct {
    /// ACPI Processor ID
    processor_id: u8 align(1),
    /// APIC ID
    id: u8 align(1),
    /// Flags
    ///
    /// - Bit 0: 1 if the processor is enabled
    /// - Bit 1: 1 if the processor is online capable
    // TODO: implement Flags for this
    flags: u32 align(1),
};

/// I/O APIC
///
/// This type represents an I/O APIC.
pub const IoApic = extern struct {
    /// I/O APIC ID
    id: u8 align(1),
    reserved: u8 align(1),
    /// I/O APIC address
    address: u32 align(1),
    /// Global system interrupt base
    gsi_base: u32 align(1),
};

/// I/O APIC Interrupt Source Override
///
/// This entry type contains the data for an Interrupt Source Override, explaining how IRQ
/// sources are mapped to global system interrupts.
///
/// Example:
/// The PIT Timer is connected to ISA IRQ 0x00, but the APIC is enabled it's connected to APIC
/// interrupt pin 2. In this case, we need an interrupt source override where the source entry (bus
/// source) is 0 and the global system interrupt is 2.
pub const IoApicIntSrcOverride = extern struct {
    /// Bus source
    ///
    /// This is usually constant (0) and is a reserved field.
    bus_source: u8 align(1),
    /// IRQ source
    ///
    /// This is the source IRQ pin for the override.
    irq_source: u8 align(1),
    /// Global system interrupt
    ///
    /// This is the target IRQ on the APIC for the override.
    gsi: u32 align(1),
    /// Flags
    flags: Flags align(1),
};

/// I/O APIC Non-maskable interrupt source
///
/// Specifies which I/O APIC interrupt inputs should be enabled as non-maskable.
pub const IoApicNmiSrc = extern struct {
    /// NMI Source
    nmi_src: u8 align(1),
    reserved: u8 align(1),
    /// Flags
    flags: Flags align(1),
    /// Global System Interrupt
    gsi: u32 align(1),
};

/// Local APIC Non-maskable interrupts
///
/// These can be configured with the LINT0 and LINT1 entries in the LVT of the relevant
/// processor's LAPIC.
pub const LApicNmi = extern struct {
    /// ACPI Processor ID (0xFF means all processors)
    processor_id: u8 align(1),
    /// Flags
    flags: Flags align(1),
    /// LINT# (0 or 1),
    lint_pin: u8 align(1),
};

/// Local APIC Address Override
///
/// This entry type is used to override the LAPIC address in the MADT header. There can only be
/// one of these defined in the MADT and if defined, the 64-bit LAPIC address stored within it
/// should be used instead of the 32-bit address stored in the MADT header.
pub const LApicAddrOverride = extern struct {
    reserved: u16 align(1),
    /// 64-bit physical address of Local APIC
    addr: u64 align(1),
};

/// Processor Local X2APIC
///
/// Represents a physical processor and its Local X2APIC. Identical to the LAPIC, but used only
/// when it wouldn't be able to hold the required values.
pub const LX2Apic = extern struct {
    reserved: u16 align(1),
    /// Processor's local x2APIC ID
    x2apic_id: u32 align(1),
    /// Flags (same as LAPIC flags)
    flags: u32 align(1),
    /// ACPI ID
    id: u32 align(1),
};

pub const Flags = packed struct(u16) {
    pub const Polarity = enum(u2) {
        /// Use the default settings.
        /// Is active-low for level-triggered interrupts.
        Default = 0b00,
        /// Active high
        ActiveHigh = 0b01,
        Reserved = 0b10,
        /// Active low
        ActiveLow = 0b11,
    };
    pub const TriggerMode = enum(u2) {
        /// Use the default settings (edge-triggered).
        Default = 0b00,
        /// Edge triggered
        EdgeTriggered = 0b01,
        Reserved = 0b10,
        /// Level triggered
        LevelTriggered = 0b11,
    };
    /// Polarity
    polarity: Polarity,
    /// Trigger mode
    trigger_mode: TriggerMode,
    /// Reserved
    reserved: u12 = 0,
};

pub const MadtEntryHeader = extern struct {
    /// Entry type
    entry_type: MadtEntryType align(1),
    /// Length of the entry
    /// (including the header)
    record_length: u8 align(1),
};

pub const MadtEntryType = enum(u8) {
    /// Processor Local APIC
    ProcessorLocalApic = 0,
    /// I/O APIC
    IoApic = 1,
    /// I/O APIC Interrupt Source Override
    IoApicIntSrcOverride = 2,
    /// I/O APIC Non-maskable interrupt source
    IoApicNmiSrc = 3,
    /// Local APIC Non-maskable interrupts
    LApicNmi = 4,
    /// Local APIC Address Override
    LApicAddrOverride = 5,
    /// Processor Local X2APIC
    LX2Apic = 9,
};

pub const AcpiSdtHeader = extern struct {
    signature: [4]u8 align(1),
    length: u32 align(1),
    revision: u8 align(1),
    checksum: u8 align(1),
    oem_id: [6]u8 align(1),
    oem_table_id: [8]u8 align(1),
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};
