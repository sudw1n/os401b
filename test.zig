const std = @import("std");
pub fn main() !void {
    std.debug.print("align = {x}, size = {x}\n", .{ @alignOf(ChunkHeader), @sizeOf(ChunkHeader) });
}

const ChunkHeader = struct {
    size: usize,
    status: ChunkStatus,
};
const ChunkStatus = enum(u8) { Free, Used };
