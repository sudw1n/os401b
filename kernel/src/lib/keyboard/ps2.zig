const std = @import("std");
const cpu = @import("../cpu.zig");
const lapic = @import("../interrupts/lapic.zig");

const log = std.log.scoped(.ps2);
const out = cpu.out;
const in = cpu.in;

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

const KeyboardSet = union(KeyboardSetType) {
    Set1: *Set1,
    Set2: *Set2,
    Set3: *Set3,
};

const KeyboardSetType = enum {
    Set1,
    Set2,
    Set3,
};

const Set1 = struct {};
const Set2 = struct {};
const Set3 = struct {};

pub fn handle() void {
    log.debug("handling keyboard", .{});
}

pub fn init() void {
    // try to set the keyboard to use a scancode we support
    switch (getScancodeSetUsed()) {
        .Set2, .Set3 => {
            if (!checkTranslation()) {
                log.warn("PS/2 controller translation isn't enabled, enabling", .{});
                enableTranslation();
            }
            log.info("switching to Set1", .{});
            keyboardUseSet(.Set1);
        },
        else => {},
    }
}

fn keyboardUseSet(set: KeyboardSetType) void {
    // start from a clean slate
    flushOutputBuffer();

    // command to get/set the scancode set
    const command1 = 0xF0;
    const command2: u8 = switch (set) {
        .Set1 => 0x1,
        .Set2 => 0x2,
        .Set3 => 0x3,
    };
    Port.Data.write(command1);
    Port.Data.write(command2);
}

pub fn getScancodeSetUsed() KeyboardSetType {
    // start from a clean slate
    flushOutputBuffer();

    // command to get/set the scancode set
    const command1 = 0xF0;
    // 0 -> get current set
    const command2 = 0x00;
    Port.Data.write(command1);
    Port.Data.write(command2);

    // since we are reading the current used set, the response will be 0xFA followed by one of the
    // below values:
    // 0x43 -> scancode set 1
    // 0x41 -> scancode set 2
    // 0x3f -> scancode set 3
    const ack = Port.Data.read();
    if (ack != 0xFA) {
        @panic("failed to get scancode set");
    }
    const set = Port.Data.read();
    switch (set) {
        0x43 => return KeyboardSetType.Set1,
        0x41 => return KeyboardSetType.Set2,
        0x3f => return KeyboardSetType.Set3,
        else => @panic("invalid byte returned while getting scancode set"),
    }
}

const ConfigFlag = enum(u8) {
    Translation = 1 << 6,
    pub fn asU8(self: ConfigFlag) u8 {
        return @intFromEnum(self);
    }
};

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
    setConfig(controller_config | @as(u8, (1 << 6)));
}

fn getConfig() u8 {
    // send 0x20 to Command register
    Port.StatusCommand.write(0x20);
    // read the reply from Data port
    return Port.Data.read();
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
        log.debug("flushing buffer", .{});
        // read the data port
        _ = Port.Data.read();
    }
}

fn check(status: StatusFlag) bool {
    return (Port.StatusCommand.get() & @intFromEnum(status)) != 0;
}

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
