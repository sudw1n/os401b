//! GDT Setup:
//! - Selector 0x00: null
//! - Selector 0x08: kernel code (64-bit, ring 0)
//! - Selector 0x10: kernel data (64-bit)
//! - Selector 0x18: user code (64-bit, ring 3)
//! - Selector 0x20: user data (64-bit)

const std = @import("std");
const cpu = @import("cpu.zig");

const log = std.log.scoped(.gdt);

const SystemTableRegister = cpu.SystemTableRegister;

/// Descriptor Privilege Level
pub const Dpl = enum(u2) {
    Kernel = 0b00,
    User = 0b11,
};

/// Segment selectors (offsets) for the GDT
pub const SegmentSelector = enum(u16) {
    NullDescriptor = 0x00,
    // 64-bit, ring 0
    KernelCode = 0x08,
    // 64-bit
    KernelData = 0x10,
    // 64-bit, ring 3
    UserCode = 0x18,
    // 64-bit
    UserData = 0x20,
};

/// Part of the GDT entry that describes the access rights of the segment
pub const AccessBits = packed struct {
    /// Tells to the CPU that the descriptor has been accessed in some way. This is set by the CPU.
    accessed: u1,
    /// For data selectors, allows writing to this region; region read-only is cleared.
    ///
    /// For code selectors, allows for read-only access to code for accessing constants stored near
    /// instructions. Otherwise, code can't be read as data, only for instruction fetches.
    write_read: u1,
    /// For data selectors, causes the limit to grow downwards, instead of up. useful for stack
    /// selectors.
    ///
    /// For code selectors, allow user code to run with kernel under certain conditions. Best left
    /// cleared.
    expand_down_conforming: u1,
    /// Set for code descriptors, cleared for data descriptors.
    executable: u1,
    /// If set, indicates a code or data descriptor.
    /// If cleared, indicates a system descriptor i.e. TSS, IDT (not valid in GDT) or gate-type
    /// descriptor (unused in long mode).
    descriptor: u1,
    /// Code ring that's allowed to use this descriptor.
    dpl: Dpl,
    /// If not set, descriptor is ignored.
    present: u1,

    pub fn init(executable: bool, dpl: Dpl) AccessBits {
        return AccessBits{
            .accessed = 1,
            .write_read = 1,
            .expand_down_conforming = 0,
            .executable = @intFromBool(executable),
            .descriptor = 1,
            .dpl = dpl,
            .present = 1,
        };
    }
};

/// Part of the GDT entry that describes the flags of the segment
pub const FlagBits = packed struct {
    /// For use with hardware task switching. Can be left zero.
    available: u1,
    /// Set if descriptor is for long mode
    long_mode: u1,
    /// Set if descriptor is for 32-bit mode, otherwise 16-bit
    misc: u1,
    /// If set, limit is interpreted as 0x1000 sized chunks, otherwise bytes.
    granularity: u1,

    pub fn initLongMode() FlagBits {
        return FlagBits{
            .available = 0,
            .long_mode = 1,
            .misc = 0,
            .granularity = 0,
        };
    }
};

/// Descriptor for each GDT entry
pub const GdtEntry = packed struct {
    /// Lower 16-bits of limit address.
    /// Described size of the segment in bytes.
    limit_low: u16,
    /// Lower 24-bits of base address.
    /// Starting address of the segment.
    base_low: u24,

    /// See `AccessBits`
    access: AccessBits,

    /// Upper 4 bits of limit address.
    limit_high: u4,

    /// See `FlagBits`
    flags: FlagBits,

    /// Upper 8 bits of base address.
    base_high: u8,

    pub fn init(base: u32, limit: u20, access: AccessBits, flags: FlagBits) GdtEntry {
        return GdtEntry{
            .limit_low = @truncate(limit),
            .base_low = @truncate(base),
            .access = access,
            .limit_high = @truncate(limit >> 16),
            .flags = flags,
            .base_high = @truncate(base >> 24),
        };
    }
};

// everything 0 for null descriptor
const null_access = AccessBits{
    .accessed = 0,
    .write_read = 0,
    .expand_down_conforming = 0,
    .executable = 0,
    .descriptor = 0,
    .dpl = Dpl.Kernel,
    .present = 0,
};
const null_flags = FlagBits{
    .available = 0,
    .long_mode = 0,
    .misc = 0,
    .granularity = 0,
};

const kernel_code_access = AccessBits.init(true, Dpl.Kernel);
const kernel_data_access = AccessBits.init(false, Dpl.Kernel);
const user_code_access = AccessBits.init(true, Dpl.User);
const user_data_access = AccessBits.init(false, Dpl.User);
const long_mode_flags = FlagBits.initLongMode();

// number of entries in the GDT is the number of segment selectors we have defined
const NUM_ENTRIES = @typeInfo(SegmentSelector).@"enum".fields.len;
var gdt_entries: [NUM_ENTRIES]GdtEntry = undefined;

pub fn init() void {
    log.info("Setting up GDT", .{});
    // base and limit irrelevant for long mode
    gdt_entries[0] = .init(0, 0, null_access, null_flags);
    gdt_entries[1] = .init(0, 0xfffff, kernel_code_access, long_mode_flags);
    gdt_entries[2] = .init(0, 0xfffff, kernel_data_access, long_mode_flags);
    gdt_entries[3] = .init(0, 0xfffff, user_code_access, long_mode_flags);
    gdt_entries[4] = .init(0, 0xfffff, user_data_access, long_mode_flags);

    const gdtr = SystemTableRegister{
        .base = @intFromPtr(&gdt_entries),
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
    };

    log.info("Loading GDTR", .{});
    cpu.lgdt(gdtr);

    log.info("Flushing GDT", .{});
    asm volatile (
        \\call flushGdt
    );
    log.info("GDT setup complete", .{});
}

export fn flushGdt() callconv(.Naked) void {
    // reload segment registers
    asm volatile (
        \\mov %[kernel_data], %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        :
        : [kernel_data] "i" (SegmentSelector.KernelData),
    );
    // To reload %cs we'll need an address to jump to, so we'll use the saved address on the stack.
    // We need to place the selector we want to load into %cs onto the stack before the return
    // address, so we'll briefly store it in %rdi, push our code selector then push the return
    // address back on the stack.
    asm volatile (
    // save the return address
        \\pop %%rdi
        // make sure the code segment is at top of stack
        \\push %[kernel_code]
        \\push %%rdi
        // far return
        \\lretq
        :
        : [kernel_code] "i" (SegmentSelector.KernelCode),
    );
}
