const cpu = @import("../cpu.zig");
const out = cpu.out;
const in = cpu.in;

const Port = enum(u8) {
    Channel0 = 0x40,
    ModeCommand = 0x43,

    pub fn get(self: Port) u8 {
        return @intFromEnum(self);
    }
};

const FREQUENCY: u32 = 1193182; // 1.193182 MHz
// reload register = (clock frequency)/(duration wanted in seconds)
/// Get the value of count to be given to the PIT.
///
/// frequency: how many times the clock should tick per second. For example, 1000 means the clock
/// will interrupt every 1ms.
pub fn getReloadValue(frequency: u32) u16 {
    // 1193182 / 1000 = 1193.182
    // 1193182 / 1000000 = 1.193182
    const reload_value: u32 = FREQUENCY / frequency;
    return @as(u16, @truncate(reload_value));
}

const Mode = enum(u3) {
    OneShot = 0,
    Periodic = 2,
    pub fn get(self: Mode) u3 {
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

    pub fn init(mode: Mode) ConfigByte {
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

pub fn setPeriodic(count: u16) void {
    const config_byte: ConfigByte = .init(Mode.Periodic);
    out(
        Port.ModeCommand.get(),
        @as(u8, @bitCast(config_byte)),
    );
    out(
        Port.Channel0.get(),
        // low-byte
        @as(u8, @truncate(count)),
    );
    out(
        Port.Channel0.get(),
        // high-byte
        @as(u8, @truncate(count >> 8)),
    );
}

// The read back command is a special command sent to the mode/command register.
//
// Bits         Usage
// 7 and 6      Must be set for the read back command
// 5            Latch count flag (0 = latch count, 1 = don't latch count)
// 4            Latch status flag (0 = latch status, 1 = don't latch status)
// 3            Read back timer channel 2 (1 = yes, 0 = no)
// 2            Read back timer channel 1 (1 = yes, 0 = no)
// 1            Read back timer channel 0 (1 = yes, 0 = no)
// 0            Reserved (should be clear)
//
// Bits 1 to 3 of the read back command select which PIT channels are affected, and allow multiple
// channels to be selected at the same time.
//
// If bit 5 is clear, then any/all PIT channels selected with bits 1 to 3 will have their current
// count copied into their latch register (similar to sending the latch command, except it works for
// multiple channels with one command).
//
// If bit 4 is clear, then for any/all PIT channels selected with bits 1 to 3, the next read of the
// corresponding data port will return a status byte.
const READBACK_CH0: u8 = 0b1101_0010;

/// Read the current count of the PIT.
pub fn readCurrentCount() u16 {
    // latch the count
    out(Port.ModeCommand.get(), READBACK_CH0);

    // read low then high
    const lo = in(u8, Port.Channel0.get());
    const hi = in(u8, Port.Channel0.get());
    return (@as(u16, hi) << 8) | @as(u16, lo);
}
