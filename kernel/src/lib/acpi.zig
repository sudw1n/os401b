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
        paging.mapPage(paging.physToVirtRaw(self.xsdt_address), self.xsdt_address, &.{ .Present, .Writable });
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

pub const Xsdt = extern struct {
    sdt_header: AcpiSdtHeader,
    pub fn getSdtHeader(self: *Xsdt, n: usize) *AcpiSdtHeader {
        const entry_count = (self.sdt_header.length - @sizeOf(AcpiSdtHeader)) / @sizeOf(u64);
        const entries = @as([*]align(1) u64, @ptrFromInt(@intFromPtr(self) + @sizeOf(AcpiSdtHeader)))[0..entry_count];
        const entry: *AcpiSdtHeader = @ptrFromInt(paging.physToVirtRaw(entries[n]));
        log.debug("Retrieving XSDT entry at index {d} = {s}", .{ n, entry.signature });
        return entry;
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
