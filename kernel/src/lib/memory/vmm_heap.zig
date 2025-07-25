const std = @import("std");
const build_options = @import("build_options");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");

const log = std.log.scoped(.vmm_heap);

var fba: ?std.heap.FixedBufferAllocator = null;

pub fn init() void {
    // Heap size for the Kernel VMM objects.
    const vmm_heap_size: usize = 0x10000; // 64 KiB
    const frame = pmm.global_pmm.alloc(vmm_heap_size);
    const virt = paging.physToVirt(@intFromPtr(frame.ptr));
    const heap = @as([*]u8, @ptrFromInt(virt))[0..frame.len];
    for (heap) |*byte| {
        byte.* = 0; // Initialize the heap memory to zero
    }
    log.info("Heap initialized at virtual address: {x:0>16}, size: {d}", .{ @intFromPtr(heap.ptr), heap.len });
    fba = std.heap.FixedBufferAllocator.init(heap);
}

pub fn deinit(pml4: *paging.PML4) void {
    fba.?.reset();
    // Free the physical frame used for the heap
    const heap_buffer = fba.?.buffer;
    paging.unmapRange(pml4, @intFromPtr(heap_buffer.ptr), heap_buffer.len);
    fba = null;
}

pub fn allocator() std.mem.Allocator {
    return (fba orelse @panic("Heap not initialized")).threadSafeAllocator();
}
