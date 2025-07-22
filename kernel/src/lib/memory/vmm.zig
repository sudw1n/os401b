// TODO: build a virtual memory manager built around the paging system but one that isn't specific
// to x86_64. This tracks the pages that have been allocated along with their flags
const std = @import("std");
const limine = @import("limine");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const heap = @import("vmm_heap.zig");

const log = std.log.scoped(.vmm);

const PageTableEntryFlag = paging.PageTableEntryFlag;

pub var global_vmm: VirtualMemoryManager = undefined;

pub fn init(memory_map: *limine.MemoryMapResponse, executable_address_response: *limine.ExecutableAddressResponse) void {
    // we initialize it this way because we never deallocate the kernel PML4
    const pt_root = paging.PageTable.init();
    const allocator = heap.allocator();
    const virt_base = paging.physToVirt(pmm.global_pmm.getFirstFreePage());
    global_vmm = VirtualMemoryManager.init(pt_root, virt_base, allocator);

    // map physical frames
    const entries = memory_map.getEntries();
    for (entries) |entry| {
        const base = entry.base;
        const length = entry.length;
        const flags: []const VmObjectFlag = switch (entry.type) {
            .usable, .bootloader_reclaimable, .acpi_reclaimable => &.{.Write},
            .acpi_nvs => &.{ .Write, .Reserved },
            .framebuffer => &.{ .Write, .Mmio, .Reserved },
            else => {
                log.debug("Skipping {s} region: phys {x:0>16}:{x}", .{ @tagName(entry.type), base, length });
                continue;
            },
        };
        const virt = @as([*]u8, @ptrFromInt(paging.physToVirt(base)))[0..length];
        // Pre-map all available physical memory regions into the page tables.
        //
        // By establishing these mappings up front, the VMM won't need to allocate or map
        // pages on the fly for known regions. Once this initialization is done, any
        // physical address within these regions can be translated to its virtual address
        // simply by calling paging.physToVirt() and vice versa.
        global_vmm.map(virt, base, flags) catch |err| {
            log.err("Failed to map {s} region: phys {x:0>16}:{x}, error: {}", .{ @tagName(entry.type), base, length, err });
            @panic("Failed to map memory region");
        };
        log.info("Mapped {s} region: virt {x:0>16}:{x} -> phys {x:0>16}", .{ @tagName(entry.type), @intFromPtr(virt.ptr), length, base });
    }

    mapOwn(executable_address_response);
}

// TODO:
// 1. Get physical address of a virtual address.
//    We would first need to make sure there is a VMObject that covers the virtual address, and then we
//    can walk the page tables in software. We could probably also do the reverse by tracking the
//    physical address as a field in VmObject. If a physical address is provided, we can just search
//    for a region that contains it in our VmObjects linked list. The window of the region would be
//    given by the slice of the virtual address since the length is the same in both (virtual and
//    physical) cases.
// 2. Implement a complete deinit(). We will probably again need to track the physical address so as
//    to be able to free the physical pages with PMM.
// 3. Copying data between two separate virtual address spaces (VMM instances).

/// Manages the virtual address spaces of processes and the kernel.
///
/// There can be more than one instance of this manager. The kernel will have its own instance.
pub const VirtualMemoryManager = struct {
    /// Page table root for the virtual address space
    pt_root: *paging.PML4,
    /// Initial base address for the virtual address space
    virt_base: u64,
    /// A linked list of VM objects that have been allocated to that address space
    vm_objects: ?*VmObject,
    /// Allocator for the VM objects
    allocator: std.mem.Allocator,

    pub const Error = error{
        MisalignedRegion,
        OverlappingRegion,
    } || std.mem.Allocator.Error;

    pub fn init(pml4: *paging.PML4, virt_base: u64, allocator: std.mem.Allocator) VirtualMemoryManager {
        log.debug("Initializing VirtualMemoryManager with PML4 at {x:0>16}, virt_base {x:0>16}", .{ @intFromPtr(pml4), virt_base });
        return VirtualMemoryManager{
            .pt_root = pml4,
            .virt_base = virt_base,
            .vm_objects = null,
            .allocator = allocator,
        };
    }

    // TODO: complete this. we should also deallocate all the VmObject nodes in the linked list
    pub fn deinit(self: *VirtualMemoryManager) void {
        // Free the page table root
        self.pt_root.deinit();
    }

    /// Allocate virtual memory of the given size with the given flags.
    /// If `phys` is provided, the virtual address will be mapped to the corresponding physical address for the allocation.
    pub fn alloc(self: *VirtualMemoryManager, size: u64, flags: []const VmObjectFlag, phys: ?u64) Error![]u8 {
        const length = paging.pageCeil(size);
        log.debug("Attempting allocation of 0x{x} bytes", .{length});

        // we are finding the first gap big enough to hold `length`, and then inserting a new
        // VmObject node either at the front, in the middle, or at the end of the linked list.

        // we keep a prev pointer alonside current. if prev == null then it means we haven't yet seen
        // any region so in that case we start with self.virt_base
        var prev: ?*VmObject = null;
        var current: ?*VmObject = self.vm_objects;
        var found_base: u64 = 0;
        while (current) |vm| {
            // end of the previous region (or virt_base is none yet)
            const prev_end = if (prev) |p| @intFromPtr(p.region.ptr) + p.region.len else self.virt_base;
            const next_start = @intFromPtr(vm.region.ptr);

            // is there room between prev_end and next_start?
            if (prev_end + length <= next_start) {
                found_base = prev_end;
                break;
            }

            // advance
            prev = current;
            current = vm.next;
        }
        // if we fell off the end, just place the new allocation after the last region
        if (current == null) {
            const prev_end = if (prev) |p|
                @intFromPtr(p.region.ptr) + p.region.len
            else
                self.virt_base;
            found_base = prev_end;
        }

        // allocate and link in the new VmObject
        const obj = try self.allocator.create(VmObject);
        if (prev) |p| {
            p.next = obj;
        } else {
            // inserting at head
            self.vm_objects = obj;
        }

        // now we immediately back the virtual address with physical pages

        // if the allocation asks us to map the new virtual address to a physical address that it
        // has given, then we won't ask the PMM to allocate a new page **assuming** that physical
        // region has already been reserved in the PMM.
        const phys_addr: u64 = blk: {
            if (phys) |p| break :blk p;
            const p = pmm.global_pmm.alloc(length);
            // sanity check: since we've already page aligned the size, the returned physical frame
            // allocation shouldn't have a different length
            std.debug.assert(p.len == length);
            break :blk @intFromPtr(p.ptr);
        };

        obj.* = VmObject{
            .phys_addr = phys_addr,
            .region = @as([*]u8, @ptrFromInt(found_base))[0..length],
            .flags = VmObjectFlag.asRaw(flags),
            .next = current,
        };

        // here we use the flags translated into page table entry flags since our VMM will use
        // paging
        const entry_flags = VmObjectFlag.toX86(obj.flags);
        // add an assert for the above assumptions just to be sure.
        // i.e. the physical address that we have now retrieved is in fact reserved (either just now
        // or was already) at this point
        std.debug.assert(pmm.global_pmm.isFree(phys_addr) == false);

        log.info("Mapping virt {x:0>16}:{x} -> phys {x:0>16}, flags {s}", .{ @intFromPtr(obj.region.ptr), obj.region.len, phys_addr, flags });
        paging.mapRange(self.pt_root, @intFromPtr(obj.region.ptr), phys_addr, length, entry_flags);

        log.info("alloc@{x:0>16}:{x}", .{ @intFromPtr(obj.region.ptr), obj.region.len });
        return obj.region;
    }

    /// Map an existing physical range into the current address space.
    ///
    /// Parameters:
    ///  * `virt` – the virtual slice to map (ptr + len both page-aligned)
    ///  * `phys` – the physical base address to map to
    ///  * `flags` – slice of `VmObjectFlag` controlling caching, permissions, etc.
    ///
    /// Requirements:
    ///  * `virt.ptr` must be page-aligned.
    ///  * `virt.len` must be a non-zero multiple of the page size.
    ///  * The `virt` range must not overlap any already-mapped region.
    ///  * `phys` must point to a reserved physical region of at least `virt.len` bytes.
    ///
    /// Errors:
    ///  * `MisalignedRegion` if `virt` isn't page-aligned or `len` isn't a multiple.
    ///  * `OverlappingRegion` if the requested range overlaps an existing VmObject.
    ///  * `OutOfMemory` if allocator errors on OOM.
    ///
    /// On success, a new `VmObject` is linked into `vm_objects` list and the mapping is live.
    pub fn map(self: *VirtualMemoryManager, virt: []u8, phys: ?u64, flags: []const VmObjectFlag) Error!void {
        const start = @intFromPtr(virt.ptr);
        const len = virt.len;

        if (len == 0) {
            log.err("zero-length mapping requested: virt {x:0>16}", .{start});
            return Error.MisalignedRegion;
        }

        // round down start, round up length
        const aligned_start = paging.pageFloor(start);
        const aligned_length = paging.pageCeil(len);
        if (aligned_start != start or aligned_length != len) {
            log.err("misaligned region: virt {x:0>16}:{x} -> {x:0>16}:{x}", .{ start, len, aligned_start, aligned_length });
            return Error.MisalignedRegion;
        }

        // find an insertion point into the sorted linked list by virtual address
        var prev: ?*VmObject = null;
        var curr: ?*VmObject = self.vm_objects;
        while (curr) |node| {
            const node_start = @intFromPtr(node.region.ptr);
            const node_end = node_start + node.region.len;
            if (node_end <= start) {
                // the node is entirely before our region so keep searching forward
                prev = curr;
                curr = node.next;
            } else {
                // otherwise we have reached the node region that might come after our given region
                break;
            }
        }

        // check for overlap before insertion
        if (curr) |node| {
            const node_start = @intFromPtr(node.region.ptr);
            const node_end = node_start + node.region.len;
            // the first check can short-circuit
            if ((start < node_end) and (start + len > node_start)) {
                log.err("overlapping region: virt {x:0>16}:{x} overlaps with existing region {x:0>16}:{x}", .{ start, len, node_start, node.region.len });
                return Error.OverlappingRegion;
            }
        }

        const raw_flags = VmObjectFlag.asRaw(flags);
        const obj = try self.allocator.create(VmObject);

        if (prev) |p| {
            p.next = obj;
        } else {
            // inserting at head
            self.vm_objects = obj;
        }

        // back the virtual address with physical pages immediately
        const entry_flags = VmObjectFlag.toX86(raw_flags);

        const phys_addr = blk: {
            if (phys) |p| break :blk p;
            const p = pmm.global_pmm.alloc(len);
            // sanity check: since we've already page aligned the size, the returned physical frame
            // allocation shouldn't have a different length
            std.debug.assert(p.len == len);
            break :blk @intFromPtr(p.ptr);
        };
        log.info("Mapping virt {x:0>16}:{x} -> phys {x:0>16}, flags {s}", .{ start, len, phys_addr, flags });

        obj.* = VmObject{
            .phys_addr = phys_addr,
            .region = virt,
            .flags = raw_flags,
            .next = curr,
        };

        paging.mapRange(self.pt_root, start, phys_addr, len, entry_flags);

        return;
    }

    pub fn free(self: *VirtualMemoryManager, memory: []u8) void {
        const memory_ptr_val = @intFromPtr(memory.ptr);

        log.debug("Attempting free for 0x{x:0>16}:{x}", .{ memory_ptr_val, memory.len });

        var prev: ?*VmObject = null;
        var current: ?*VmObject = self.vm_objects;
        while (current) |vm| {
            const region_ptr_val = @intFromPtr(vm.region.ptr);
            if ((memory_ptr_val >= region_ptr_val) and ((memory_ptr_val + memory.len) <= (region_ptr_val + vm.region.len))) {
                // the given memory falls in this region, so we free this node
                if (prev) |p| p.next = vm.next;
                vm.next = null;
                log.info("free@{x:0>16}:{x}", .{ region_ptr_val, vm.region.len });
                paging.unmapRange(self.pt_root, region_ptr_val, memory.len);
                return;
            }
            prev = current;
            current = vm.next;
        }

        log.warn("No allocated region found matching {x:0>16}:{x}, nothing to free", .{ memory_ptr_val, memory.len });
    }

    pub fn create(self: *VirtualMemoryManager, comptime T: type, flags: []const VmObjectFlag, phys: ?u64) Error!*T {
        const size = @sizeOf(T);
        const ptr = try self.alloc(size, flags, phys);
        return @ptrCast(@alignCast(ptr));
    }

    pub fn destroy(self: *VirtualMemoryManager, comptime T: type, memory: *T) void {
        const size = @sizeOf(T);
        const ptr = @as([*]u8, @ptrCast(memory))[0..size];
        self.free(ptr);
    }

    pub fn switchTo(self: *VirtualMemoryManager) void {
        // Switch to the page table root for this address space
        paging.switchToPML4(self.pt_root);
    }

    pub fn format(self: VirtualMemoryManager, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("VirtualMemoryManager {{\n", .{});
        try writer.print("  PML4 Root: {x:0>16}\n", .{@intFromPtr(self.pt_root)});
        try writer.print("  Base: {x:0>16}\n", .{self.virt_base});
        try writer.print("  Regions {{\n", .{});
        var current: ?*VmObject = self.vm_objects;
        while (current) |vm| {
            const comma = if (vm.next) |_| "," else "";
            try writer.print("    {x:0>16}:{x}{s}\n", .{ @intFromPtr(vm.region.ptr), vm.region.len, comma });
            current = vm.next;
        }
        try writer.print("  }}\n", .{});
        try writer.print("}}", .{});
    }
};

const VmObject = struct {
    phys_addr: u64,
    region: []u8,
    flags: u64,
    next: ?*VmObject,
};

/// Flags for VM objects, used to determine how the memory should be mapped.
pub const VmObjectFlag = enum(u64) {
    /// Disables the VM region
    Disabled = 1 << 0,
    /// Makes the VM region writable
    Write = 1 << 1,
    /// Makes the VM region executable
    Exec = 1 << 2,
    /// Makes the VM region userspace-accessible
    User = 1 << 3,
    /// Marks the VM region as Memory-Mapped I/O. Setting this flag also implies Reserved.
    ///
    /// This effectively disables caching as well as ensures every write is immediately and
    /// synchronously propagated to the backing store.
    ///
    /// If this bit is cleared, it indicates the object is working (anonymous) memory.
    Mmio = 1 << 4,
    /// Marks the VM region as reserved in the physical address space meaning it should remain
    /// reserved in the PMM.
    Reserved = 1 << 5,

    pub fn asInt(self: VmObjectFlag) u64 {
        return @intFromEnum(self);
    }

    pub fn check(self: VmObjectFlag, flags: u64) bool {
        return flags & self.asInt() != 0;
    }

    /// convert the given slice of VmObjectFlag to a single u64 value
    pub fn asRaw(slice: []const VmObjectFlag) u64 {
        var value: u64 = 0;
        for (slice) |flag| {
            value |= flag.asInt();
        }
        return value;
    }

    /// convert the VM object flags to x86_64 page table flags
    pub fn toX86(flags: u64) u64 {
        var value: u64 = 0;
        if (!VmObjectFlag.Disabled.check(flags)) {
            value |= PageTableEntryFlag.Present.asInt();
        }
        if (VmObjectFlag.Write.check(flags)) {
            value |= PageTableEntryFlag.Writable.asInt();
        }
        if (!VmObjectFlag.Exec.check(flags)) {
            value |= PageTableEntryFlag.NoExecute.asInt();
        }
        if (VmObjectFlag.User.check(flags)) {
            value |= PageTableEntryFlag.UserAccessible.asInt();
        }
        if (VmObjectFlag.Mmio.check(flags)) {
            value |= (PageTableEntryFlag.WriteThrough.asInt() | PageTableEntryFlag.NoCache.asInt() | PageTableEntryFlag.Reserved.asInt());
        }
        if (VmObjectFlag.Reserved.check(flags)) {
            value |= PageTableEntryFlag.Reserved.asInt();
        }
        return value;
    }

    pub fn format(value: VmObjectFlag, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{@tagName(value)});
    }
};

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

// map the kernel's own memory regions
fn mapOwn(executable_address_response: *limine.ExecutableAddressResponse) void {
    const vbase = executable_address_response.virtual_base;
    const pbase = executable_address_response.physical_base;

    // The regions of the kernel with appropriate permissions for page table setup
    const kernel_regions = &[_]struct {
        name: [:0]const u8,
        start: u64,
        end: u64,
        flags: []const VmObjectFlag,
    }{
        // .limine_requests: R, read‑only, non-executable
        .{
            .name = "limine_requests",
            .start = @intFromPtr(&__limine_requests_start),
            .end = @intFromPtr(&__limine_requests_end),
            .flags = &.{.Reserved},
        },
        // .text: RX, read‑only, executable
        .{
            .name = "text",
            .start = @intFromPtr(&__kernel_code_start),
            .end = @intFromPtr(&__kernel_code_end),
            .flags = &.{ .Reserved, .Exec },
        },

        // .rodata: R, read-only, non‑executable
        .{
            .name = "rodata",
            .start = @intFromPtr(&__kernel_rodata_start),
            .end = @intFromPtr(&__kernel_rodata_end),
            .flags = &.{.Reserved},
        },

        // .data: RW, non‑executable
        .{
            .name = "data",
            .start = @intFromPtr(&__kernel_data_start),
            .end = @intFromPtr(&__kernel_data_end),
            .flags = &.{ .Reserved, .Write },
        },

        // .bss: RW, non‑executable
        .{
            .name = "bss",
            .start = @intFromPtr(&__kernel_bss_start),
            .end = @intFromPtr(&__kernel_bss_end),
            .flags = &.{ .Reserved, .Write },
        },

        // stack: RW, non‑executable (grows down from top)
        .{
            .name = "stack",
            .start = @intFromPtr(&__kernel_stack_bottom),
            .end = @intFromPtr(&__kernel_stack_top),
            .flags = &.{ .Reserved, .Write },
        },
    };

    for (kernel_regions) |reg| {
        const virt_addr = reg.start; // ensure the start is start address is
        const length = paging.pageCeil(reg.end - reg.start); // ensure the length is page-aligned
        const offset = virt_addr - vbase; // how far into the kernel base is this pointer
        const phys_addr = pbase + offset; // location in RAM for that offset

        const virt = @as([*]u8, @ptrFromInt(virt_addr))[0..length];
        global_vmm.map(virt, phys_addr, reg.flags) catch |err| {
            log.err("Failed to map kernel region {s}: virt {x:0>16}:{x} -> phys {x:0>16}, error: {}", .{ reg.name, virt_addr, length, phys_addr, err });
            @panic("Failed to map kernel region");
        };
        log.info("Mapped kernel {s} region virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{ reg.name, virt_addr, virt_addr + length, phys_addr });
    }
}
