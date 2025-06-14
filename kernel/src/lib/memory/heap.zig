const std = @import("std");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");

pub var allocator: std.mem.Allocator = undefined;

var fba: std.heap.FixedBufferAllocator = undefined;

pub fn init(size: u64) void {
    const frame = pmm.global_pmm.alloc(size);
    const virt = paging.physToVirt(@intFromPtr(frame.ptr));
    paging.mapRange(virt, @intFromPtr(frame.ptr), frame.len, &.{
        .Writable,
        .Present,
    });
    const heap = @as([*]u8, @ptrFromInt(virt))[0..frame.len];
    fba = std.heap.FixedBufferAllocator.init(heap);
    allocator = fba.allocator();
}
