const pmm = @import("../pmm.zig");
const vmm = @import("../vmm.zig");

pub const Allocator = struct {
    heap: []u8,
    current: usize,
    pub fn init(size: u64) Allocator {
        const heap = vmm.global_vmm.alloc(size, &.{.Write}, null);
        return Allocator{
            .heap = heap,
            .current = 0,
        };
    }

    pub fn deinit(self: Allocator) void {
        vmm.global_vmm.free(self.heap);
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
