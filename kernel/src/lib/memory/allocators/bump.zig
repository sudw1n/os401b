const pmm = @import("../pmm.zig");
const paging = @import("../paging.zig");

pub const Allocator = struct {
    heap: []u8,
    current: usize,
    pub fn init(size: u64) Allocator {
        const frame = pmm.global_pmm.alloc(size);
        const virt = paging.physToVirt(@intFromPtr(frame.ptr));
        paging.mapRange(virt, @intFromPtr(frame.ptr), frame.len, &.{
            .Writable,
            .Present,
        });
        const heap = @as([*]u8, @ptrFromInt(virt))[0..frame.len];
        return Allocator{
            .heap = heap,
            .current = 0,
        };
    }

    pub fn deinit(self: Allocator) void {
        pmm.global_pmm.free(self.heap);
    }

    pub fn alloc(self: *Allocator, size: usize) []u8 {
        if (self.current + size > self.heap.len) {
            @panic("Allocator out of memory");
        }
        const ptr = self.heap[self.current .. self.current + size];
        self.current += size;
        return ptr;
    }

    pub fn allocZ(self: *Allocator, size: usize) []u8 {
        const ptr = self.alloc(size);
        for (ptr) |*byte| {
            byte.* = 0; // Initialize the memory to zero
        }
        return ptr;
    }

    pub fn create(self: *Allocator, comptime T: type) *T {
        const size = @sizeOf(T);
        const ptr = self.alloc(size);
        return @ptrCast(@alignCast(ptr));
    }

    pub fn createZ(self: *Allocator, comptime T: type) *T {
        const size = @sizeOf(T);
        const ptr = self.allocZ(size);
        return @ptrCast(@alignCast(ptr));
    }

    pub fn free(self: *Allocator, ptr: []u8) void {
        // In a simple allocator, we don't actually free memory.
        // This is a no-op.
        _ = self;
        _ = ptr;
        return;
    }
};
