const std = @import("std");
const cpu = @import("cpu.zig");

/// CR2 Register
pub const Cr2 = struct {
    pub inline fn get() u64 {
        return asm volatile ("movq %%cr2, %[out]"
            : [out] "=r" (-> u64),
        );
    }
};

pub const Cr3 = struct {
    pub inline fn get() u64 {
        return asm volatile ("movq %%cr3, %[out]"
            : [out] "=r" (-> u64),
        );
    }
    pub inline fn set(cr3: u64) void {
        asm volatile ("movq %[in], %%cr3"
            :
            : [in] "r" (cr3),
            : "memory"
        );
    }
};

/// RFLAGS Register
pub const Rflags = packed struct(u64) {
    /// Carry Flag
    cf: bool,
    /// Reserved
    res1: u1 = 1,
    /// Parity Flag
    pf: bool,
    /// Reserved
    res2: u1 = 0,
    /// Auxiliary Carry Flag
    af: bool,
    /// Reserved
    res3: u1 = 0,
    /// Zero Flag
    zf: bool,
    /// Sign Flag
    sf: bool,
    /// Trap Flag
    tf: bool,
    /// Interrupt Enable Flag
    @"if": bool,
    /// Direction Flag
    df: bool,
    /// Overflow Flag
    of: bool,
    /// I/O Privilege Level
    iopl: u2,
    /// Nested Task
    nt: bool,
    /// Reserved
    res4: u1 = 0,
    /// Resume Flag
    rf: bool,
    /// Virtual-8086 Mode
    vm: bool,
    /// Alignment Check / Access Control
    ac: bool,
    /// Virtual Interrupt Flag
    vif: bool,
    /// Virtual Interrupt Pending
    vip: bool,
    /// ID Flag
    id: bool,
    /// Reserved
    res5: u42,

    /// Custom formatter for RFLAGS.
    pub fn format(value: Rflags, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        // Convert the packed RFLAGS into a raw u64 value.
        const raw: u64 = @bitCast(value);
        try writer.print("RFLAGS: 0x{x:0>16}\n", .{raw});
        try writer.print("  CF: {s}  PF: {s}  AF: {s}  ZF: {s}  SF: {s}\n", .{
            if (value.cf) "1" else "0",
            if (value.pf) "1" else "0",
            if (value.af) "1" else "0",
            if (value.zf) "1" else "0",
            if (value.sf) "1" else "0",
        });
        try writer.print("  TF: {s}  IF: {s}  DF: {s}  OF: {s}  IOPL: 0b{b}\n", .{
            if (value.tf) "1" else "0",
            if (value.@"if") "1" else "0",
            if (value.df) "1" else "0",
            if (value.of) "1" else "0",
            value.iopl,
        });
        try writer.print("  NT: {s}  RF: {s}  VM: {s}  AC: {s}  VIF: {s}  VIP: {s}  ID: {s}\n", .{
            if (value.nt) "1" else "0",
            if (value.rf) "1" else "0",
            if (value.vm) "1" else "0",
            if (value.ac) "1" else "0",
            if (value.vif) "1" else "0",
            if (value.vip) "1" else "0",
            if (value.id) "1" else "0",
        });
    }

    /// Get RFLAGS
    pub inline fn get(comptime T: type) T {
        switch (T) {
            u64 => return asm volatile (
                \\pushfq
                \\pop %[ret]
                : [ret] "={rax}" (-> u64),
            ),
            Rflags => return asm volatile (
                \\pushfq
                \\pop %[ret]
                : [ret] "={rax}" (-> Rflags),
            ),
            else => @compileError("Unsupported type for RFLAGS.get()"),
        }
    }

    /// Set RFLAGS
    pub inline fn set(comptime T: type, rflags: T) void {
        switch (T) {
            u64, Rflags => asm volatile (
                \\push %[val]
                \\popfq
                :
                : [val] "{rax}" (rflags),
            ),
            else => @compileError("Unsupported type for RFLAGS.set()"),
        }
    }
};

// Model Specific Registers
pub const Msr = enum(u32) {
    /// Contains base address of the LAPIC registers
    ///
    /// This register contains the following information:
    ///  Bits 0:7: reserved.
    ///  Bit 8: if set, it means that the processor is the Bootstrap Processor (BSP).
    ///  Bits 9:10: reserved.
    ///  Bit 11: APIC global enable. This bit can be cleared to disable the local APIC for this processor.
    ///  Bits 12:31: Contains the base address of the local APIC for this processor core.
    ///  Bits 32:63: reserved.
    IA32_APIC_BASE = 0x1B,
    /// TSC Deadline
    IA32_TSC_DEADLINE = 0x6E0,

    /// Read a 64‑bit MSR
    pub inline fn read(self: Msr) u64 {
        var low: u32 = undefined;
        var high: u32 = undefined;
        asm volatile (
            \\ rdmsr
            : [low] "={eax}" (low), // EAX ← low 32 bits
              [high] "={edx}" (high), // EDX ← high 32 bits
            : [msr] "{ecx}" (self), // ECX ← MSR index
            : "memory" // prevent reordering around MSR access
        );
        return (@as(u64, high) << 32) | low;
    }

    /// Write a 64‑bit MSR
    pub inline fn write(self: Msr, value: u64) void {
        const low: u32 = @truncate(value);
        const high: u32 = @truncate(value >> 32);
        asm volatile (
            \\ wrmsr
            :
            : [low] "{eax}" (low), // EAX ← low 32 bits
              [high] "{edx}" (high), // EDX ← high 32 bits
              [msr] "{ecx}" (self), // ECX ← MSR index
            : "memory" // prevent reordering around MSR access
        );
    }
};
