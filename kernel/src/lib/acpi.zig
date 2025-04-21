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
        const responseVirt = paging.physToVirtRaw(response.address);
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
        const xsdtVirt = paging.physToVirtRaw(self.xsdt_address);
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
        log.debug("XSDT entry count: {d}", .{entry_count});
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
        const entry_virt = paging.physToVirtRaw(entries[n]);
        const hdr: *AcpiSdtHeader = @ptrFromInt(entry_virt);
        log.debug("Retrieving XSDT entry at index {d} with signature {s}", .{ n, hdr.signature });
        return hdr;
    }
    /// Scans all entries for an SDT whose signature matches `signature` or null if not found.
    pub fn findSdtHeader(self: *Xsdt, signature: []const u8) ?*AcpiSdtHeader {
        const entries = self.getEntries();
        log.debug("Searching XSDT for signature {s}", .{signature});
        for (0.., entries) |i, entry_addr| {
            log.debug("Examining entry {d} at phys 0x{x:0>16}", .{ i, entry_addr });
            const entry_virt = paging.physToVirtRaw(entry_addr);
            const entry: *AcpiSdtHeader = @ptrFromInt(entry_virt);
            if (std.mem.eql(u8, entry.signature, signature)) {
                log.debug("Found signature {s} at index {d}", .{ signature, i });
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
