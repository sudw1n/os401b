const std = @import("std");
const idt = @import("../interrupts/idt.zig");
const process = @import("process.zig");

const CpuContext = idt.InterruptFrame;
const Process = process.Process;
const State = process.State;

const log = std.log.scoped(.scheduler);

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
            .allocator = allocator,
            .first = p,
            .current = p,
        };
    }

    pub fn createProcess(self: *Scheduler, name: []const u8, function: *const (fn (*anyopaque) void), arg: *anyopaque) !*Process {
        // allocate a new process
        const p = try self.allocator.create(Process);
        const pid = blk: {
            const pid = self.next_pid;
            self.next_pid += 1;
            break :blk pid;
        };
        p.init(name, pid, State.Ready, function, arg);
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
        // load the new process's page tables
        candidate.vmm.activate();
        return candidate.context;
    }

    /// Insert `p` right after `first` in the ring.
    fn addProcess(self: *Scheduler, p: *Process) void {
        p.next = self.first.next;
        self.first.next = p;
    }

    /// Remove `p` from the ring. Must not be the only element.
    pub fn deleteProcess(self: *Scheduler, p: *Process) void {
        if (p == self.first) {
            // if we removed the first process, we need to update the first pointer
            self.first = p.next;
        } else {
            var prev: *Process = self.first;
            // find the node just before `p`
            while (prev.next != p) : (prev = prev.next) {}
            prev.next = p.next;
        }
        // clean up the process resources
        p.deinit();
    }
};
