const std = @import("std");
const pmm = @import("../pmm.zig");
const vmm = @import("../vmm.zig");

const log = std.log.scoped(.heap);

pub const Allocator = struct {
    heap: []u8,
    current: usize,
    remaining: usize,

    const ChunkHeader = extern struct {
        size: usize align(1),
        status: ChunkStatus align(1),
    };
    const ChunkStatus = enum(u8) { Free, Used };

    pub fn init(size: u64) Allocator {
        const heap = vmm.global_vmm.alloc(size, &.{.Write}, null);
        log.info("Heap allocator initialized at {x:0>16}:{x}", .{ @intFromPtr(heap.ptr), heap.len });
        return Allocator{
            .heap = heap,
            .current = 0,
            .remaining = heap.len,
        };
    }

    pub fn deinit(self: *Allocator) void {
        self.current = 0;
        self.remaining = 0;
        vmm.global_vmm.free(self.heap);
    }

    pub fn alloc(self: *Allocator, size: usize) []u8 {
        if (self.current + size > self.heap.len) {
            @panic("Allocator out of memory");
        }
        // typecast the current position to a ChunkHeader pointer
        const hdr_ptr: *ChunkHeader = @ptrCast(@alignCast(self.heap[self.current..]));
        // fill in the header information
        hdr_ptr.* = ChunkHeader{
            .size = size,
            .status = ChunkStatus.Used,
        };
        // move forward the pointer
        self.current += @sizeOf(ChunkHeader);
        // return the memory after the header
        const chunk = self.heap[self.current .. self.current + size];
        // move forward the pointer by the size of allocation
        self.current += size;
        self.remaining -= size + @sizeOf(ChunkHeader);
        log.debug("alloc@{x:0>16}:{x}, remaining {x}", .{ @intFromPtr(chunk.ptr), chunk.len, self.remaining });
        return chunk;
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

    pub fn free(self: *Allocator, chunk: []u8) void {
        self.validatePtr(chunk);

        const hdr_ptr: *ChunkHeader = ptrToHeader(chunk);
        if (hdr_ptr.status == ChunkStatus.Used) {
            @branchHint(.likely);
            hdr_ptr.status = ChunkStatus.Free;
            self.remaining += hdr_ptr.size + @sizeOf(ChunkHeader);
            log.debug("free@{x:0>16}:{x}, remaining {x}", .{ @intFromPtr(chunk.ptr), chunk.len, self.remaining });
            return;
        }
        @panic("Double free");
    }

    fn validatePtr(self: *Allocator, ptr: []u8) void {
        if (@intFromPtr(ptr) < @intFromPtr(self.heap.ptr) or @intFromPtr(ptr) >= @intFromPtr(self.heap.ptr) + self.heap.len) {
            @panic("free: given pointer is outside the heap bounds");
        }
    }

    fn ptrToHeader(ptr: []u8) *ChunkHeader {
        // Calculate the pointer to the header based on the pointer to the data
        return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(ChunkHeader));
    }
};
