const std = @import("std");
const gdt = @import("../gdt.zig");
const idt = @import("../interrupts/idt.zig");
const pmm = @import("../memory/pmm.zig");
const paging = @import("../memory/paging.zig");
const vmm_lib = @import("../memory/vmm.zig");
const heap_allocator = @import("../memory/allocator.zig");
const scheduler = @import("scheduler.zig");
const pit = @import("../timers/pit.zig");

const SegmentSelector = gdt.SegmentSelector;
const CpuContext = idt.InterruptFrame;
const VirtualMemoryManager = vmm_lib.VirtualMemoryManager;
const Allocator = heap_allocator.Allocator;

const log = std.log.scoped(.process);

// Type to represent the entry point of a thread function.
pub const ThreadFunction = *const fn (*anyopaque) callconv(.{ .x86_64_sysv = .{} }) void;

// Maximum length of process/thread names.
pub const NAME_MAX_LEN = 64;

const VMM_BUFFER_SIZE: usize = 0x10000; // 64 KiB

const VIRT_BASE_START: usize = 0x00400000;
const VIRT_BASE_END: usize = 0x0000_7FFF_FFFF_F000;
// 64 KiB stack size
const STACK_SIZE: usize = 0x10000;

pub const Thread = struct {
    parent: *Process,
    name: [NAME_MAX_LEN]u8,
    tid: u64,
    state: State,
    stack: []u8,
    stack_guard_page: []u8,
    context: CpuContext,
    wake_time: u64,

    next: ?*Thread = null,

    pub fn init(self: *Thread, parent: *Process, name: []const u8, tid: u64, state: State) void {
        self.* = Thread{
            .parent = parent,
            .name = [_]u8{0} ** NAME_MAX_LEN,
            .tid = tid,
            .state = state,
            .stack = undefined,
            .stack_guard_page = undefined,
            .context = undefined, // Will be initialized later by initContext
        };

        const len = @min(NAME_MAX_LEN, name.len);
        @memcpy(self.name[0..len], name[0..len]);
    }

    pub fn initContext(self: *Thread, function: ThreadFunction, arg: *anyopaque) void {
        log.debug("Initializing thread context for {s} (TID: {d})", .{ self.name, self.tid });
        self.initStack();
        self.initCode(function, arg);
        self.context.rflags.@"if" = true; // Enable interrupts
    }

    pub fn deinit(self: *Thread) void {
        // Clear the thread's stack
        self.parent.vmm.free(self.stack_guard_page);
        self.parent.vmm.free(self.stack);
    }

    pub fn sleep(self: *Thread, duration_ms: u64) void {
        log.info("Thread {s} (TID: {d}) is going to sleep for {d} ms", .{ self.name, self.tid, duration_ms });
        self.state = State.Sleeping;
        self.wake_time = pit.getUptimeMs() + duration_ms;
        scheduler.yield();
    }

    // will call the thread's entry point and then exit the thread
    fn threadExecutionWrapper(entry_fn: ThreadFunction, arg: *anyopaque) callconv(.{ .x86_64_sysv = .{} }) void {
        entry_fn(arg);
        const g = scheduler.global_scheduler orelse {
            log.err("Global scheduler is not initialized, cannot exit thread", .{});
            @panic("Global scheduler is not initialized");
        };
        g.threadExit();
    }

    fn initCode(self: *Thread, function: ThreadFunction, arg: *anyopaque) void {
        self.context.cs = SegmentSelector.KernelCode.get(u64);
        self.context.rip = @intFromPtr(&threadExecutionWrapper);
        self.context.rdi = @intFromPtr(function);
        self.context.rsi = @intFromPtr(arg);
    }

    fn initStack(self: *Thread) void {
        self.context.ss = SegmentSelector.KernelData.get(u64);

        const parent = self.parent;

        self.stack = parent.vmm.allocEnd(STACK_SIZE, &.{
            .Write,
        }, null) catch |err| {
            log.err("Failed to allocate stack for thread: {}", .{err});
            @panic("Failed to allocate stack for thread");
        };
        self.stack_guard_page = parent.vmm.allocEnd(0x1000, &.{.Disabled}, null) catch |err| {
            log.err("Failed to allocate stack guard page for thread: {}", .{err});
            @panic("Failed to allocate stack guard page for thread");
        };

        const stack_top = @intFromPtr(self.stack.ptr + self.stack.len);
        self.context.rsp = stack_top; // since stack grows downwards
        self.context.rbp = 0;
    }
};

/// A single process (or the idle task)
pub const Process = struct {
    /// The buffer used by the VMM Allocator for this process
    vmm_buffer: []u8,
    /// The allocator used by the VMM for this process.
    vmm_allocator: heap_allocator.Allocator,
    /// The virtual memory manager for this process.
    vmm: VirtualMemoryManager,

    allocator: std.mem.Allocator,

    /// The process ID
    name: [NAME_MAX_LEN]u8,
    pid: u64,

    // used to assign unique TIDs to threads
    next_tid: u64 = 0,

    threads: ?*Thread = null,

    // On AMD64 the entire 48-bit canonical address space is split in two halves by bit 47:

    // Low half (PML4 indices 0–255): user‐space
    // High half (PML4 indices 256–511): kernel
    //
    // This means that the user‐space virtual address space range is:
    // 0x0000_0000_0000_0000  ...  0x0000_7FFF_FFFF_FFFF

    pub fn init(self: *Process, name: []const u8, pid: u64) void {
        log.info("Initializing process {s} (PID: {d})", .{ name, pid });
        const heap_phys = pmm.global_pmm.alloc(VMM_BUFFER_SIZE);
        const heap_virt = paging.physToVirt(@intFromPtr(heap_phys.ptr));
        const heap = @as([*]u8, @ptrFromInt(heap_virt))[0..heap_phys.len];
        @memset(heap, 0); // Initialize the heap memory to zero

        var vmm_allocator = Allocator.initFixed(heap);
        const allocator_instance = vmm_allocator.allocator();
        const vmm_instance = VirtualMemoryManager.init(VIRT_BASE_START, VIRT_BASE_END, allocator_instance);

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
        log.debug("Copying kernel PML4 entries to process VMM PML4", .{});
        @memcpy(vmm_instance.pt_root.entries[256..511], vmm_lib.global_vmm.pt_root.entries[256..511]);

        self.* = Process{
            .name = [_]u8{0} ** NAME_MAX_LEN,
            .vmm_buffer = heap,
            .vmm_allocator = vmm_allocator,
            .vmm = vmm_instance,
            .allocator = heap_allocator.allocator(),
            .pid = pid,
        };

        const len = @min(NAME_MAX_LEN, name.len);
        @memcpy(self.name[0..len], name[0..len]);
        log.info("Process {s} (PID: {d}) initialized with VMM buffer at {x:0>16}:{x}", .{
            self.name,
            self.pid,
            @intFromPtr(self.vmm_buffer.ptr),
            self.vmm_buffer.len,
        });
    }

    pub fn addThread(self: *Process, name: []const u8, function: ThreadFunction, arg: *anyopaque) *Thread {
        log.info("Adding thread {s} to process {s} (PID: {d})", .{ name, self.name, self.pid });
        const allocator = self.allocator;

        // Allocate a new thread
        const thread = allocator.create(Thread) catch |err| {
            log.err("Failed to allocate thread for process {s} (PID: {d}): {}", .{
                self.name,
                self.pid,
                err,
            });
            @panic("Thread allocation failed");
        };

        const tid = blk: {
            const tid = self.next_tid;
            self.next_tid += 1;
            break :blk tid;
        };

        thread.init(self, name, tid, State.Ready);
        thread.initContext(function, arg);

        log.info("Adding thread {s} (TID: {d}) to process {s} (PID: {d})", .{
            name,
            tid,
            self.name,
            self.pid,
        });

        // Insert thread into the singly-linked list
        // NOTE: thread.next is null by default
        if (self.threads == null) {
            self.threads = thread;
        } else {
            var current = self.threads.?;
            while (current.next) |next| {
                current = next;
            }
            current.next = thread; // append to the end of the list
        }

        return thread;
    }

    // Remove the thread from the process' list of threads
    pub fn removeThread(self: *Process, thread: *Thread) void {
        // TODO: move the safety checks to run only in debug mode

        // Ensure the thread is not running before removing it
        if (thread.state == .Running) {
            log.err("Cannot remove a running thread: {s} (TID: {d})", .{ thread.name, thread.tid });
            @panic("Attempt to remove a running thread");
        }

        if (thread.parent != self) {
            log.err("Thread {s} (TID: {d}) does not belong to process {s} (PID: {d})", .{
                thread.name,
                thread.tid,
                self.name,
                self.pid,
            });
            @panic("Attempt to remove a thread that does not belong to the given process");
        }

        log.info("Removing thread {s} (TID: {d}) from process {s} (PID: {d})", .{
            thread.name,
            thread.tid,
            self.name,
            self.pid,
        });

        var found = false;

        // nothing to do if the list is empty
        const first = self.threads orelse {
            log.err("No threads to remove in process {s} (PID: {d})", .{
                self.name,
                self.pid,
            });
            @panic("Attempt to remove a thread from an empty process");
        };

        if (first == thread) {
            found = true; // We found the thread to remove
            // If the thread to remove is the first one, we need to update the head of the list
            self.threads = thread.next; // Update the head to the next thread
        } else {
            var current = first;
            while (current.next) |next| {
                if (next == thread) {
                    // Found the thread to remove, update the next pointer
                    current.next = next.next;
                    found = true; // We found the thread to remove
                    break; // Exit the loop after removing the thread
                }
                current = next; // Move to the next thread
            }
        }

        if (!found) {
            log.err("Thread {s} (TID: {d}) not found in process {s} (PID: {d})", .{
                thread.name,
                thread.tid,
                self.name,
                self.pid,
            });
            @panic("Attempt to remove a non-existent thread");
        }

        // Deinitialize the thread
        thread.deinit();

        const allocator = self.allocator;
        allocator.destroy(thread);

        // if removing the last thread results in the process having no threads, then we
        // deinitialize the process as well
        if (self.threads == null) {
            log.info("Process {s} (PID: {d}) has no more threads, deinitializing process", .{
                self.name,
                self.pid,
            });
            self.deinit();
        }
    }

    pub fn deinit(self: *Process) void {
        log.info("Deinitializing process {s} (PID: {d})", .{ self.name, self.pid });
        log.debug("Process deinit: vmm\n{}", .{self.vmm});
        self.vmm.deinit();
        self.vmm_allocator.deinit();
        // Clear the VMM buffer
        log.debug("Process deinit: vmm buffer@{x:0>16}:{x}", .{ @intFromPtr(self.vmm_buffer.ptr), self.vmm_buffer.len });
        @memset(self.vmm_buffer, 0); // Clear the VMM buffer
        // Free the physical frame used for the VMM buffer
        const vmm_buffer_phys = @as([*]u8, @ptrFromInt(paging.virtToPhys(@intFromPtr(self.vmm_buffer.ptr))))[0..self.vmm_buffer.len];
        pmm.global_pmm.free(vmm_buffer_phys);
    }
};

pub const State = enum {
    /// The thread is in the queue and waiting to be scheduled.
    Ready,
    /// The thread is currently running on the CPU.
    Running,
    /// The thread has finished running and should not be scheduled. Its resources can also be
    /// cleaned up.
    Dead,
    /// The thread is currently sleeping and will be woken up after a certain time.
    Sleeping,
};
