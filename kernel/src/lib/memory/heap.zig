const std = @import("std");
const build_options = @import("build_options");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");

var fba: ?std.heap.FixedBufferAllocator = null;

/// Heap size for the kernel, calculated as a fraction of the total memory specified in build options.
pub const HEAP_SIZE: usize = (build_options.memory * 1024 * 1024) / 10;

pub fn init() void {
    const frame = pmm.global_pmm.alloc(HEAP_SIZE);
    const virt = paging.physToVirt(@intFromPtr(frame.ptr));
    const heap = @as([*]u8, @ptrFromInt(virt))[0..frame.len];
    for (heap) |*byte| {
        byte.* = 0; // Initialize the heap memory to zero
    }
    std.log.debug("Heap initialized at virtual address: {x:0>16}, size: {d}", .{ @intFromPtr(heap.ptr), heap.len });
    fba = std.heap.FixedBufferAllocator.init(heap);
}
