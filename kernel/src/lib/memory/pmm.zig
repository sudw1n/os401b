const std = @import("std");
const limine = @import("limine");
const build_options = @import("build_options");

const log = std.log.scoped(.paging);
const ArrayBitSet = std.bit_set.ArrayBitSet;
const BitmapEntryType = u64;
const Bitmap = ArrayBitSet(BitmapEntryType, TOTAL_PAGES);

const PAGE_SIZE = build_options.page_size;
const TOTAL_PAGES = blk: {
    const memoryMiB = build_options.memory;
    const totalBytes = memoryMiB * 1024 * 1024;
    break :blk totalBytes / PAGE_SIZE;
};

pub const PhysicalMemoryManager = struct {
    pub const Error = error{
        DoubleFree,
    };
    // In our bitmap, each bit represents a page:
    //   0 -> reserved, 1 -> free
    free_bitmap: Bitmap,
    pub fn init(memmap_request: limine.MemoryMapRequest) PhysicalMemoryManager {
        // Attempt to obtain the memory map response from Limine.
        const memmap_response = memmap_request.response orelse @panic("Failed to get memory map response from Limine");
        const entries = memmap_response.getEntries();
        if (entries.len == 0) {
            @panic("No memory map entries found from Limine");
        }

        // Initialize the bitmap (which will initially pages set all pages as free)
        // and then mark all pages as reserved.
        var bitmap = Bitmap.initFull();
        bitmap.toggleAll();

        var total_usable: u64 = 0;
        for (entries) |entry| {
            if (entry.type == .usable) {
                log.info("Usable memory region: {x:0>16} - {x:0>16}", .{ entry.base, entry.base + entry.length });
                const start_page = addressToPage(entry.base);
                const end_page = addressToPage(entry.base + entry.length);
                // Mark pages in this region as free
                bitmap.setRangeValue(.{ .start = start_page, .end = end_page }, true);
                total_usable += entry.length;
            }
        }
        log.info("Total usable memory: {d} MiB", .{total_usable / 1024 / 1024});
        std.debug.assert(bitmap.count() == total_usable / PAGE_SIZE);
        return PhysicalMemoryManager{
            .free_bitmap = bitmap,
        };
    }
    /// Allocate pages that fit given size
    pub fn alloc(self: *PhysicalMemoryManager, size: u64) []u8 {
        // how many pages needed to fullfill this allocation
        const pages_needed = std.math.divCeil(u64, size, PAGE_SIZE) catch {
            @branchHint(.unlikely);
            @panic("PhysicalMemoryManager.alloc(): Divide error");
        };
        const startPage = self.findContiguous(pages_needed);
        // mark the range as reserved
        self.free_bitmap.setRangeValue(.{ .start = startPage, .end = startPage + pages_needed }, false);
        const bytes_needed = pages_needed * PAGE_SIZE;
        const addr = self.pageToAddress(startPage);
        const ptr: [*]u8 = @ptrFromInt(addr);
        return ptr[0..bytes_needed];
    }
    // find a contiguous range of pages
    fn findContiguous(self: *PhysicalMemoryManager, pages_needed: u64) u64 {
        var candidate: u64 = 0;
        // ensure candidate plus pages_needed is within bounds
        while (candidate <= TOTAL_PAGES - pages_needed) {
            var i: u64 = 0;
            // check if all pages in the block starting at candidate are free
            while (i < pages_needed) : (i += 1) {
                if (!self.free_bitmap.isSet(candidate + i)) {
                    // if page candidate + i is reserved, then we need to restart past that index
                    candidate = candidate + i + 1;
                    break;
                }
            }
            if (i == pages_needed) return candidate;
        }
        @panic("Out of memory: contiguous block not found");
    }
    /// Deallocate the given physical page address.
    ///
    /// Returns false if the page is already free (double-free).
    pub fn free(self: *PhysicalMemoryManager, bytes: []u8) !void {
        const size = bytes.len;
        const pages = std.math.divCeil(u64, size, PAGE_SIZE) catch {
            @branchHint(.unlikely);
            @panic("PhysicalMemoryManager.alloc(): Divide error");
        };
        const address = @intFromPtr(bytes.ptr);
        std.debug.assert(address % PAGE_SIZE == 0);
        const startPage = addressToPage(address);
        const endPage = startPage + pages;
        std.debug.assert(endPage <= TOTAL_PAGES);
        for (startPage..endPage) |i| {
            if (self.free_bitmap.isSet(i)) {
                @branchHint(.unlikely);
                return Error.DoubleFree;
            }
        }
        self.free_bitmap.setRangeValue(.{ .start = startPage, .end = endPage }, true);
    }
    pub fn allocPage(self: *PhysicalMemoryManager) u64 {
        // panicking here is fine because there are no physical pages to allocate so we can't
        // recover from that
        const freePage = self.free_bitmap.findFirstSet() orelse @panic("Out of memory: no single free page found");
        self.free_bitmap.unset(freePage);
        return pageToAddress(freePage);
    }
    /// Check if an address is free.
    fn isFree(self: *PhysicalMemoryManager, address: u64) bool {
        const page = addressToPage(address);
        return self.free_bitmap.isSet(page);
    }
    fn pageToAddress(page: u64) u64 {
        return page * PAGE_SIZE;
    }
    fn addressToPage(address: u64) u64 {
        return address / PAGE_SIZE;
    }
};
