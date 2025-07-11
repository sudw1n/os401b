//! Programmable Interval Timer (PIT) interface

const std = @import("std");
const cpu = @import("../cpu.zig");
const out = cpu.out;
const in = cpu.in;

pub const TICKS_PER_SEC: u32 = 1000; // 1 ms tick
pub const frequency: u32 = 1193182; // 1.193182 MHz

pub fn init() void {
    const reload = reloadForHz(TICKS_PER_SEC);
    setPeriodic(reload);
}

/// Return the initial count needed to generate interrupts at the given rate.
///
/// hz: Desired interrupt frequency, in hertz (i.e. how many interrupts per second).
pub fn reloadForHz(hz: u32) u16 {
    if (hz == 0) @panic("reloadForHz: frequency cannot be zero");
    const raw: u32 = std.math.divCeil(u32, frequency, hz) catch @panic("reloadForHz: division error");
    if (raw > std.math.maxInt(u16)) {
        @panic("reloadForHz: resulting count too large for 16 bits");
    }
    return @truncate(raw);
}

/// Return the initial count needed to generate interrupts at the given rate.
///
/// ms: Desired duration in milliseconds
pub fn reloadForMs(ms: u32) u16 {
    // The frequency tells us how many ticks are in 1 second.
    // Now, desired delay in seconds: T = ms / 1000
    // So to get total ticks, we multiply how many seconds there are (T) by how many ticks there are
    // in a second (frequency).
    // Ticks needed = frequency * T = frequency * ms / 1000

    // widen to 64-bit
    const numerator: u64 = std.math.mulWide(u32, frequency, ms);
    // divide with rounding up
    const raw: u64 = std.math.divCeil(u64, numerator, 1_000) catch @panic("reloadForMs: bad divisor");
    // guard 16-bit limit
    if (raw > @as(u64, 0xFFFF)) {
        @panic("reloadForMs overflow: ms too large");
    }
    // safe to truncate
    return @truncate(raw);
}

/// How many milliseconds correspond to the given number of ticks?
pub fn ticksToMs(ticks: u32) u32 {
    // See the comment inside reloadForMs() to understand how this formula has been derived.
    // This is basically just the inverse of the formula used there.
    return std.math.divCeil(u32, (ticks * 1000), frequency) catch @panic("ticksToMs: division error");
}

/// Configure the PIT in periodic mode with the given count
pub fn setPeriodic(count: u16) void {
    const config_byte: ConfigByte = .init(Mode.Periodic);
    out(
        u8,
        Port.ModeCommand.get(),
        @as(u8, @bitCast(config_byte)),
    );
    out(
        u8,
        Port.Channel0.get(),
        // low-byte
        @as(u8, @truncate(count)),
    );
    out(
        u8,
        Port.Channel0.get(),
        // high-byte
        @as(u8, @truncate(count >> 8)),
    );
}

/// Configure the PIT in one-shot mode with the given count
pub fn setOneShot(count: u16) void {
    const config_byte: ConfigByte = .init(Mode.OneShot);
    out(
        u8,
        Port.ModeCommand.get(),
        @as(u8, @bitCast(config_byte)),
    );
    out(
        u8,
        Port.Channel0.get(),
        // low-byte
        @as(u8, @truncate(count)),
    );
    out(
        u8,
        Port.Channel0.get(),
        // high-byte
        @as(u8, @truncate(count >> 8)),
    );
}

/// Read the current count of the PIT.
pub fn readCurrentCount() u16 {

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
    const READBACK_CH0 = 0b1101_0010;
    // latch the count
    out(u8, Port.ModeCommand.get(), READBACK_CH0);

    // read low then high
    const lo = in(u8, Port.Channel0.get());
    const hi = in(u8, Port.Channel0.get());
    return (@as(u16, hi) << 8) | @as(u16, lo);
}

pub fn sleep(ms: u32) void {
    // get the maximum ms we can wait for in a single cycle
    const max_ms: u32 = (@as(u32, 0xFFFF) * 1_000) / frequency;
    var remaining_duration: u32 = ms;

    // loop until we've covered the full duration
    while (remaining_duration > 0) {
        const chunk_ms = if (remaining_duration > max_ms) max_ms else remaining_duration;

        // load the PIT and wait for its counter to underflow
        const count = reloadForMs(chunk_ms);
        setOneShot(count);
        while (readCurrentCount() != 0) {}

        remaining_duration -= chunk_ms;
    }
}

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

/// I/O Ports for the PIT
const Port = enum(u8) {
    Channel0 = 0x40,
    ModeCommand = 0x43,

    pub fn get(self: Port) u8 {
        return @intFromEnum(self);
    }
};

const Mode = enum(u3) {
    OneShot = 0,
    Periodic = 2,
    pub fn get(self: Mode) u3 {
        return @intFromEnum(self);
    }
};
