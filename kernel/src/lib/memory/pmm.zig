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
    /// Allocate a single physical page.
    pub fn alloc(self: *PhysicalMemoryManager) u64 {
        // panicking here is fine because there are no physical pages to allocate so we can't
        // recover from that
        const freePage = self.free_bitmap.findFirstSet() orelse @panic("Out of memory");
        self.free_bitmap.unset(freePage);
        return pageToAddress(freePage);
    }
    /// Deallocate the given physical page address.
    ///
    /// Returns false if the page is already free (double-free).
    pub fn dealloc(self: *PhysicalMemoryManager, address: u64) bool {
        if (!self.isFree(address)) {
            return false;
        }
        const page = addressToPage(address);
        self.free_bitmap.set(page);
        return true;
    }
    /// Check if an address is free.
    pub fn isFree(self: *PhysicalMemoryManager, address: u64) bool {
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
