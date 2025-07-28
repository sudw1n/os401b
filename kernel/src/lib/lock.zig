pub const SpinLock = struct {
    locked: bool = false,

    pub fn init() SpinLock {
        return SpinLock{};
    }

    pub fn acquire(self: *SpinLock) void {
        while (self.locked) {
            // Busy-wait until the lock is available
            asm volatile ("pause");
        }
        self.locked = true;
    }

    pub fn release(self: *SpinLock) void {
        self.locked = false;
    }
};
