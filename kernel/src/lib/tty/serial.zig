const std = @import("std");
const cpu = @import("../cpu.zig");

pub const SerialError = error{
    FaultySerial,
};

pub const SerialWriter = struct {
    const PORT = 0x3f8; // COM1
    const Self = @This();
    pub const Error = SerialError;

    pub fn init() SerialError!Self {
        // disable all interrupts
        cpu.out(PORT + 1, @as(u8, 0x00));
        // enable DLAB (set baud rate divisor)
        cpu.out(PORT + 3, @as(u8, 0x80));
        // set divisor to 38400 baud
        cpu.out(PORT + 0, @as(u8, 0x03)); // 3 (lo byte)
        cpu.out(PORT + 1, @as(u8, 0x00)); // 0 (hi byte)
        cpu.out(PORT + 3, @as(u8, 0x03)); // 8 bits, no parity, one stop bit
        cpu.out(PORT + 2, @as(u8, 0xC7)); // Enable FIFO, clear them, with 14-byte threshold
        cpu.out(PORT + 4, @as(u8, 0x0B)); // IRQs enabled, RTS/DSR set
        cpu.out(PORT + 4, @as(u8, 0x1E)); // Set in loopback mode, test the serial chip

        cpu.out(PORT + 0, @as(u8, 0xAE)); // Send a test byte
        if (cpu.in(u8, PORT + 0) != 0xAE) {
            return error.FaultySerial;
        }

        // If serial is not faulty set it in normal operation mode:
        // not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled
        cpu.out(PORT + 4, @as(u8, 0x0F));

        return Self{};
    }

    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) !void {
        try std.fmt.format(self, fmt, args);
    }

    pub fn write(_: Self, bytes: []const u8) !usize {
        writeStr(bytes);
        return bytes.len;
    }

    pub fn writeByte(self: Self, byte: u8) !void {
        _ = try self.write(&.{byte});
    }

    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) !void {
        for (0..n) |_| {
            _ = try self.write(bytes);
        }
    }

    pub fn writeAll(self: Self, bytes: []const u8) !void {
        _ = try self.write(bytes);
    }

    fn isTransmitEmpty() bool {
        return cpu.in(u8, PORT + 5) & 0x20 == 0;
    }

    fn writeStr(s: []const u8) void {
        for (s) |c| {
            while (isTransmitEmpty()) {}
            cpu.out(PORT, c);
        }
    }
};
