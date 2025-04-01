const std = @import("std");


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
