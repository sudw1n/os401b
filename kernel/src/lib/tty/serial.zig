const std = @import("std");
const cpu = @import("../cpu.zig");

var serial: SerialWriter = undefined;

pub fn init() SerialError!void {
    serial = try SerialWriter.init();
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // The scope .none and message_level .debug stuff was implemented for one special case
    // (printing out the interrupt stack frame) and is not used anywhere else.
    // TODO: find a better way
    const scope_prefix = if (scope == .none) "" else "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ comptime message_level.asText() ++ "] " ++ scope_prefix;
    const fmt = if (message_level == .debug) format else prefix ++ format;
    serial.print(fmt ++ "\n", args) catch return;
}

pub const SerialError = error{
    InvalidSerialDevice,
    SerialPrint,
};

pub const SerialWriter = struct {
    const PORT = 0x3f8; // COM1
    const Self = @This();
    pub const Error = SerialError;

    pub fn init() SerialError!Self {
        // disable all interrupts
        cpu.out(u8, PORT + 1, 0x00);
        // enable DLAB (set baud rate divisor)
        cpu.out(u8, PORT + 3, 0x80);
        // set divisor to 38400 baud
        cpu.out(u8, PORT + 0, 0x03); // 3 (lo byte)
        cpu.out(u8, PORT + 1, 0x00); // 0 (hi byte)
        cpu.out(u8, PORT + 3, 0x03); // 8 bits, no parity, one stop bit
        cpu.out(u8, PORT + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
        cpu.out(u8, PORT + 4, 0x0B); // IRQs enabled, RTS/DSR set
        cpu.out(u8, PORT + 4, 0x1E); // Set in loopback mode, test the serial chip

        cpu.out(u8, PORT + 0, 0xAE); // Send a test byte
        if (cpu.in(u8, PORT + 0) != 0xAE) {
            @panic("Invalid serial device");
        }

        // If serial is not faulty set it in normal operation mode:
        // not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled
        cpu.out(u8, PORT + 4, 0x0F);

        return Self{};
    }

    pub fn print(self: Self, comptime fmt: []const u8, args: anytype) Error!void {
        std.fmt.format(self, fmt, args) catch return Error.SerialPrint;
    }

    pub fn write(_: Self, bytes: []const u8) Error!usize {
        writeStr(bytes);
        return bytes.len;
    }

    pub fn writeByte(self: Self, byte: u8) Error!void {
        _ = try self.write(&.{byte});
    }

    pub fn writeBytesNTimes(self: Self, bytes: []const u8, n: usize) Error!void {
        for (0..n) |_| {
            _ = try self.write(bytes);
        }
    }

    pub fn writeAll(self: Self, bytes: []const u8) Error!void {
        _ = try self.write(bytes);
    }

    fn isTransmitEmpty() bool {
        return cpu.in(u8, PORT + 5) & 0x20 == 0;
    }

    fn writeStr(s: []const u8) void {
        for (s) |c| {
            while (isTransmitEmpty()) {
                asm volatile ("pause");
            }
            cpu.out(u8, PORT, c);
        }
    }
};
