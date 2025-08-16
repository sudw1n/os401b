const std = @import("std");
const cpu = @import("../cpu.zig");
const idt = @import("../interrupts/idt.zig");
const ioapic = @import("../interrupts/ioapic.zig");
const process = @import("process.zig");
const kernel_allocator = @import("../memory/allocator.zig");
const term = @import("../tty/terminal.zig");

const CpuContext = idt.InterruptFrame;
const Process = process.Process;
const Thread = process.Thread;
const State = process.State;
const ThreadFunction = process.ThreadFunction;

const log = std.log.scoped(.scheduler);

pub var global_scheduler: ?*Scheduler = null;
var kernel_process: *Process = undefined; // the kernel process, which is the first process created

var dummy_arg: u64 = undefined; // dummy argument for the dummy thread
fn dummyEntryFn(_: *anyopaque) callconv(.{ .x86_64_sysv = .{} }) void {}

pub fn init() void {
    // Initialize the scheduler, set up the first process, etc.
    const allocator = kernel_allocator.allocator();
    global_scheduler = allocator.create(Scheduler) catch |err| {
        log.err("Failed to allocate scheduler: {}", .{err});
        @panic("Scheduler allocation failed");
    };
    var g = global_scheduler.?; // safe to unwrap because we just allocated it
    g.init(allocator);

    // create and register the currently running kernel code as the first process
    kernel_process = allocator.create(Process) catch |err| {
        log.err("Failed to allocate initial kernel process: {}", .{err});
        @panic("Kernel process allocation failed");
    };
    kernel_process.initKernel("kernel", 0);
    spawn("kernel-main", &dummyEntryFn, &dummy_arg);
}

// Spawn a new kernel thread
pub fn spawn(
    name: []const u8,
    entry_fn: ThreadFunction,
    entry_fn_arg: *anyopaque,
) void {
    var g = global_scheduler.?;
    // add a new thread to the "kernel" process
    const kt = kernel_process.addThread(name, entry_fn, entry_fn_arg);
    g.registerThread(kt);
    log.debug("{}", .{kernel_process});
}

pub fn yield() void {
    // fire the PIT interrupt manually so that the scheduler is called
    asm volatile (
        \\int %[vector]
        :
        : [vector] "i" (0x20),
    );
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    // TODO: make this a truly circular list
    runqueue: ?*Thread = null, // points to the first thread in the list
    current: ?*Thread = null, // currently running thread
    next_pid: u64 = 0, // used to assign unique PIDs to processes

    pub fn init(self: *Scheduler, allocator: std.mem.Allocator) void {
        self.* = Scheduler{
            .allocator = allocator,
        };
    }

    pub fn scheduleNewThread(
        self: *Scheduler,
        name: []const u8,
        entry_fn: ThreadFunction,
        entry_fn_arg: *anyopaque,
    ) !void {
        log.info("Scheduling new thread: \"{s}\"", .{name});
        // allocate a new process
        const p = try self.allocator.create(Process);
        const pid = self.next_pid;
        self.next_pid += 1;
        p.init(name, pid);
        // register the thread to the process
        const t = p.addThread(name, entry_fn, entry_fn_arg);
        // also register it in the scheduler
        self.registerThread(t);
    }

    /// Heart of the scheduler: save the old context, pick the next READY,
    /// clean out any DEAD processes as we go, and return its context.
    pub fn schedule(self: *Scheduler, context: *CpuContext) *CpuContext {

        // disable interrupts to prevent context switch during this operation
        const old = self.current orelse {
            @branchHint(.unlikely);
            log.err("No current thread to schedule", .{});
            @panic("No current thread to schedule");
        };

        // find a non-dead process to run
        var candidate = old.next_in_runqueue orelse self.runqueue orelse {
            @branchHint(.unlikely);
            log.err("No threads available to schedule", .{});
            @panic("no threads left to run");
        };
        while (candidate.state == .Dead) {
            log.debug("Thread \"{s}\" (TID: {d}) is dead", .{ candidate.name, candidate.tid });
            candidate = self.unregisterThread(candidate) orelse {
                @branchHint(.unlikely);
                log.err("No threads left to run", .{});
                @panic("no threads left to run");
            };
        }

        // If the new thread chosen is the same as old, just return the incoming context pointer.
        // That leaves us on the same stack and effectively does nothing.
        if (candidate == old) {
            return context;
        }

        old.context = context.*;
        if (old.state != .Dead) old.state = .Ready;

        const next_thread = candidate;

        next_thread.state = .Running;
        self.current = next_thread;

        // load the new process's page tables
        log.debug("Switching to process \"{s}\" (PID: {d}), thread \"{s}\" (TID: {d})", .{ next_thread.parent.name, next_thread.parent.pid, next_thread.name, next_thread.tid });
        next_thread.parent.vmm.activate();
        return &next_thread.context;
    }

    /// Insert `t` in the list at the front
    pub fn registerThread(self: *Scheduler, t: *Thread) void {
        log.info("Registering thread \"{s}\" (TID: {d})", .{ t.name, t.tid });
        if (self.runqueue) |first| {
            log.debug("list non-empty, head is \"{s}\" (TID: {d}), appending", .{ first.name, first.tid });
            var last = first;
            while (last.next_in_runqueue) |n| {
                last = n;
            }
            last.next_in_runqueue = t;
        } else {
            log.debug("list empty, making it the head/current", .{});
            self.runqueue = t; // first thread in the list
            // if this was the first thread, then it should mean our current is null, so initialize
            // it
            self.current = t;
        }
        t.next_in_runqueue = null;
    }

    pub fn threadExit(self: *Scheduler) void {
        // mark the current thread as dead
        const t = self.current orelse {
            log.err("No current thread to exit", .{});
            @panic("No current thread to exit");
        };
        t.state = .Dead;
        log.info("Thread \"{s}\" (TID: {d}) has exited", .{ t.name, t.tid });
        while (true) {
            // Halt the CPU until an interrupt occurs so that our scheduler will be called and it
            // can switch to another thread as well as clean up the dead thread.
            asm volatile ("hlt");
        }
    }

    /// Remove `t` from the list. Must not be the only element.
    fn unregisterThread(self: *Scheduler, t: *Thread) ?*Thread {
        log.info("Unregistering thread \"{s}\" (TID: {d})", .{ t.name, t.tid });

        std.debug.assert(t.state != .Running); // we should never unregister a running thread

        // must have at least one thread
        const first = self.runqueue orelse {
            log.err("No threads in the list to delete", .{});
            @panic("No threads in the list to delete");
        };

        var successor: ?*Thread = null;

        // special case: only one thread in the list
        if (first == t) {
            successor = t.next_in_runqueue; // could be null
            if (t.next_in_runqueue == null) {
                self.runqueue = null; // this was the only thread, so we can clear the list
                self.current = null;
            } else {
                self.runqueue = t.next_in_runqueue; // advance the head
                // if we removed the running thread, pick its successor
                if (self.current == t) self.current = t.next_in_runqueue;
            }
        } else {
            var prev = first;
            while (prev.next_in_runqueue) |n| {
                if (n == t) break;
                prev = n;
            }
            if (prev.next_in_runqueue != t) {
                log.err("Thread \"{s}\" (TID: {d}) not found in the list", .{ t.name, t.tid });
                @panic("Thread to unregister not found in the list");
            }
            successor = t.next_in_runqueue orelse self.runqueue; // if tail to be removed, wrap around to head
            prev.next_in_runqueue = t.next_in_runqueue;

            // if we removed the running thread, pick its successor
            if (self.current == t) self.current = successor;
        }

        // detach it completely and let parent clean it up
        t.next_in_runqueue = null;
        const parent = t.parent;
        parent.removeThread(t);

        return successor;
    }
};
