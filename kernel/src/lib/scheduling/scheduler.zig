const std = @import("std");
const idt = @import("../interrupts/idt.zig");
const vmm = @import("../memory/vmm.zig");
const vmm_heap = @import("../memory/vmm_heap.zig");
const gdt = @import("../gdt.zig");

const VirtualMemoryManager = vmm.VirtualMemoryManager;
const SegmentSelector = gdt.SegmentSelector;

pub const CpuContext = idt.InterruptFrame;

pub const PROCESS_NAME_MAX_LEN = 64;

pub var global_scheduler: *Scheduler = undefined;

pub fn init() !void {
    // Initialize the scheduler, set up the first process, etc.
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    // Our scheduler, keeps exactly one circular list of `Process`es, with at least the idle process in
    // it at all times.
    /// entry point into the list (e.g. idle)
    first: *Process,
    /// the currently running process
    current: *Process,

    var next_pid: u64 = 0; // used to assign unique PIDs to processes

    pub fn init(allocator: std.mem.Allocator, p: *Process) Scheduler {
        // make the list point at itself
        p.next = p; // circular list
        p.state = .Running;
        return Scheduler{
            .first = p,
            .current = p,
        };
    }

    pub fn createProcess(self: *Scheduler, name: [PROCESS_NAME_MAX_LEN:0]u8, function: *const (fn (*anyopaque) void), arg: *anyopaque) !*Process {
        // allocate a new process
        const pml4 = try vmm.createPML4(self.allocator);
        const p = try self.allocator.create(Process);
        p.vmm = VirtualMemoryManager.init(pml4: *paging.PML4, virt_base: u64, allocator: std.mem.Allocator)
        @memcpy(p.name, name);
        p.pid = blk: {
            const pid = self.next_pid;
            self.next_pid += 1;
            break :blk pid;
        };
        p.state = .Ready;
        p.context.ss = SegmentSelector.KernelData;
        p.
            return p;
    }

    /// Heart of the scheduler: save the old context, pick the next READY,
    /// clean out any DEAD processes as we go, and return its context.
    pub fn schedule(self: *Scheduler, context: *CpuContext) *CpuContext {
        // save old context and mark ready
        const old = self.current;
        old.context = context;
        old.state = .Ready;

        // find a non-dead process to run
        var candidate = old.next;
        while (candidate.state == .Dead) : (candidate = candidate.next) {
            self.deleteProcess(candidate);
        }

        // mark the non-dead process as running
        candidate.state = .Running;
        self.current = candidate;
        return candidate.context;
    }

    /// Insert `p` right after `first` in the ring.
    fn addProcess(self: *Scheduler, p: *Process) void {
        p.next = self.first.next;
        self.first.next = p;
    }
    /// Remove `p` from the ring. Must not be the only element.
    pub fn deleteProcess(self: *Scheduler, p: *Process) void {
        var prev: *Process = self.first;
        // find the node just before `p`
        while (prev.next != p) : (prev = prev.next) {}
        prev.next = p.next;
        if (p == self.first) {
            // if we removed the first process, we need to update the first pointer
            self.first = p.next;
        }
    }
};

/// A single process (or the idle task) in a circular list.
const Process = struct {
    /// The virtual memory manager for this process.
    vmm: *VirtualMemoryManager,
    /// The process ID
    name: [PROCESS_NAME_MAX_LEN:0]u8,
    pid: u64,
    state: State,
    context: *CpuContext,
    next: *Process, // non-optional ptr: we maintain a true circular list
};

const State = enum {
    /// The process is in the queue and waiting to be scheduled.
    Ready,
    /// The process is currently running on the CPU.
    Running,
    /// The process has finished running and should not be scheduled. Its resources can also be
    /// cleaned up.
    Dead,
};
