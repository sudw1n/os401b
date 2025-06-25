const std = @import("std");
const build_options = @import("build_options");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");

pub var allocator: std.mem.Allocator = undefined;

var fba: std.heap.FixedBufferAllocator = undefined;
/// Heap size for the kernel, calculated as a fraction of the total memory specified in build options.
pub const HEAP_SIZE: usize = (build_options.memory * 1024 * 1024) / 10;

pub fn init() void {
    const frame = pmm.global_pmm.alloc(HEAP_SIZE);
    const virt = paging.physToVirt(@intFromPtr(frame.ptr));
    paging.mapRange(virt, @intFromPtr(frame.ptr), frame.len, &.{
        .Writable,
        .Present,
    });
    const heap = @as([*]u8, @ptrFromInt(virt))[0..frame.len];
    fba = std.heap.FixedBufferAllocator.init(heap);
    allocator = fba.allocator();
}
