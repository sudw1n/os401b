const cpu = @import("../cpu.zig");
const out = cpu.out;
const in = cpu.in;

const PitPorts = enum(u8) {
    Channel0 = 0x40,
    ModeCommand = 0x43,

    pub fn get(self: PitPorts) u8 {
        return @intFromEnum(self);
    }
};

const PIT_FREQUENCY: u32 = 1193182; // 1.193182 MHz
// reload register = (clock frequency)/(duration wanted in seconds)
/// Get the value of count to be given to the PIT.
///
/// frequency: how many times the clock should tick per second. For example, 1000 means the clock
/// will interrupt every 1ms.
pub fn getReloadValue(frequency: u32) u16 {
    // 1193182 / 1000 = 1193.182
    // 1193182 / 1000000 = 1.193182
    const reload_value: u32 = PIT_FREQUENCY / frequency;
    return @as(u16, @truncate(reload_value));
}

const PitMode = enum(u3) {
    OneShot = 0,
    Periodic = 2,
    pub fn get(self: PitMode) u3 {
        return @intFromEnum(self);
    }
};

const ConfigByte = packed struct(u8) {
    /// Select BCD (1) or binary (0) encoding
    encoding: u1,
    /// Selects the mode to use for this channel.
    mode: u3,
    /// Select the access mode for the channel.
    access_mode: u2,
    /// Select the channel we want to use.
    channel: u2,

    pub fn init(mode: PitMode) ConfigByte {
        return ConfigByte{
            // binary encoding
            .encoding = 0,
            .mode = mode.get(),
            // 0b11 means we send the low byte, then the high byte of the 16-bit register
            .access_mode = 0b11,
            // we always want channel 0
            .channel = 0,
        };
    }
};

pub fn setPitPeriodic(count: u16) void {
    const config_byte: ConfigByte = .init(PitMode.Periodic);
    out(
        PitPorts.ModeCommand.get(),
        @as(u8, @bitCast(config_byte)),
    );
    out(
        PitPorts.Channel0.get(),
        // low-byte
        @as(u8, @truncate(count)),
    );
    out(
        PitPorts.Channel0.get(),
        // high-byte
        @as(u8, @truncate(count >> 8)),
    );
}

const READBACK_CH0: u8 = 0b1101_0010;

/// Read the current count of the PIT.
pub fn readCurrentCount() u16 {
    // latch the count
    out(PitPorts.ModeCommand.get(), READBACK_CH0);

    // read low then high
    const lo = in(u8, PitPorts.Channel0.get());
    const hi = in(u8, PitPorts.Channel0.get());
    return (@as(u16, hi) << 8) | @as(u16, lo);
}
