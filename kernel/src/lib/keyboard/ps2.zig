const std = @import("std");
const cpu = @import("../cpu.zig");
const lapic = @import("../interrupts/lapic.zig");

const log = std.log.scoped(.ps2);
const out = cpu.out;
const in = cpu.in;

var ps2_driver: Ps2Driver = undefined;

pub fn init() void {
    log.debug("Force enabling PS/2 scancode translation", .{});
    enableTranslation();

    // keyboardUseSet(SET);
    flushOutputBuffer();

    ps2_driver = Ps2Driver.init();

    log.info("Initialized PS/2 keyboard", .{});
}

pub fn handle() void {
    lapic.global_lapic.sendEoi();
    // the fact that the CPU just interrupted us already guarantees there's a byte waiting in the
    // output buffer, so we don't use our normal `read()` instead just go for the raw `get()`
    const scancode = Port.Data.get();
    ps2_driver.processScancode(scancode);
}

pub const Ps2Driver = struct {
    /// A circular buffer to store the scancodes
    buffer: [max_buffer_size]KeyEvent,
    /// The current position in the buffer
    buf_position: usize,
    /// To handle multi-byte scancodes, we implement a simple state machine.
    /// This holds the current state of the state machine.
    current_state: State,

    const State = enum {
        /// The normal state, where we expect to receive a single byte
        /// After being in the prefix state and reading a byte, we also go back to this state.
        Normal,
        /// The prefix state, where the driver has encountered a prefix byte. While in this state,
        /// the next read is an extended scancode.
        Prefix,
    };

    const max_buffer_size = 255;

    pub fn init() Ps2Driver {
        return Ps2Driver{
            .buffer = undefined,
            .buf_position = 0,
            .current_state = .Normal,
        };
    }
    fn processScancode(self: *Ps2Driver, code: u8) void {
        if (code == 0xE0) {
            // this is a prefix byte, so we go to the prefix state
            self.current_state = .Prefix;
            return;
        }

        const key_event = getKeyEvent(code);
        self.buffer[self.buf_position] = key_event;
        self.buf_position = (self.buf_position + 1) % max_buffer_size;

        if (self.current_state == .Prefix) {
            // if we were in the prefix state, we go back to the normal state
            self.current_state = .Normal;
        }

        log.debug("buffer position: {d}", .{self.buf_position});
        log.debug("{s}", .{key_event});
    }

    fn getKeyEvent(code: u8) KeyEvent {
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
};

const Led = enum(u8) {
    /// Scroll Lock LED
    ScrollLock = 1 << 0,
    /// Num Lock LED
    NumLock = 1 << 1,
    /// Caps Lock LED
    CapsLock = 1 << 2,
    pub fn asU8(self: Led) u8 {
        return @intFromEnum(self);
    }
};

fn setLed(led: Led) void {
    // send 0xED to Command register
    Port.StatusCommand.writeWithAck(0xED);
    // write the value to Data port
    Port.Data.writeWithAck(led.asU8());
}

/// Check if the given status flag is set in the status register
fn check(status: StatusFlag) bool {
    return (Port.StatusCommand.get() & @intFromEnum(status)) != 0;
}

/// Enable PS/2 scancode translation
fn enableTranslation() void {
    // read current controller config byte
    const controller_config = getConfig();
    // send back the byte with the 6th bit set
    setConfig(controller_config | ConfigFlag.Translation.asU8());
}

/// Get the current controller config byte
fn getConfig() u8 {
    // send 0x20 to Command register
    Port.StatusCommand.set(0x20);
    // read the reply from Data port
    return Port.Data.get();
}

/// Set the controller config byte
fn setConfig(value: u8) void {
    // send 0x60 to Command register
    Port.StatusCommand.write(0x60);
    // write the value to Data port
    Port.Data.write(value);
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
    /// Write with acknowledgement
    fn writeWithAck(self: Port, value: u8) void {
        while (true) {
            self.write(value);
            const response = Port.Data.read();
            // ACK
            if (response == 0xFA) return;
            // Resend
            if (response == 0xFE) continue;
            @panic("unexpected response from PS/2 keyboard");
        }
    }
};

const KeyEvent = struct {
    /// For Set1:
    /// 0x00 - 0x7F: make codes
    /// 0x80 - 0xFF: break codes
    code: u8,
    type: ScanCodeType,
    /// To keep track of the modifier keys when this event was generated.
    status_mask: u8,
    pub fn format(value: KeyEvent, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
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

const Modifier = enum(u8) {
    None = 0,
    Shift = 1 << 0,
    Ctrl = 1 << 1,
    Alt = 1 << 2,
    Meta = 1 << 3,
    CapsLock = 1 << 4,
    NumLock = 1 << 5,
    ScrollLock = 1 << 6,
    pub fn asU8(self: Modifier) u8 {
        return @intFromEnum(self);
    }
    pub fn set(self: Modifier, flags: u8) u8 {
        return flags | self.asU8();
    }
    pub fn check(self: Modifier, flags: u8) bool {
        return flags & self.asU8() != 0;
    }
    pub fn clear(self: Modifier, flags: u8) u8 {
        return flags & ~self.asU8();
    }
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

// We're not using these functions right now, but might need them if I wanna support other sets in
// the future, so I'm leaving them here for now.

const KeyboardSetType = enum {
    Set1,
    Set2,
    Set3,
};

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

fn getSet2KeyEvent(code: u8) KeyEvent {
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
/// Drain any stray bytes (scancodes or controller replies) that may be in the Data port
fn flushOutputBuffer() void {
    // discard any value in the output buffer until it's no longer full
    while (check(StatusFlag.OutputBufferFull)) {
        log.debug("flushing keyboard buffer", .{});
        // read the data port
        _ = Port.Data.read();
    }
}
