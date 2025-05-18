const std = @import("std");
const cpu = @import("../cpu.zig");
const lapic = @import("../interrupts/lapic.zig");

const log = std.log.scoped(.ps2);
const out = cpu.out;
const in = cpu.in;

const SET: KeyboardSetType = .Set2;

pub fn handle() void {
    lapic.global_lapic.sendEoi();
    // the fact that the CPU just interrupted us already guarantees there's a byte waiting in the
    // output buffer, so we don't use our normal `read()` instead just go for the raw `get()`
    const scancode = Port.Data.get();
    const processed_code = processScancode(scancode);
    log.debug("{}", .{processed_code});
}

pub fn init() void {
    log.debug("Initializing PS/2 keyboard", .{});
    keyboardUseSet(SET);
    flushOutputBuffer();
}

fn processScancode(code: u8) ScanCode {
    switch (SET) {
        .Set1 => return getScanCodeSet1(code),
        .Set2 => return getScancodeSet2(code),
        .Set3 => @panic("todo: implement scancode set 3"),
    }
}

fn getScanCodeSet1(code: u8) ScanCode {
    // check the MSB
    // if MSB = 1 it's a break code
    if (code & (1 << 7) != 0) {
        return .{
            .code = code,
            .type = .Break,
        };
    } else {
        return .{
            .code = code,
            .type = .Make,
        };
    }
}

fn getScancodeSet2(code: u8) ScanCode {
    // scancode is always a MAKE code unless prefixed by a 0xF0 byte
    if (code == 0xF0) {
        return .{
            .code = Port.Data.get(),
            .type = .Break,
        };
    } else {
        return .{
            .code = code,
            .type = .Make,
        };
    }
}

fn keyboardUseSet(set: KeyboardSetType) void {
    // start from a clean slate
    flushOutputBuffer();

    // command to get/set the scancode set
    const command = 0xF0;
    writeWithAck(command);

    const param: u8 = switch (set) {
        .Set1 => 0x1,
        .Set2 => 0x2,
        .Set3 => 0x3,
    };
    writeWithAck(param);
}

fn getScancodeSetUsed() KeyboardSetType {
    // start from a clean slate
    flushOutputBuffer();

    // command to get/set the scancode set
    const command = 0xF0;
    writeWithAck(command);

    // 0 -> get current set
    const param = 0x00;
    writeWithAck(param);

    // since we are reading the current used set, the response will be followed by one of the below
    // values:
    // 0x43 -> scancode set 1
    // 0x41 -> scancode set 2
    // 0x3f -> scancode set 3
    const set = Port.Data.read();
    switch (set) {
        0x43 => return KeyboardSetType.Set1,
        0x41 => return KeyboardSetType.Set2,
        0x3f => return KeyboardSetType.Set3,
        else => @panic("invalid byte returned while getting scancode set"),
    }
}

/// Normally the PS/2 controller converts the set 2 scancodes into set 1 (for legacy reasons), this
/// function checks if the translation is enabled.
fn checkTranslation() bool {
    // read the byte returned on the data port.
    // if the 6th bit is set than the translation is enabled.
    return (getConfig() & ConfigFlag.Translation.asU8()) != 0;
}

fn disableTranslation() void {
    // read current controller config byte
    const controller_config = getConfig();
    // send back the byte with the 6th bit cleared
    setConfig(controller_config & ~ConfigFlag.Translation.asU8());
}

fn enableTranslation() void {
    // read current controller config byte
    const controller_config = getConfig();
    // send back the byte with the 6th bit set
    setConfig(controller_config | ConfigFlag.Translation.asU8());
}

fn getConfig() u8 {
    // send 0x20 to Command register
    Port.StatusCommand.set(0x20);
    // read the reply from Data port
    return Port.Data.get();
}

fn setConfig(value: u8) void {
    // send 0x60 to Command register
    Port.StatusCommand.write(0x60);
    // write the value to Data port
    Port.Data.write(value);
}

/// Drain any stray bytes (scancodes or controller replies) that may be in the Data port
fn flushOutputBuffer() void {
    // discard any value in the output buffer until it's no longer full
    while (check(StatusFlag.OutputBufferFull)) {
        log.debug("flushing keyboard buffer", .{});
        // read the data port
        _ = Port.Data.read();
    }
}

/// Check if the given status flag is set in the status register
fn check(status: StatusFlag) bool {
    return (Port.StatusCommand.get() & @intFromEnum(status)) != 0;
}

/// Write with acknowledgement
fn writeWithAck(value: u8) void {
    while (true) {
        Port.Data.write(value);
        const response = Port.Data.read();
        // ACK
        if (response == 0xFA) return;
        // Resend
        if (response == 0xFE) continue;
        @panic("unexpected response from PS/2 keyboard");
    }
}

const Port = enum(u8) {
    /// Data Port:
    /// R/W transfers actual keyboard bytes (make- and break-codes, replies to commands, etc.)
    ///
    /// Commands to the keyboard ("switch your scancode set") always go to this port.
    Data = 0x60,
    /// Status/Command Port:
    /// Read -> Status register (to poll busy/full flags)
    /// Write -> Controller commands
    ///
    /// Commands to the controller ("give me the config byte") always go to this port.
    StatusCommand = 0x64,
    pub fn asU8(self: Port) u8 {
        return @intFromEnum(self);
    }
    pub fn get(self: Port) u8 {
        return in(u8, self.asU8());
    }
    pub fn set(self: Port, value: u8) void {
        out(u8, self.asU8(), value);
    }
    pub fn read(self: Port) u8 {
        // if reading from Data port, wait until output buffer full
        if (self == Port.Data) {
            while (!check(StatusFlag.OutputBufferFull)) {
                asm volatile ("pause");
            }
        }
        return self.get();
    }
    pub fn write(self: Port, value: u8) void {
        // wait until input buffer is empty
        while (check(StatusFlag.InputBufferFull)) {
            asm volatile ("pause");
        }
        self.set(value);
    }
};

const ScanCode = struct {
    /// For Set1:
    /// 0x00 - 0x7F: make codes
    /// 0x80 - 0xFF: break codes
    ///
    /// For Set2:
    /// 0x00 - 0xFF: make codes
    /// 0xF0,0x00-0xFF: break codes
    code: u8,
    type: ScanCodeType,
    pub fn format(value: ScanCode, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        const prefix = switch (value.type) {
            .Make => "MAKE",
            .Break => "BREAK",
        };
        try writer.print("{s}: 0x{x}", .{ prefix, value.code });
    }
};

const ScanCodeType = enum {
    Make,
    Break,
};

const KeyboardSetType = enum {
    Set1,
    Set2,
    Set3,
};

const ConfigFlag = enum(u8) {
    Translation = 1 << 6,
    pub fn asU8(self: ConfigFlag) u8 {
        return @intFromEnum(self);
    }
};

const StatusFlag = enum(u8) {
    /// Output buffer status.
    /// 0 = empty, 1 = full
    ///
    /// This must be set before attempting to read data from Data port
    OutputBufferFull = 1 << 0,
    /// Input buffer status.
    /// 0 = empty, 1 = full
    ///
    /// This must be clear before attempting to write data to either I/O port
    InputBufferFull = 1 << 1,
};
