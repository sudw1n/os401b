// TODO: setup a GDT yourself and remove the limine bootloader defaults
/// Segment selectors for the GDT
pub const SegmentSelector = enum(u16) {
    NullDescriptor = 0x00,
    // these values are so because the limine bootloader sets up a GDT for us.
    // see: https://github.com/limine-bootloader/limine/blob/v8.x/PROTOCOL.md#x86-64-1
    KernelCode = 0x28,
    KernelData = 0x30,
};

/// Descriptor Privilege Level
pub const Dpl = enum(u2) {
    Kernel = 0b00,
    User = 0b11,
};
