const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const log = std.log.scoped(.heap);

pub const Allocator = struct {
    heap: []u8,
    end_index: usize,
    remaining: usize,

    const ChunkHeader = struct {
        size: usize,
        status: ChunkStatus,
    };
    const ChunkStatus = enum(u8) { Free, Used };

    const Self = @This();

    pub fn init(size: u64) Self {
        const heap = vmm.global_vmm.alloc(size, &.{.Write}, null) catch |err| {
            log.err("Failed initializing heap allocator: {}", .{err});
            @panic("Failed to initialize heap allocator");
        };
        log.info("Heap allocator initialized at {x:0>16}:{x}", .{ @intFromPtr(heap.ptr), heap.len });
        return Self{
            .heap = heap,
            .end_index = 0,
            .remaining = heap.len,
        };
    }

    pub fn deinit(self: *Self) void {
        self.end_index = 0;
        self.remaining = 0;
        vmm.global_vmm.free(self.heap);
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = free,
            },
        };
    }

    pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        // todo: handle alignment
        // maybe reference this: https://ziglang.org/documentation/0.14.1/std/#std.heap.FixedBufferAllocator.alloc
        _ = alignment;

        var self: *Self = @ptrCast(@alignCast(ctx));

        if (self.end_index + len > self.heap.len) {
            return null;
        }

        // typecast the current position to a ChunkHeader pointer
        const hdr_ptr: *ChunkHeader = @ptrCast(@alignCast(self.heap[self.end_index..]));
        // fill in the header information
        hdr_ptr.* = ChunkHeader{
            .size = len,
            .status = ChunkStatus.Used,
        };
        // move forward the pointer
        self.end_index += @sizeOf(ChunkHeader);
        // return the memory after the header
        const chunk = self.heap[self.end_index .. self.end_index + len];
        // move forward the pointer by the size of allocation
        self.end_index += len;

        self.remaining -= (len + @sizeOf(ChunkHeader));

        log.info("alloc@{x:0>16}:{x}, remaining {x}", .{ @intFromPtr(chunk.ptr), chunk.len, self.remaining });
        return chunk.ptr;
    }

    pub fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;

        if (memory.len == 0) return;

        var self: *Self = @ptrCast(@alignCast(ctx));
        self.validatePtr(memory);

        const hdr_ptr: *ChunkHeader = ptrToHeader(memory.ptr);
        if (hdr_ptr.status == ChunkStatus.Used) {
            @branchHint(.likely);
            hdr_ptr.status = ChunkStatus.Free;
            self.remaining += hdr_ptr.size + @sizeOf(ChunkHeader);
            log.info("free@{x:0>16}:{x}, remaining {x}", .{ @intFromPtr(memory.ptr), memory.len, self.remaining });
            return;
        }
        @panic("Double free");
    }

    fn validatePtr(self: *Self, pointer: []u8) void {
        if (@intFromPtr(pointer.ptr) < @intFromPtr(self.heap.ptr) or @intFromPtr(pointer.ptr) >= @intFromPtr(self.heap.ptr) + self.heap.len) {
            @panic("free: given pointer is outside the heap bounds");
        }
    }

    fn ptrToHeader(ptr: [*]u8) *ChunkHeader {
        // Calculate the pointer to the header based on the pointer to the data
        return @ptrFromInt(@intFromPtr(ptr) - @sizeOf(ChunkHeader));
    }
};
