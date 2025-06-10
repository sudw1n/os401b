// TODO: build a virtual memory manager built around the paging system but one that isn't specific
// to x86_64. This tracks the pages that have been allocated along with their flags
const paging = @import("paging.zig");

const PageTableEntryFlags = paging.PageTableEntryFlags;

pub var global_vmm: VirtualMemoryManager = undefined;

pub fn init() void {
    global_vmm = VirtualMemoryManager.init();
}

pub const VirtualMemoryManager = struct {
    pub fn init() VirtualMemoryManager {
        return VirtualMemoryManager{};
    }
};

const VmObject = struct {
    ptr: []u8,
    flags: u64,
    next: ?*VmObject,

    /// convert the VM object flags to x86_64 page table flags
    fn convertVmFlags(self: *VmObject) u64 {
        var value: u64 = 0;
        const flags = self.flags;
        if (VmObjectFlags.Write.check(flags)) {
            value |= PageTableEntryFlags.Writable.asInt();
        }
        if (VmObjectFlags.User.check(flags)) {
            value |= PageTableEntryFlags.UserAccessible.asInt();
        }
        if (!VmObjectFlags.Exec.check(flags)) {
            value |= PageTableEntryFlags.NoExecute.asInt();
        }
        return value;
    }
};

const VmObjectFlags = enum(u64) {
    None = 0,
    Write = 1 << 0,
    Exec = 1 << 1,
    User = 1 << 2,
    pub fn asInt(self: VmObjectFlags) u64 {
        return @intFromEnum(self);
    }
    pub fn check(self: VmObjectFlags, flags: u64) bool {
        return flags & self.asInt() != 0;
    }
};
