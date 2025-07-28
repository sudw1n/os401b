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

pub export var val: u64 = 0xdeadbeef;

pub fn init() void {
    asm volatile ("cli");
    // Initialize the scheduler, set up the first process, etc.
    const allocator = kernel_allocator.allocator();
    global_scheduler = allocator.create(Scheduler) catch |err| {
        log.err("Failed to allocate scheduler: {}", .{err});
        @panic("Scheduler allocation failed");
    };
    var g = global_scheduler.?; // safe to unwrap because we just allocated it
    g.init(allocator);
    g.scheduleNewThread("main1", idleMain, &val) catch |err| {
        log.err("Failed to initialize scheduler: {}", .{err});
        @panic("Scheduler initialization failed");
    };
    asm volatile ("sti");
}

fn idleMain(arg: *anyopaque) callconv(.{ .x86_64_sysv = .{} }) void {
    _ = arg;
    while (true) {
        asm volatile ("cli");
        term.print("this is first thread", .{}) catch |err| {
            log.err("Failed to print from first thread: {}", .{err});
            @panic("Failed to print from first thread");
        };
        asm volatile ("sti");
        cpu.hlt();
    }
}

pub fn yield() void {
    // fire the PIT interrupt manually so that the scheduler is called
    asm volatile (
        \\int %[vector]
        :
        : [vector] "i" (ioapic.InterruptVectors.PitTimer.get()),
    );
}

pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    // TODO: make this a truly circular list
    threads: ?*Thread = null, // points to the first thread in the ring
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
        log.info("Scheduling new thread: {s}", .{name});
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
        log.debug("entering schedule, current: {x:0>16}, context: {any}", .{ if (self.current) |c| @intFromPtr(c) else 0, context.* });
        const old = self.current orelse {
            log.err("No current thread to schedule", .{});
            @panic("No current thread to schedule");
        };

        old.context = context.*;
        if (old.state != .Dead) {
            old.state = .Ready;
        }

        // find a non-dead process to run
        var candidate = old.next orelse self.threads;
        while (candidate) |c| {
            if (c.state != .Dead) break;
            log.debug("Skipping dead thread \"{s}\" (TID: {d})", .{ c.name, c.tid });
            candidate = c.next;
            self.unregisterThread(c);
        }

        // if I fell off the end, go back to the head
        const next_thread = if (candidate) |c| c else if (self.threads) |h| h else {
            log.err("No non-dead threads available to schedule", .{});
            @panic("no threads left to run");
        };

        // mark the non-dead process as running
        next_thread.state = .Running;
        self.current = next_thread;

        // load the new process's page tables
        log.debug("Switching to process \"{s}\" with PID {d}, thread \"{s}\" with (TID: {d})", .{ next_thread.parent.name, next_thread.parent.pid, next_thread.name, next_thread.tid });
        next_thread.parent.vmm.activate();
        return &next_thread.context;
    }

    /// Insert `t` in the ring at the front
    fn registerThread(self: *Scheduler, t: *Thread) void {
        log.info("Registering thread \"{s}\" (TID: {d})", .{ t.name, t.tid });
        if (self.threads) |first| {
            log.debug("Ring non-empty, head is \"{s}\" (TID: {d}), appending", .{ first.name, first.tid });
            var last = first;
            while (last.next) |n| {
                last = n;
            }
            last.next = t;
        } else {
            log.debug("Ring empty, making it the head/current", .{});
            self.threads = t; // first thread in the ring
            // if this was the first thread, then it should mean our current is null, so initialize
            // it
            self.current = t;
        }
        t.next = null;
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

    /// Remove `t` from the ring. Must not be the only element.
    fn unregisterThread(self: *Scheduler, t: *Thread) void {
        log.debug("Unregistering thread \"{s}\" (TID: {d})", .{ t.name, t.tid });

        // must have at least one thread
        const first = self.threads orelse {
            log.err("No threads in the ring to delete", .{});
            @panic("No threads in the ring to delete");
        };

        // special case: only one thread in the ring
        if (first == t and t.next == null) {
            self.threads = null; // this was the only thread, so we can clear the ring
            self.current = null;
        } else {
            // find the predecessor of `t`
            var prev = first;
            while (prev.next) |n| {
                if (n == t) break;
                prev = n;
            }
            if (prev.next != t) {
                log.err("Thread \"{s}\" (TID: {d}) not found in the ring", .{ t.name, t.tid });
                @panic("Thread to unregister not found in the ring");
            }
            prev.next = t.next; // remove `t` from the ring

            if (first == t) {
                // if we removed the head, advance it
                self.threads = t.next;
            }

            // if we removed the running thread, pick its successor
            if (self.current == t) {
                self.current = t.next orelse blk: {
                    // t.next is guaranteed non-null here, because we handled the 1‑element case above
                    @branchHint(.unlikely);
                    break :blk self.threads;
                };
            }
        }

        // detach it completely and let parent clean it up
        t.next = null;
        const parent = t.parent;
        parent.removeThread(t);
    }
};
