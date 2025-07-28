const std = @import("std");
const registers = @import("registers.zig");

const Rflags = registers.Rflags;
const AtomicBool = std.atomic.Value(bool);

pub const SpinLock = struct {
    locked: AtomicBool,

    pub fn init() SpinLock {
        return SpinLock{ .locked = AtomicBool.init(false) };
    }

    pub fn acquire(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(
            false, // expecting unlocked
            true, // want to set locked
            .acquire, // on success: act like an Acquire fence
            .acquire, // on failure: fresh-load with Acquire semantics
        ) != null) {
            std.atomic.spinLoopHint();
        }
    }

    /// Acquire lock and disable interrupts,
    /// returning the old RFLAGS so you can restore later.
    pub fn acquireFlagsSave(self: *SpinLock) Rflags {
        const flags = Rflags.get(Rflags);
        asm volatile ("cli");
        self.acquire();
        return flags;
    }

    pub fn release(self: *SpinLock) void {
        self.locked.store(false, .release);
    }

    /// Release lock and restore RFLAG
    pub fn releaseFlagsRestore(self: *SpinLock, flags: Rflags) void {
        self.release();
        Rflags.set(Rflags, flags);
    }
};
