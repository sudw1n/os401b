// TODO: build a virtual memory manager built around the paging system but one that isn't specific
// to x86_64. This tracks the pages that have been allocated along with their flags
const std = @import("std");
const limine = @import("limine");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");

const log = std.log.scoped(.vmm);

const PageTableEntryFlag = paging.PageTableEntryFlag;

pub var global_vmm: VirtualMemoryManager = undefined;

pub fn init(memory_map: *limine.MemoryMapResponse, executable_address_response: *limine.ExecutableAddressResponse) void {
    const pt_root = paging.PageTable.initZero();
    log.debug("PML4 allocated at address: {x:0>16}", .{@intFromPtr(pt_root)});
    const allocator = heap.allocator();
    const virt_base = paging.physToVirt(pmm.global_pmm.getFirstFreePage());
    global_vmm = VirtualMemoryManager.init(pt_root, virt_base, allocator);

    // map physical frames
    // TODO: maybe put all of the below stuff in kernel's main source file, since it's part of the kernel's
    // initialization?
    const entries = memory_map.getEntries();
    for (entries) |entry| {
        const base = entry.base;
        const length = entry.length;
        const virt_addr = paging.physToVirt(base);
        const flags: []const paging.PageTableEntryFlags = switch (entry.type) {
            .usable, .bootloader_reclaimable, .executable_and_modules => &.{ .Present, .Writable },
            .framebuffer, .acpi_reclaimable, .acpi_nvs => &.{ .Present, .Writable, .WriteThrough, .NoCache },
            else => {
                log.debug("Skipping {s} region: virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{ @tagName(entry.type), virt_addr, virt_addr + length, base });
                continue;
            },
        };
        log.info("Mapping {s} region: virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{ @tagName(entry.type), virt_addr, virt_addr + length, base });
        paging.mapRange(global_vmm.pt_root, virt_addr, base, length, flags);
    }

    mapOwn(executable_address_response);

    global_vmm.switchTo();
}

/// Manages the virtual address spaces of processes and the kernel.
///
/// There can be more than one instance of this manager. The kernel will have its own instance.
pub const VirtualMemoryManager = struct {
    /// Page table root for the virtual address space
    pt_root: *paging.PML4,
    /// Initial base address for the virtual address space
    virt_base: u64,
    /// A linked list of VM objects that have been allocated to that address space
    vm_objects: ?*VmObject,
    allocator: std.mem.Allocator,

    pub const Error = error{
        MisalignedRegion,
        OverlappingRegion,
    } || std.mem.Allocator.Error;

    pub fn init(pml4: *paging.PML4, virt_base: u64, allocator: std.mem.Allocator) VirtualMemoryManager {
        return VirtualMemoryManager{
            .pt_root = pml4,
            .virt_base = virt_base,
            .vm_objects = null,
            .allocator = allocator,
        };
    }

    // TODO: complete this. we should also deallocate all the VmObject nodes in the linked list
    pub fn deinit(self: *VirtualMemoryManager) void {
        // Free the page table root
        self.pt_root.deinit();
    }

    pub fn switchTo(self: *VirtualMemoryManager) void {
        // Switch to the page table root for this address space
        paging.switchToPML4(self.pt_root);
    }
};

const VmObject = struct {
    region: []u8,
    flags: u64,
    next: ?*VmObject,
};

/// Flags for VM objects, used to determine how the memory should be mapped.
pub const VmObjectFlag = enum(u64) {
    /// Disables the VM region
    Disabled = 1 << 0,
    /// Makes the VM region writable
    Write = 1 << 1,
    /// Makes the VM region executable
    Exec = 1 << 2,
    /// Makes the VM region userspace-accessible
    User = 1 << 3,
    /// Marks the VM region as Memory-Mapped I/O. Setting this flag also implies Reserved.
    ///
    /// This effectively disables caching as well as ensures every write is immediately and
    /// synchronously propagated to the backing store.
    ///
    /// If this bit is cleared, it indicates the object is working (anonymous) memory.
    Mmio = 1 << 4,
    /// Marks the VM region as reserved in the physical address space meaning it should remain
    /// reserved in the PMM.
    Reserved = 1 << 5,

    pub fn asInt(self: VmObjectFlag) u64 {
        return @intFromEnum(self);
    }

    pub fn check(self: VmObjectFlag, flags: u64) bool {
        return flags & self.asInt() != 0;
    }

    /// convert the given slice of VmObjectFlag to a single u64 value
    pub fn asRaw(slice: []const VmObjectFlag) u64 {
        var value: u64 = 0;
        for (slice) |flag| {
            value |= flag.asInt();
        }
        return value;
    }

    /// convert the VM object flags to x86_64 page table flags
    pub fn toX86(flags: u64) u64 {
        var value: u64 = 0;
        if (!VmObjectFlag.Disabled.check(flags)) {
            value |= PageTableEntryFlag.Present.asInt();
        }
        if (VmObjectFlag.Write.check(flags)) {
            value |= PageTableEntryFlag.Writable.asInt();
        }
        if (!VmObjectFlag.Exec.check(flags)) {
            value |= PageTableEntryFlag.NoExecute.asInt();
        }
        if (VmObjectFlag.User.check(flags)) {
            value |= PageTableEntryFlag.UserAccessible.asInt();
        }
        if (VmObjectFlag.Mmio.check(flags)) {
            value |= (PageTableEntryFlag.WriteThrough.asInt() | PageTableEntryFlag.NoCache.asInt() | PageTableEntryFlag.Reserved.asInt());
        }
        if (VmObjectFlag.Reserved.check(flags)) {
            value |= PageTableEntryFlag.Reserved.asInt();
        }
        return value;
    }

    pub fn format(value: VmObjectFlag, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}", .{@tagName(value)});
    }
};

extern const __kernel_start: u8;
extern const __kernel_end: u8;
extern const __limine_requests_start: u8;
extern const __limine_requests_end: u8;
extern const __kernel_code_start: u8;
extern const __kernel_code_end: u8;
extern const __kernel_rodata_start: u8;
extern const __kernel_rodata_end: u8;
extern const __kernel_data_start: u8;
extern const __kernel_data_end: u8;
extern const __kernel_bss_start: u8;
extern const __kernel_bss_end: u8;
// stack grows downward
extern const __kernel_stack_top: u8;
extern const __kernel_stack_bottom: u8;

// map own stack and code regions
fn mapOwn(executable_address_response: *limine.ExecutableAddressResponse) void {
    const vbase = executable_address_response.virtual_base;
    const pbase = executable_address_response.physical_base;

    // The regions of the kernel with appropriate permissions for page table setup
    const kernel_regions = &[_]struct {
        name: [:0]const u8,
        start: u64,
        end: u64,
        flags: []const paging.PageTableEntryFlags,
    }{
        // .limine_requests: R, read‑only, non-executable
        .{
            .name = "limine_requests",
            .start = @intFromPtr(&__limine_requests_start),
            .end = @intFromPtr(&__limine_requests_end),
            .flags = &.{ .Present, .NoExecute },
        },
        // .text: RX, read‑only, executable
        .{
            .name = "text",
            .start = @intFromPtr(&__kernel_code_start),
            .end = @intFromPtr(&__kernel_code_end),
            .flags = &.{.Present},
        },

        // .rodata: R‑only, non‑executable
        .{
            .name = "rodata",
            .start = @intFromPtr(&__kernel_rodata_start),
            .end = @intFromPtr(&__kernel_rodata_end),
            .flags = &.{ .Present, .NoExecute },
        },

        // .data: RW, non‑executable
        .{
            .name = "data",
            .start = @intFromPtr(&__kernel_data_start),
            .end = @intFromPtr(&__kernel_data_end),
            .flags = &.{ .Present, .Writable, .NoExecute },
        },

        // .bss: RW, non‑executable
        .{
            .name = "bss",
            .start = @intFromPtr(&__kernel_bss_start),
            .end = @intFromPtr(&__kernel_bss_end),
            .flags = &.{ .Present, .Writable, .NoExecute },
        },

        // stack: RW, non‑executable (grows down from top)
        .{
            .name = "stack",
            .start = @intFromPtr(&__kernel_stack_bottom),
            .end = @intFromPtr(&__kernel_stack_top),
            .flags = &.{ .Present, .Writable, .NoExecute },
        },
    };

    for (kernel_regions) |reg| {
        const virt = reg.start;
        const length = reg.end - reg.start;
        const offset = virt - vbase; // how far into the kernel base is this pointer
        const phys = pbase + offset; // location in RAM for that offset

        log.info("Mapping kernel {s} region virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{ reg.name, virt, virt + length, phys });

        paging.mapRange(global_vmm.pt_root, virt, phys, length, reg.flags);
    }
}
