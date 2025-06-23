// TODO: build a virtual memory manager built around the paging system but one that isn't specific
// to x86_64. This tracks the pages that have been allocated along with their flags
const std = @import("std");
const limine = @import("limine");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");

const log = std.log.scoped(.vmm);

const PageTableEntryFlag = paging.PageTableEntryFlags;

pub var global_vmm: VirtualMemoryManager = undefined;

pub fn init(allocator: std.mem.Allocator, memory_map: *limine.MemoryMapResponse, executable_address_response: *limine.ExecutableAddressResponse) void {
    global_vmm = VirtualMemoryManager.init(allocator);

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
}

/// Manages the virtual address spaces of processes and the kernel.
pub const VirtualMemoryManager = struct {
    /// Page table root for the virtual address space
    pt_root: *paging.PML4,
    /// A linked list of VM objects that have been allocated
    vm_objects: ?*VmObject,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VirtualMemoryManager {
        const pt_root = paging.PageTable.initZero();
        log.debug("PML4 allocated at address: {x:0>16}", .{@intFromPtr(pt_root)});
        return VirtualMemoryManager{
            .pt_root = pt_root,
            .vm_objects = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VirtualMemoryManager) void {
        // Free the page table root
        self.pt_root.deinit();
    }
};

const VmObject = struct {
    ptr: []u8,
    flags: u64,
    next: ?*VmObject,
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
