const std = @import("std");
const limine = @import("limine");
const build_options = @import("build_options");
const registers = @import("../registers.zig");

const log = std.log.scoped(.paging);
const ArrayBitSet = std.bit_set.ArrayBitSet;
const BitmapEntryType = u64;
const Bitmap = ArrayBitSet(BitmapEntryType, TOTAL_PAGES);

extern const __kernel_start: u8;
extern const __kernel_end: u8;
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

pub const PAGE_SIZE = build_options.page_size;
pub const TOTAL_PAGES = blk: {
    const memoryMiB = build_options.memory;
    const totalBytes = memoryMiB * 1024 * 1024;
    break :blk totalBytes / PAGE_SIZE;
};

var HHDM_OFFSET: u64 = 0;
var allocator: PhysicalMemoryManager = undefined;
var pml4: *PML4 = undefined;

pub const PhysicalMemoryManager = struct {
    pub const Error = error{
        DoubleFree,
    };
    // In our bitmap, each bit represents a page:
    //   0 -> reserved, 1 -> free
    free_bitmap: Bitmap,
    pub fn init(memory_map: *limine.MemoryMapResponse) PhysicalMemoryManager {
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
                total_usable += length;
            }
        }
        // also mark the pages occupied by the kernel itself
        const kernel_bytes = @intFromPtr(&__kernel_end) - @intFromPtr(&__kernel_start);
        total_usable -= kernel_bytes;
        const kernel_pages = bytesToPage(kernel_bytes);
        // null page is already reserved
        log.info("Marking kernel pages as reserved: {d} pages", .{kernel_pages});
        bitmap.setRangeValue(.{ .start = 1, .end = kernel_pages }, false);

        log.info("Total usable memory: {d} MiB", .{total_usable / 1024 / 1024});
        std.debug.assert(bitmap.count() == bytesToPage(total_usable));

        return PhysicalMemoryManager{ .free_bitmap = bitmap };
    }
    /// Allocate pages that fit given size
    pub fn alloc(self: *PhysicalMemoryManager, size: u64) []u8 {
        // how many pages needed to fullfill this allocation
        const pages_needed = bytesToPage(size);
        const startPage = self.findContiguous(pages_needed);
        // mark the range as reserved
        self.free_bitmap.setRangeValue(.{ .start = startPage, .end = startPage + pages_needed }, false);
        const bytes_needed = pages_needed * PAGE_SIZE;
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
        const pages = bytesToPage(size);
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

/// 64-bit flags for a page table entry.
pub const PageTableEntryFlags = enum(u64) {
    /// Specifies whether the mapped frame or page table is loaded in memory.
    Present = 1 << 0,
    /// Controls whether writes to the mapped frame are allowed.
    Writable = 1 << 1,
    /// Controls whether accesses from userspace (ring 3) are permitted.
    UserAccessible = 1 << 2,
    /// If set, a “write-through” policy is used for caching.
    WriteThrough = 1 << 3,
    /// Disables caching for this entry.
    NoCache = 1 << 4,
    /// Set by the CPU when the entry is accessed.
    Accessed = 1 << 5,
    /// Set by the CPU on a write to the mapped frame.
    Dirty = 1 << 6,
    /// If set, the entry maps a huge page (2MB/1GB) instead of a page table.
    HugePage = 1 << 7,
    /// Indicates that the mapping is present in all address spaces.
    Global = 1 << 8,
    /// Available for OS use – additional bits.
    Bit_9 = 1 << 9,
    Bit_10 = 1 << 10,
    Bit_11 = 1 << 11,
    /// Available for OS use – additional bits.
    Bit_52 = 1 << 52,
    Bit_53 = 1 << 53,
    Bit_54 = 1 << 54,
    Bit_55 = 1 << 55,
    Bit_56 = 1 << 56,
    Bit_57 = 1 << 57,
    Bit_58 = 1 << 58,
    Bit_59 = 1 << 59,
    Bit_60 = 1 << 60,
    Bit_61 = 1 << 61,
    Bit_62 = 1 << 62,
    /// Forbid code execution from the mapped frame.
    NoExecute = 1 << 63,

    pub fn asU64(self: PageTableEntryFlags) u64 {
        return @intFromEnum(self);
    }
};

/// A single 64-bit page table entry.
///
/// The entry packs both the physical frame address and the flag bits.
/// The frame address is stored in bits 12–51.
pub const PageTableEntry = packed struct {
    const bit_12_51_mask = 0x000ffffffffff000;
    entry: u64,

    /// Initializes a page table entry with the given physical frame address and flags.
    /// The frame address is masked to ensure only the proper bits are set.
    pub fn init(frame_address: u64, flags: []const PageTableEntryFlags) PageTableEntry {
        // Mask the frame address to bits 12–51 (assuming a 4KiB page alignment)
        var entry: u64 = frame_address & bit_12_51_mask;
        for (flags) |flag| {
            entry |= flag.asU64();
        }
        return PageTableEntry{ .entry = entry };
    }

    pub fn checkFlag(self: PageTableEntry, flag: PageTableEntryFlags) bool {
        return (self.entry & flag.asU64()) != 0;
    }

    /// Sets (ORs in) the given flags.
    pub fn setFlags(self: *PageTableEntry, flags: []const PageTableEntryFlags) void {
        for (flags) |flag| {
            self.entry |= flag.asU64();
        }
    }

    /// Clears (removes) the given flags.
    pub fn clearFlags(self: *PageTableEntry, flags: []const PageTableEntryFlags) void {
        for (flags) |flag| {
            self.entry &= ~(flag.asU64());
        }
    }

    /// Returns the physical frame address stored in this entry.
    pub fn getFrameAddress(self: PageTableEntry) u64 {
        return self.entry & bit_12_51_mask;
    }
};

/// A generic page table of 512 entries.
///
/// A physical page is 4096 bytes; 512 entries of 8 bytes each
/// exactly fill that space. The same type is used for every level in the paging
/// hierarchy (PML4, PDPT, Page Directory, and Page Table).
pub const PageTable = struct {
    pub const ENTRY_COUNT = 512;
    entries: [ENTRY_COUNT]PageTableEntry,

    /// Allocate a page table
    pub fn init() *PageTable {
        // Allocate a 4096-byte block for the page table.
        const mem = physToVirt([]u8, allocator.alloc(@sizeOf(PageTable)));
        return @as(*PageTable, @ptrCast(@alignCast(mem)));
    }
    /// Initialize a page table with zeroed entries.
    pub fn initZero() *PageTable {
        const table = PageTable.init();
        for (&table.entries) |*entry| {
            entry.* = PageTableEntry.init(0, &.{});
        }
        return table;
    }
    pub fn deinit(self: *PageTable) void {
        // Deallocate the page table.
        const ptr = @as([*]u8, @ptrCast(self));
        const len = @sizeOf(PageTable);
        allocator.free(ptr[0..len]);
    }
};

/// For clarity, alias the PageTable type for each level of the paging hierarchy.
pub const PML4 = PageTable;
pub const PDPT = PageTable;
pub const PageDirectory = PageTable;
pub const PT = PageTable;

/// PML4 -> PDPT -> PageDirectory -> PT -> Physical Frame
pub fn init(memory_map: *limine.MemoryMapResponse, executable_address_response: *limine.ExecutableAddressResponse, hhdm_offset: u64) void {
    HHDM_OFFSET = hhdm_offset;
    allocator = PhysicalMemoryManager.init(memory_map);

    pml4 = PML4.initZero();
    log.info("PML4 allocated at address: {x:0>16}", .{@intFromPtr(pml4)});

    // map physical frames
    const entries = memory_map.getEntries();
    for (entries) |entry| {
        const flags: []const PageTableEntryFlags = switch (entry.type) {
            .usable, .bootloader_reclaimable => &.{ .Present, .Writable },
            .framebuffer, .acpi_reclaimable, .acpi_nvs => &.{ .Present, .Writable, .WriteThrough, .NoCache },
            else => {
                continue;
            },
        };
        const base = if (entry.base == 0) entry.base + 0x1000 else entry.base;
        const length = if (entry.base == 0) entry.length - 0x1000 else entry.length;
        const virt_addr = base + hhdm_offset;
        log.info("Mapping {s} region: virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{ @tagName(entry.type), virt_addr, virt_addr + length, base });
        mapRange(virt_addr, base, length, flags);
    }

    mapOwn(executable_address_response);

    // load the new page table base
    const cr3_val = virtToPhysRaw(@intFromPtr(pml4));
    log.info("Reloading CR3 with value: {x:0>16}", .{cr3_val});
    registers.Cr3.set(cr3_val);
}

// map own stack and code regions
fn mapOwn(executable_address_response: *limine.ExecutableAddressResponse) void {
    const regions = &[_]struct {
        name: []const u8,
        start: u64,
        end: u64,
        flags: []const PageTableEntryFlags,
    }{
        // .text: RX, read‑only, executable
        .{
            .name = "text",
            .start = @intFromPtr(&__kernel_code_start),
            .end = @intFromPtr(&__kernel_code_end),
            .flags = &.{.Present},
        },

        // .rodata: R‑only, non‑executable
        .{
            .name = "rodata",
            .start = @intFromPtr(&__kernel_rodata_start),
            .end = @intFromPtr(&__kernel_rodata_end),
            .flags = &.{ .Present, .NoExecute },
        },

        // .data: RW, non‑executable
        .{
            .name = "data",
            .start = @intFromPtr(&__kernel_data_start),
            .end = @intFromPtr(&__kernel_data_end),
            .flags = &.{ .Present, .Writable, .NoExecute },
        },

        // .bss: RW, non‑executable
        .{
            .name = "bss",
            .start = @intFromPtr(&__kernel_bss_start),
            .end = @intFromPtr(&__kernel_bss_end),
            .flags = &.{ .Present, .Writable, .NoExecute },
        },

        // stack: RW, non‑executable (grows down from top)
        .{
            .name = "stack",
            .start = @intFromPtr(&__kernel_stack_bottom),
            .end = @intFromPtr(&__kernel_stack_top),
            .flags = &.{ .Present, .Writable, .NoExecute },
        },
    };

    const vbase = executable_address_response.virtual_base;
    const pbase = executable_address_response.physical_base;

    for (regions) |reg| {
        const virt = reg.start;
        const length = reg.end - reg.start;
        const offset = virt - vbase; // how far into the kernel base is this pointer
        const phys = pbase + offset; // location in RAM for that offset

        log.info("Mapping {s} region virt {x:0>16}-{x:0>16} -> phys {x:0>16} (len={d} bytes)", .{ reg.name, virt, virt + length, phys, length });

        mapRange(virt, phys, length, reg.flags);
    }
}

pub fn mapRange(
    virt_addr: u64,
    phys_addr: u64,
    length: u64,
    flags: []const PageTableEntryFlags,
) void {
    const pages: u64 = bytesToPage(length);
    for (0..pages) |i| {
        const offset = pageToAddress(i);
        mapPage(virt_addr + offset, phys_addr + offset, flags);
    }
}

pub fn mapPage(virt: u64, phys: u64, flags: []const PageTableEntryFlags) void {
    const virt_addr = pageFloor(virt);
    const phys_addr = pageFloor(phys);

    log.debug("Mapping page: virt {x:0>16} -> phys {x:0>16}", .{ virt_addr, phys_addr });
    // Calculate indices for each paging level.
    //
    // Each of these indices is 9 bits wide:
    // 63 ... 48   47 ... 39   38 ... 30   29 ... 21   20 ... 12   11 ... 0
    // Sgn. ext    PML4        PDPR        Page dir    Page Table  Offset
    const pml4_index = (virt_addr >> 39) & 0x1FF;
    const pdpt_index = (virt_addr >> 30) & 0x1FF;
    const pd_index = (virt_addr >> 21) & 0x1FF;
    const pt_index = (virt_addr >> 12) & 0x1FF;

    var pdpt: *PDPT = undefined;
    var pml4_entry = &pml4.entries[pml4_index];
    log.debug("PML4 Entry at index {d}: {x:0>16}", .{ pml4_index, pml4_entry.getFrameAddress() });
    if (!pml4_entry.checkFlag(.Present)) {
        log.debug("  PML4 Entry not present. Creating new PDPT...", .{});
        pdpt = PDPT.initZero();
        pml4_entry.* = PageTableEntry.init(virtToPhysRaw(@intFromPtr(pdpt)), &.{ .Present, .Writable });
        log.debug("  New PDPT created at: {x:0>16}", .{@intFromPtr(pdpt)});
    } else {
        // our new pdpt's address is the pml4 entry without the flags
        log.debug("  PML4 Entry already present. Using existing PDPT.", .{});
        pdpt = @ptrFromInt(physToVirtRaw(pml4_entry.getFrameAddress()));
        log.debug("  Existing PDPT at: {x:0>16}", .{@intFromPtr(pdpt)});
    }

    var pd: *PageDirectory = undefined;
    var pdpt_entry = &pdpt.entries[pdpt_index];
    log.debug("PDPT Entry at index {d}: {x:0>16}", .{ pdpt_index, pdpt_entry.getFrameAddress() });
    if (!pdpt_entry.checkFlag(.Present)) {
        log.debug("  PDPT Entry not present. Creating new PD...", .{});
        pd = PageDirectory.initZero();
        pdpt_entry.* = PageTableEntry.init(virtToPhysRaw(@intFromPtr(pd)), &.{ .Present, .Writable });
        log.debug("  New PD created at: {x:0>16}", .{@intFromPtr(pd)});
    } else {
        log.debug("  PDPT Entry already present. Using existing PD.", .{});
        pd = @ptrFromInt(physToVirtRaw(pdpt_entry.getFrameAddress()));
        log.debug("  Existing PD at: {x:0>16}", .{@intFromPtr(pd)});
    }

    var pt: *PT = undefined;
    var pd_entry = &pd.entries[pd_index];
    log.debug("PD Entry at index {d}: {x:0>16}", .{ pd_index, pd_entry.getFrameAddress() });
    if (!pd_entry.checkFlag(.Present)) {
        log.debug("  PD Entry not present. Creating new PT...", .{});
        pt = PT.initZero();
        pd_entry.* = PageTableEntry.init(virtToPhysRaw(@intFromPtr(pt)), &.{ .Present, .Writable });
        log.debug("  New PT created at: {x:0>16}", .{@intFromPtr(pt)});
    } else {
        log.debug("  PD Entry already present. Using existing PT.", .{});
        pt = @ptrFromInt(physToVirtRaw(pd_entry.getFrameAddress()));
        log.debug("  Existing PT at: {x:0>16}", .{@intFromPtr(pt)});
    }

    // write the mapping into the page table
    log.debug("Mapping the physical address into PT at index {d}.", .{pt_index});
    pt.entries[pt_index] = PageTableEntry.init(phys_addr, flags);
    log.debug("Page mapped: virt {x:0>16} -> phys {x:0>16} (PML4[{d}], PDPT[{d}], PD[{d}], PT[{d}])", .{ virt_addr, phys_addr, pml4_index, pdpt_index, pd_index, pt_index });
}

inline fn getPml4() *PML4 {
    return @ptrFromInt(physToVirtRaw(registers.Cr3.get()));
}

fn pageToAddress(page: u64) u64 {
    return page * PAGE_SIZE;
}

fn bytesToPage(bytes: u64) u64 {
    return std.math.divCeil(u64, bytes, PAGE_SIZE) catch {
        @branchHint(.unlikely);
        @panic("bytesToPage: Divide error");
    };
}

fn addressToPage(address: u64) u64 {
    return address / PAGE_SIZE;
}

// Return virtual address (at HHDM offset) of the slice
// mem should be a slice with the `ptr` field value being a physical address.
pub fn virtToPhys(comptime T: type, mem: []u8) T {
    return @as(T, @ptrCast(@as([*]u8, @ptrFromInt(virtToPhysRaw(@intFromPtr(mem.ptr))))[0..mem.len]));
}

pub fn virtToPhysRaw(address: u64) u64 {
    return address - HHDM_OFFSET;
}

// Return virtual address (at HHDM offset) of the slice
// mem should be a slice with the `ptr` field value being a physical address.
pub fn physToVirt(comptime T: type, mem: []u8) T {
    return @as(T, @ptrCast(@as([*]u8, @ptrFromInt(physToVirtRaw(@intFromPtr(mem.ptr))))[0..mem.len]));
}

pub fn physToVirtRaw(address: u64) u64 {
    return HHDM_OFFSET + address;
}

fn pageFloor(addr: u64) u64 {
    return std.mem.alignBackward(u64, addr, PAGE_SIZE);
}
fn pageCeil(addr: u64) u64 {
    return std.mem.alignForward(u64, addr, PAGE_SIZE);
}
