const std = @import("std");
const gdt = @import("../gdt.zig");
const idt = @import("../interrupts/idt.zig");
const pmm = @import("../memory/pmm.zig");
const paging = @import("../memory/paging.zig");
const vmm = @import("../memory/vmm.zig");
const heap_allocator = @import("../memory/allocator.zig");

const SegmentSelector = gdt.SegmentSelector;
const CpuContext = idt.InterruptFrame;
const VirtualMemoryManager = vmm.VirtualMemoryManager;
const Allocator = heap_allocator.Allocator;

const log = std.log.scoped(.process);

/// A single process (or the idle task) in a circular list.
pub const Process = struct {
    /// The buffer used by the VMM Allocator for this process
    vmm_buffer: []u8,
    /// The allocator used by the VMM for this process.
    vmm_allocator: heap_allocator.Allocator,
    /// The virtual memory manager for this process.
    vmm: VirtualMemoryManager,

    /// The process ID
    name: [name_max_len]u8 = [_]u8{0} ** name_max_len,
    pid: u64,
    state: State,
    context: *CpuContext,

    next: *Process = null, // non-optional ptr: we maintain a true circular list

    // maximum length of the process name
    const name_max_len = 64;

    const vmm_buffer_size: usize = 0x10000; // 64 KiB

    // On AMD64 the entire 48-bit canonical address space is split in two halves by bit 47:

    // Low half (PML4 indices 0–255): user‐space
    // High half (PML4 indices 256–511): kernel
    //
    // This means that the user‐space virtual address space range is:
    // 0x0000_0000_0000_0000  ...  0x0000_7FFF_FFFF_FFFF

    // We leave the first 4 KiB unmapped to catch NULL dereferences.
    const process_virt_base_start: usize = paging.PAGE_SIZE;
    const process_virt_base_end: usize = 0x0000_7FFF_FFFF_FFFF;
    // 256 KiB stack size + 1 guard page
    const process_stack_size: usize = 0x40000 + paging.PAGE_SIZE;

    pub fn init(self: *Process, name: []const u8, pid: u64, state: State, function: *const (fn (*anyopaque) void), arg: *anyopaque) void {
        const heap_phys = pmm.global_pmm.alloc(vmm_buffer_size);
        const heap_virt = paging.physToVirt(@intFromPtr(heap_phys.ptr));
        const heap = @as([*]u8, @ptrFromInt(heap_virt))[0..heap_phys.len];
        for (heap) |*byte| {
            byte.* = 0; // Initialize the heap memory to zero
        }

        const vmm_allocator = Allocator.initFixed(heap);
        const allocator_instance = vmm_allocator.allocator();
        const vmm_instance = VirtualMemoryManager.init(process_virt_base_start, allocator_instance);

        // The kernel lives entirely in the higher half (PML4 entries 256..511), and we want the kernel to exist in all
        // address spaces.
        //
        // So we copy over the kernel's PML4 entries to the process VMM's PML4.
        //
        // TODO: this has a subtle bug where if the kernel's PML4 entries change in one process,
        // this will not be reflected in the kernel VMM's PML4. So when switching processes, the
        // kernel could page fault.
        //
        // A solution would be to keep track of the "current" generation of the kernel PML4 entries.
        // Everytime the kernel PML4 is modified, the generation is incremented. Whenever a new
        // process is loaded, its kernel pml4 generation is checked against the current generation.
        // If the current generation is higher, we copy the process' kernel tables over so that the
        // page tables are synchronized.
        @memcpy(vmm_instance.pt_root[256..511], vmm.global_vmm.pt_root[256..511]);

        const context = allocator_instance.create(CpuContext) catch |err| {
            log.err("Failed to allocate CPU context: {}", .{err});
            @panic("Failed to initialize new process");
        };

        self.* = Process{
            .vmm_buffer = heap,
            .vmm_allocator = vmm_allocator,
            .vmm = vmm_instance,
            .pid = pid,
            .state = state,
            .context = context,
        };

        @memcpy(self.name[0..name_max_len], name[0..name_max_len]);

        self.initContext(function, arg);
    }

    fn initContext(self: *Process, function: *const (fn (*anyopaque) void), arg: *anyopaque) void {
        self.initStack();
        self.initCode(function, arg);
        self.context.rflags.@"if" = 1; // Enable interrupts
    }

    fn initCode(self: *Process, function: *const (fn (*anyopaque) void), arg: *anyopaque) void {
        self.context.cs = SegmentSelector.KernelCode;
        self.context.rip = @intFromPtr(function);
        self.context.rdi = @intFromPtr(arg);
    }

    fn initStack(self: *Process) void {
        self.context.ss = SegmentSelector.KernelData;

        const stack = @as([*]u8, @ptrFromInt(process_virt_base_end - process_stack_size))[0..process_stack_size];

        const stack_guard_page = stack[0..paging.PAGE_SIZE];

        const stack_bottom = stack[paging.PAGE_SIZE..];
        // don't map the bottom-most page of the stack to act as a guard page. So that when a stack
        // overflow occurs, it will cause a page fault.
        self.vmm.map(stack_guard_page, null, &.{.Disabled});
        self.vmm.map(stack_bottom, null, &.{ .User, .Write });

        const stack_top = @intFromPtr(stack_bottom.ptr) + stack_bottom.len;
        self.context.rsp = stack_top; // since stack grows downwards
        self.context.rbp = 0;
    }

    pub fn deinit(self: *Process) void {
        self.vmm.deinit();
        self.vmm_allocator.deinit();
        const vmm_buffer_phys = @as([*]u8, @ptrFromInt(paging.virtToPhys(@intFromPtr(self.vmm_buffer.ptr))))[0..self.vmm_buffer.len];
        pmm.global_pmm.free(vmm_buffer_phys);
    }
};

pub const State = enum {
    /// The process is in the queue and waiting to be scheduled.
    Ready,
    /// The process is currently running on the CPU.
    Running,
    /// The process has finished running and should not be scheduled. Its resources can also be
    /// cleaned up.
    Dead,
};
