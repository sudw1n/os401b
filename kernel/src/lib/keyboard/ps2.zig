const std = @import("std");
const cpu = @import("../cpu.zig");
const lapic = @import("../interrupts/lapic.zig");
const term = @import("../tty/terminal.zig");

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
    current_modifiers: u8 = Modifier.None.asU8(),

    const State = enum {
        /// The normal state, where we expect to receive a single byte
        /// After being in the prefix state and reading a byte, we also go back to this state.
        Normal,
        /// The prefix state, where the driver has encountered a prefix byte. While in this state,
        /// the next read is an extended scancode.
        Prefix,
    };

    const max_buffer_size = 256;

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
            log.debug("Prefix byte received, going to Prefix state", .{});
            self.current_state = .Prefix;
            return;
        }

        const maybe_event = self.getKeyEvent(code);
        if (maybe_event) |event| {
            // Only non‐modifier events should be enqueued into the buffer
            self.buffer[self.buf_position] = event;
            self.buf_position = (self.buf_position + 1) % max_buffer_size;
            if (event.type == .Make) displayKeyEvent(event);
        }
        if (self.current_state == .Prefix) {
            // if we were in the prefix state, we go back to the normal state
            self.current_state = .Normal;
        }
    }

    fn displayKeyEvent(event: KeyEvent) void {
        const c: ?u8 = blk: switch (event.code) {
            .Tab => {
                break :blk '\t';
            },
            .Enter => {
                break :blk '\n';
            },
            .Backspace => {
                break :blk '\x0E';
            },
            else => {
                const raw: u8 = @intFromEnum(event.code);
                if (raw < set1_ascii_map.len and set1_ascii_map[raw] != 0) {
                    const c = set1_ascii_map[raw];
                    if (Modifier.CapsLock.check(event.status_mask) or Modifier.Shift.check(event.status_mask)) {
                        break :blk std.ascii.toUpper(c);
                    }
                    break :blk c;
                }
                break :blk null;
            },
        };
        if (c) |char| {
            term.print("{c}", .{char}) catch @panic("failed to write character to terminal");
        }
    }

    fn getKeyEvent(self: *Ps2Driver, code: u8) ?KeyEvent {
        const is_break = (code & (1 << 7)) != 0;
        const index = code & ~@as(u8, (1 << 7)); // mask off the MSB
        const scancode = set1[index];
        const kind: ScanCodeType = if (is_break) .Break else .Make;

        const modifier = scancode.toModifier();

        if (modifier != Modifier.None) {
            // capslock is a toggle, so we need to handle it
            if (modifier == .CapsLock) {
                modifier.toggle(&self.current_modifiers);
            } else {
                if (kind == .Make) {
                    modifier.set(&self.current_modifiers);
                } else {
                    modifier.clear(&self.current_modifiers);
                }
            }
            // modifiers events are encoded in the status_mask field of each key event
            return null;
        }
        // if it's not a modifier, we return a KeyEvent
        return KeyEvent{
            .code = scancode,
            .type = kind,
            .status_mask = self.current_modifiers,
        };
    }
};

// TODO: add support for extended scancodes (0xE0 prefix)

// Build the full 256-entry scancode table at comptime:
const set1: [256]Scancode = blk: {
    var scancode_table: [256]Scancode = undefined;

    // default everything to Unknown
    for (&scancode_table) |*slot| slot.* = Scancode.Unknown;

    // fill in each of the "make-up" scancodes from Set 1
    // (we ignore the release bit 0x80 here; mask that out upstream)
    scancode_table[0x01] = Scancode.Escape;
    scancode_table[0x02] = Scancode.Digit1;
    scancode_table[0x03] = Scancode.Digit2;
    scancode_table[0x04] = Scancode.Digit3;
    scancode_table[0x05] = Scancode.Digit4;
    scancode_table[0x06] = Scancode.Digit5;
    scancode_table[0x07] = Scancode.Digit6;
    scancode_table[0x08] = Scancode.Digit7;
    scancode_table[0x09] = Scancode.Digit8;
    scancode_table[0x0A] = Scancode.Digit9;
    scancode_table[0x0B] = Scancode.Digit0;
    scancode_table[0x0C] = Scancode.Minus;
    scancode_table[0x0D] = Scancode.Equal;
    scancode_table[0x0E] = Scancode.Backspace;
    scancode_table[0x0F] = Scancode.Tab;

    scancode_table[0x10] = Scancode.Q;
    scancode_table[0x11] = Scancode.W;
    scancode_table[0x12] = Scancode.E;
    scancode_table[0x13] = Scancode.R;
    scancode_table[0x14] = Scancode.T;
    scancode_table[0x15] = Scancode.Y;
    scancode_table[0x16] = Scancode.U;
    scancode_table[0x17] = Scancode.I;
    scancode_table[0x18] = Scancode.O;
    scancode_table[0x19] = Scancode.P;
    scancode_table[0x1A] = Scancode.LBracket;
    scancode_table[0x1B] = Scancode.RBracket;
    scancode_table[0x1C] = Scancode.Enter;
    scancode_table[0x1D] = Scancode.LControl;

    scancode_table[0x1E] = Scancode.A;
    scancode_table[0x1F] = Scancode.S;
    scancode_table[0x20] = Scancode.D;
    scancode_table[0x21] = Scancode.F;
    scancode_table[0x22] = Scancode.G;
    scancode_table[0x23] = Scancode.H;
    scancode_table[0x24] = Scancode.J;
    scancode_table[0x25] = Scancode.K;
    scancode_table[0x26] = Scancode.L;
    scancode_table[0x27] = Scancode.Semicolon;
    scancode_table[0x28] = Scancode.Quote;
    scancode_table[0x29] = Scancode.Grave;

    scancode_table[0x2A] = Scancode.LShift;
    scancode_table[0x2B] = Scancode.Backslash;
    scancode_table[0x2C] = Scancode.Z;
    scancode_table[0x2D] = Scancode.X;
    scancode_table[0x2E] = Scancode.C;
    scancode_table[0x2F] = Scancode.V;
    scancode_table[0x30] = Scancode.B;
    scancode_table[0x31] = Scancode.N;
    scancode_table[0x32] = Scancode.M;
    scancode_table[0x33] = Scancode.Comma;
    scancode_table[0x34] = Scancode.Dot;
    scancode_table[0x35] = Scancode.Slash;
    scancode_table[0x36] = Scancode.RShift;

    scancode_table[0x37] = Scancode.KPadAsterisk;
    scancode_table[0x38] = Scancode.LAlt;
    scancode_table[0x39] = Scancode.Space;
    scancode_table[0x3A] = Scancode.CapsLock;

    scancode_table[0x3B] = Scancode.F1;
    scancode_table[0x3C] = Scancode.F2;
    scancode_table[0x3D] = Scancode.F3;
    scancode_table[0x3E] = Scancode.F4;
    scancode_table[0x3F] = Scancode.F5;
    scancode_table[0x40] = Scancode.F6;
    scancode_table[0x41] = Scancode.F7;
    scancode_table[0x42] = Scancode.F8;
    scancode_table[0x43] = Scancode.F9;
    scancode_table[0x44] = Scancode.F10;

    scancode_table[0x45] = Scancode.NumLock;
    scancode_table[0x46] = Scancode.ScrollLock;

    scancode_table[0x47] = Scancode.KPad7;
    scancode_table[0x48] = Scancode.KPad8;
    scancode_table[0x49] = Scancode.KPad9;
    scancode_table[0x4A] = Scancode.KPadMinus;
    scancode_table[0x4B] = Scancode.KPad4;
    scancode_table[0x4C] = Scancode.KPad5;
    scancode_table[0x4D] = Scancode.KPad6;
    scancode_table[0x4E] = Scancode.KPadPlus;
    scancode_table[0x4F] = Scancode.KPad1;
    scancode_table[0x50] = Scancode.KPad2;
    scancode_table[0x51] = Scancode.KPad3;
    scancode_table[0x52] = Scancode.KPad0;
    scancode_table[0x53] = Scancode.KPadDot;

    scancode_table[0x57] = Scancode.F11;
    scancode_table[0x58] = Scancode.F12;

    // everything else stays as Unknown
    break :blk scancode_table;
};

const set1_ascii_map: [Scancode.fields]u8 = blk: {
    var m: [Scancode.fields]u8 = undefined;

    // default everything to 0 ("not printable")
    for (&m) |*slot| slot.* = 0;

    m[@intFromEnum(Scancode.Digit0)] = '0';
    m[@intFromEnum(Scancode.Digit1)] = '1';
    m[@intFromEnum(Scancode.Digit2)] = '2';
    m[@intFromEnum(Scancode.Digit3)] = '3';
    m[@intFromEnum(Scancode.Digit4)] = '4';
    m[@intFromEnum(Scancode.Digit5)] = '5';
    m[@intFromEnum(Scancode.Digit6)] = '6';
    m[@intFromEnum(Scancode.Digit7)] = '7';
    m[@intFromEnum(Scancode.Digit8)] = '8';
    m[@intFromEnum(Scancode.Digit9)] = '9';

    m[@intFromEnum(Scancode.A)] = 'a';
    m[@intFromEnum(Scancode.B)] = 'b';
    m[@intFromEnum(Scancode.C)] = 'c';
    m[@intFromEnum(Scancode.D)] = 'd';
    m[@intFromEnum(Scancode.E)] = 'e';
    m[@intFromEnum(Scancode.F)] = 'f';
    m[@intFromEnum(Scancode.G)] = 'g';
    m[@intFromEnum(Scancode.H)] = 'h';
    m[@intFromEnum(Scancode.I)] = 'i';
    m[@intFromEnum(Scancode.J)] = 'j';
    m[@intFromEnum(Scancode.K)] = 'k';
    m[@intFromEnum(Scancode.L)] = 'l';
    m[@intFromEnum(Scancode.M)] = 'm';
    m[@intFromEnum(Scancode.N)] = 'n';
    m[@intFromEnum(Scancode.O)] = 'o';
    m[@intFromEnum(Scancode.P)] = 'p';
    m[@intFromEnum(Scancode.Q)] = 'q';
    m[@intFromEnum(Scancode.R)] = 'r';
    m[@intFromEnum(Scancode.S)] = 's';
    m[@intFromEnum(Scancode.T)] = 't';
    m[@intFromEnum(Scancode.U)] = 'u';
    m[@intFromEnum(Scancode.V)] = 'v';
    m[@intFromEnum(Scancode.W)] = 'w';
    m[@intFromEnum(Scancode.X)] = 'x';
    m[@intFromEnum(Scancode.Y)] = 'y';
    m[@intFromEnum(Scancode.Z)] = 'z';

    m[@intFromEnum(Scancode.Minus)] = '-';
    m[@intFromEnum(Scancode.Equal)] = '=';
    m[@intFromEnum(Scancode.LBracket)] = '[';
    m[@intFromEnum(Scancode.RBracket)] = ']';
    m[@intFromEnum(Scancode.Semicolon)] = ';';
    m[@intFromEnum(Scancode.Quote)] = '\'';
    m[@intFromEnum(Scancode.Grave)] = '`';
    m[@intFromEnum(Scancode.Backslash)] = '\\';
    m[@intFromEnum(Scancode.Comma)] = ',';
    m[@intFromEnum(Scancode.Dot)] = '.';
    m[@intFromEnum(Scancode.Slash)] = '/';
    m[@intFromEnum(Scancode.Space)] = ' ';

    // keypad
    m[@intFromEnum(Scancode.KPad0)] = '0';
    m[@intFromEnum(Scancode.KPad1)] = '1';
    m[@intFromEnum(Scancode.KPad2)] = '2';
    m[@intFromEnum(Scancode.KPad3)] = '3';
    m[@intFromEnum(Scancode.KPad4)] = '4';
    m[@intFromEnum(Scancode.KPad5)] = '5';
    m[@intFromEnum(Scancode.KPad6)] = '6';
    m[@intFromEnum(Scancode.KPad7)] = '7';
    m[@intFromEnum(Scancode.KPad8)] = '8';
    m[@intFromEnum(Scancode.KPad9)] = '9';

    m[@intFromEnum(Scancode.KPadAsterisk)] = '*';
    m[@intFromEnum(Scancode.KPadMinus)] = '-';
    m[@intFromEnum(Scancode.KPadPlus)] = '+';
    m[@intFromEnum(Scancode.KPadDot)] = '.';

    break :blk m;
};

pub const Scancode = enum(u8) {
    Unknown,

    // row 1
    Escape,
    Digit1,
    Digit2,
    Digit3,
    Digit4,
    Digit5,
    Digit6,
    Digit7,
    Digit8,
    Digit9,
    Digit0,
    Minus,
    Equal,
    Backspace,
    Tab,

    // row 2
    Q,
    W,
    E,
    R,
    T,
    Y,
    U,
    I,
    O,
    P,
    LBracket,
    RBracket,
    Enter,

    // row 3
    LControl,
    A,
    S,
    D,
    F,
    G,
    H,
    J,
    K,
    L,
    Semicolon,
    Quote,
    Grave,

    // row 4
    LShift,
    Backslash,
    Z,
    X,
    C,
    V,
    B,
    N,
    M,
    Comma,
    Dot,
    Slash,
    RShift,

    // row 5
    KPadAsterisk,
    LAlt,
    Space,
    CapsLock,

    // function keys
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,

    // keypad navigation
    NumLock,
    ScrollLock,
    KPad7,
    KPad8,
    KPad9,
    KPadMinus,
    KPad4,
    KPad5,
    KPad6,
    KPadPlus,
    KPad1,
    KPad2,
    KPad3,
    KPad0,
    KPadDot,

    pub const fields = @typeInfo(Scancode).@"enum".fields.len;

    /// Convert a scancode to a Modifier
    pub fn toModifier(self: Scancode) Modifier {
        return switch (self) {
            .LShift, .RShift => Modifier.Shift,
            .LControl => Modifier.Control,
            .LAlt => Modifier.Alt,
            .CapsLock => Modifier.CapsLock,
            else => Modifier.None,
        };
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
    code: Scancode,
    type: ScanCodeType,
    /// To keep track of the modifier keys when this event was generated.
    status_mask: u8 = Modifier.None.asU8(),
    pub fn format(value: KeyEvent, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        if (value.status_mask != 0) {
            try writer.print("[ ", .{});
            const modifiers_fields = @typeInfo(Modifier).@"enum".fields;
            inline for (modifiers_fields) |modifier_field| {
                const modifier: Modifier = @enumFromInt(modifier_field.value);
                if (modifier.check(value.status_mask)) {
                    try writer.print(" {s} ", .{modifier_field.name});
                }
            }
            try writer.print(" ] ", .{});
        }
        const kind = switch (value.type) {
            .Make => "MAKE",
            .Break => "BREAK",
        };
        try writer.print("{s}: {s}", .{ kind, @tagName(value.code) });
    }
};

const ScanCodeType = enum {
    Make,
    Break,
};

// TODO: implement all of the modifiers
const Modifier = enum(u8) {
    None = 0,
    Shift = 1 << 0,
    Control = 1 << 1,
    Alt = 1 << 2,
    Meta = 1 << 3,
    CapsLock = 1 << 4,
    pub fn asU8(self: Modifier) u8 {
        return @intFromEnum(self);
    }
    pub fn set(self: Modifier, flags: *u8) void {
        flags.* |= self.asU8();
    }
    pub fn toggle(self: Modifier, flags: *u8) void {
        flags.* ^= self.asU8();
    }
    pub fn check(self: Modifier, flags: u8) bool {
        return flags & self.asU8() != 0;
    }
    pub fn clear(self: Modifier, flags: *u8) void {
        flags.* &= ~self.asU8();
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
    Port.Data.writeWithAck(command);

    const param: u8 = switch (set) {
        .Set1 => 0x1,
        .Set2 => 0x2,
        .Set3 => 0x3,
    };
    Port.Data.writeWithAck(param);
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
    Port.Data.writeWithAck(command);

    // 0 -> get current set
    const param = 0x00;
    Port.Data.writeWithAck(param);

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
