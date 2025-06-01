const std = @import("std");
const limine = @import("limine");
const paging = @import("paging.zig");

const Range = std.bit_set.Range;
const ArrayBitSet = std.bit_set.ArrayBitSet;
const BitmapEntryType = u64;
const Bitmap = ArrayBitSet(BitmapEntryType, TOTAL_PAGES);

const log = std.log.scoped(.pmm);

pub var global_pmm: PhysicalMemoryManager = undefined;

const virtToPhys = paging.virtToPhys;
const physToVirt = paging.physToVirt;
const addressToPage = paging.addressToPage;
const pageToAddress = paging.pageToAddress;

const PAGE_SIZE = paging.PAGE_SIZE;
const TOTAL_PAGES = paging.TOTAL_PAGES;

extern const __kernel_start: u8;
extern const __kernel_end: u8;
extern const __limine_requests_start: u8;
extern const __limine_requests_end: u8;
extern const __kernel_code_start: u8;
extern const __kernel_code_end: u8;
extern const __kernel_rodata_start: u8;
extern const __kernel_rodata_end: u8;
extern const __kernel_data_start: u8;
extern const __kernel_data_end: u8;
extern const __kernel_bss_start: u8;
extern const __kernel_bss_end: u8;
// stack grows downward
extern const __kernel_stack_top: u8;
extern const __kernel_stack_bottom: u8;

pub fn init(memory_map: *limine.MemoryMapResponse, executable_address_response: *limine.ExecutableAddressResponse) void {
    global_pmm = PhysicalMemoryManager.init(memory_map, executable_address_response);
    log.info("Physical memory manager initialized", .{});
}

pub const PhysicalMemoryManager = struct {
    pub const Error = error{
        DoubleFree,
    };
    // In our bitmap, each bit represents a page:
    //   0 -> reserved, 1 -> free
    free_bitmap: Bitmap,
    pub fn init(memory_map: *limine.MemoryMapResponse, executable_address_response: *limine.ExecutableAddressResponse) PhysicalMemoryManager {
        // Attempt to obtain the memory map response from Limine.
        const entries = memory_map.getEntries();
        if (entries.len == 0) {
            @panic("No memory map entries found from Limine");
        }

        // Initialize the bitmap (which will initially pages set all pages as free)
        // and then mark all pages as reserved.
        var bitmap = Bitmap.initFull();
        bitmap.toggleAll();

        var total_usable: u64 = 0;
        for (entries) |entry| {
            // we mark every usable
            if (entry.type == .usable) {
                // but let's exclude the NULL (0x0000 - 0x1000) page i.e. the first page
                const base = if (entry.base == 0) entry.base + 0x1000 else entry.base;
                const length = if (entry.base == 0) entry.length - 0x1000 else entry.length;

                log.info("Usable memory region: {x:0>16} - {x:0>16}", .{ base, base + length });
                const start_page = addressToPage(base);
                const end_page = addressToPage(base + length);
                // Mark pages in this region as free
                bitmap.setRangeValue(.{ .start = start_page, .end = end_page }, true);
                total_usable += (end_page - start_page) * PAGE_SIZE;
            }
        }
        // also mark the pages occupied by the kernel itself
        const kernel_regions = &[_]Range{
            .{
                .start = @intFromPtr(&__limine_requests_start),
                .end = @intFromPtr(&__limine_requests_end),
            },
            .{
                .start = @intFromPtr(&__kernel_code_start),
                .end = @intFromPtr(&__kernel_code_end),
            },

            .{
                .start = @intFromPtr(&__kernel_rodata_start),
                .end = @intFromPtr(&__kernel_rodata_end),
            },

            .{
                .start = @intFromPtr(&__kernel_data_start),
                .end = @intFromPtr(&__kernel_data_end),
            },
            .{
                .start = @intFromPtr(&__kernel_bss_start),
                .end = @intFromPtr(&__kernel_bss_end),
            },
            .{
                .start = @intFromPtr(&__kernel_stack_bottom),
                .end = @intFromPtr(&__kernel_stack_top),
            },
        };

        const vbase = executable_address_response.virtual_base;
        const pbase = executable_address_response.physical_base;

        for (kernel_regions) |reg| {
            const start = reg.start;
            const length = reg.end - start;
            const offset = start - vbase; // how far into the kernel base is this pointer
            const phys_start = pbase + offset; // location in RAM for that offset
            const phys_end = phys_start + length;
            log.info("Kernel region: {x:0>16} - {x:0>16}", .{ phys_start, phys_end });
            const phys_start_page = addressToPage(phys_start);
            const phys_end_page = addressToPage(phys_end);
            // doing this because the next line might not result in any new pages being reserved
            const initial_count = bitmap.count();
            bitmap.setRangeValue(.{ .start = phys_start_page, .end = phys_end_page }, false);
            const final_count = bitmap.count();
            // if there were more pages free than now
            if (initial_count > final_count) {
                // it's likely that we've already reserved those pages
                @branchHint(.unlikely);
                // find out how many pages are now reserved and then reduce our total usable memory
                // counter accordingly
                const diff = initial_count - final_count;
                total_usable -= diff * PAGE_SIZE;
            }
        }

        log.info("Total usable memory: {d} MiB", .{total_usable / 1024 / 1024});
        std.debug.assert(bitmap.count() == addressToPage(total_usable));
        return PhysicalMemoryManager{ .free_bitmap = bitmap };
    }
    /// Allocate pages that fit given size
    pub fn alloc(self: *PhysicalMemoryManager, size: u64) []u8 {
        // how many pages needed to fullfill this allocation
        const pages_needed = addressToPage(size);
        const startPage = self.findContiguous(pages_needed);
        // mark the range as reserved
        self.free_bitmap.setRangeValue(.{ .start = startPage, .end = startPage + pages_needed }, false);
        const bytes_needed = pageToAddress(pages_needed);
        const addr = pageToAddress(startPage);
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
        const pages = addressToPage(size);
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
};
