const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const log = std.log.scoped(.heap);

const VirtualMemoryManager = vmm.VirtualMemoryManager;

pub const Allocator = struct {
    vmm: *VirtualMemoryManager,
    heap: []u8,
    end_index: usize,
    remaining: usize,
    chunks_head: ?*ChunkHeader = null,
    chunks_tail: ?*ChunkHeader = null,

    const ChunkHeader = struct {
        // TODO: make this 0x10 bytes aligned, so that we can store the status in the first nibble
        size: usize,
        status: ChunkStatus,
        // for merging contiguous free chunks
        prev: ?*ChunkHeader = null,
        next: ?*ChunkHeader = null,
    };
    const ChunkStatus = enum(u8) { Free, Used };

    const Self = @This();

    pub fn init(vmm_instance: *VirtualMemoryManager, initial_size: u64) Self {
        const heap = vmm_instance.alloc(initial_size, &.{.Write}, null) catch |err| {
            log.err("Failed initializing heap allocator: {}", .{err});
            @panic("Failed to initialize heap allocator");
        };
        log.info("Heap allocator initialized at {x:0>16}:{x}", .{ @intFromPtr(heap.ptr), heap.len });
        return Self{
            .vmm = vmm_instance,
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

        const header_size = @sizeOf(ChunkHeader);

        const min_payload_size = 0x10;
        const size = @max(len, min_payload_size);

        var node = self.chunks_head;
        while (node) |hdr| {
            if (hdr.size >= size and hdr.status == .Free) {
                hdr.status = .Used;

                const chunk: []u8 = (@as([*]u8, @ptrCast(hdr)) + header_size)[0..size];
                self.remaining -= (size + header_size);
                log.info("alloc@{x:0>16}:{x} (reuse), remaining {x}", .{ @intFromPtr(chunk.ptr), size, self.remaining });

                @memset(chunk, 0);

                // check if the chunk is large enough to be split
                const leftover_size = hdr.size - size;
                if (leftover_size >= header_size + min_payload_size) {
                    // split the chunk
                    // new chunk will be after the user data section of the chunk we're about to
                    // return
                    const new_hdr_ptr: *ChunkHeader = @ptrCast(@alignCast(chunk.ptr + size));
                    const remaining_size = leftover_size - header_size;

                    log.debug("splitting chunk {x:0>16}:{x} into allocated chunk {x:0>16}:{x} and free chunk {x:0>16}:{x}", .{
                        @intFromPtr(hdr),         hdr.size,
                        @intFromPtr(chunk.ptr),   size,
                        @intFromPtr(new_hdr_ptr), leftover_size - header_size,
                    });
                    new_hdr_ptr.* = ChunkHeader{
                        .size = remaining_size,
                        .status = ChunkStatus.Free,
                        .prev = hdr,
                        .next = hdr.next,
                    };
                    if (hdr.next) |next| {
                        next.prev = new_hdr_ptr;
                    }
                    hdr.size = size;
                    hdr.next = new_hdr_ptr;
                }

                return chunk.ptr;
            }
            node = hdr.next;
        }

        if (self.end_index + size > self.heap.len) return null;

        // typecast the current position to a ChunkHeader pointer
        const hdr_ptr: *ChunkHeader = @ptrCast(@alignCast(self.heap[self.end_index..]));
        // fill in the header information
        hdr_ptr.* = ChunkHeader{
            .size = size,
            .status = ChunkStatus.Used,
            .prev = self.chunks_tail,
            .next = null,
        };

        // hook the newly carved out chunk at the tail of the doubly-linked list
        if (self.chunks_tail) |last| {
            // link the last chunk to the current one
            last.next = hdr_ptr;
        } else {
            // this is the first chunk
            self.chunks_head = hdr_ptr;
        }
        self.chunks_tail = hdr_ptr;

        // move forward the pointer
        self.end_index += header_size;
        // return the memory after the header
        const chunk = self.heap[self.end_index .. self.end_index + size];
        // move forward the pointer by the size of allocation
        self.end_index += size;

        self.remaining -= (size + header_size);

        log.info("alloc@{x:0>16}:{x}, remaining {x}", .{ @intFromPtr(chunk.ptr), size, self.remaining });
        @memset(chunk, 0);
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
            log.info("free@{x:0>16}:{x}({x}), remaining {x}", .{ @intFromPtr(memory.ptr), memory.len, hdr_ptr.size, self.remaining });
            // merging
            if (hdr_ptr.next) |next| {
                // merge with next chunk if it is free
                if (next.status == ChunkStatus.Free) {
                    log.debug("merging {x:0>16}:{x} on right with {x:0>16}:{x}", .{ @intFromPtr(hdr_ptr), hdr_ptr.size, @intFromPtr(next), next.size });
                    hdr_ptr.size += next.size + @sizeOf(ChunkHeader);
                    hdr_ptr.next = next.next;
                    if (next.next) |next_next| {
                        next_next.prev = hdr_ptr;
                    }
                }
            }
            if (hdr_ptr.prev) |prev| {
                // merge with previous chunk if it is free
                if (prev.status == ChunkStatus.Free) {
                    log.debug("merging {x:0>16}:{x} on left with {x:0>16}:{x}", .{ @intFromPtr(hdr_ptr), hdr_ptr.size, @intFromPtr(prev), prev.size });
                    prev.size += hdr_ptr.size + @sizeOf(ChunkHeader);
                    prev.next = hdr_ptr.next;
                    if (hdr_ptr.next) |next| {
                        next.prev = prev;
                    }
                }
            }
            return;
        }
        log.err("double free on {x:0>16}:{x}({x})", .{ @intFromPtr(memory.ptr), memory.len, hdr_ptr.size });
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
