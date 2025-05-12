const std = @import("std");
const cpu = @import("../cpu.zig");
const registers = @import("../registers.zig");
const lapic = @import("../interrupts/lapic.zig");
const ioapic = @import("../interrupts/ioapic.zig");
const pit = @import("../timers/pit.zig");

const LApicRegister = lapic.Registers;
const Msr = registers.Msr;

const log = std.log.scoped(.tsc);

/// TSC Deadline Timer
pub const TscTimer = struct {
    /// How many ticks occur in 1 ms
    ticks_per_ms: u64,
    pub fn init(vector: u8) TscTimer {
        // sanity checks
        checkTsc();
        checkInvariantTsc();
        checkTscDeadline();

        // If TSC deadline mode is selected in the timer LVT an interrupt is generated. The mode is
        // selecting by using 0b10 in the LVT register.
        var lvt = ioapic.Lvt.init(vector, false);
        lvt.timer_mode = 0b10;
        const raw: u32 = @as(u32, @bitCast(lvt));

        const timer = lapic.global_lapic.get(u32, lapic.Registers.Timer);
        timer.* = raw;

        return TscTimer{ .ticks_per_ms = getTicksPerMs() };
    }

    pub fn sleep(self: TscTimer, ms: u64) void {
        const ticks = std.math.mul(u64, ms, self.ticks_per_ms) catch @panic("Tsc.sleep: multiplication error");
        const current_count = cpu.rdtsc();
        const final_count = current_count + ticks;
        while (cpu.rdtsc() < final_count) {
            // Spin Loop Hint
            // see: https://www.felixcloutier.com/x86/pause.html
            asm volatile ("pause");
        }
    }

    pub fn arm(self: TscTimer, ms: u64) void {
        const ticks = std.math.mul(u64, ms, self.ticks_per_ms) catch @panic("Tsc.armInterrupt: multiplication error");
        const current_count = cpu.rdtsc();
        Msr.IA32_TSC_DEADLINE.write(current_count + ticks);
    }

    /// Check if the TSC is present
    fn checkTsc() void {
        // CPUID EAX=1: Feature Information in EDX and ECX
        const leaf = cpu.cpuid(1, 0);
        // Bit 4: TSC is present
        const tsc_mask = (1 << 4);
        if ((leaf.edx & tsc_mask) == 0) {
            @branchHint(.unlikely);
            @panic("TSC not present");
        }
    }

    fn checkInvariantTsc() void {
        // EAX=8000'0007h: Processor Power Management Information and RAS Capabilities
        const leaf = cpu.cpuid(0x80000007, 0);
        // Bit 8: Invariant TSC
        const invariant_mask = (1 << 8);
        if ((leaf.edx & invariant_mask) == 0) {
            // most processors support I-TSC and so do emulators but they may not advertise it through
            // CPUID
            @branchHint(.likely);
            log.warn("Invariant TSC reported as not present", .{});
        }
    }

    fn checkTscDeadline() void {
        const leaf = cpu.cpuid(1, 0);
        const tsc_deadline_mask = (1 << 24);
        if ((leaf.ecx & tsc_deadline_mask) == 0) {
            // this should almost always be supported
            @branchHint(.unlikely);
            @panic("TSC deadline timer reported as not present");
        }
    }

    fn getTicksPerMs() u64 {
        if (getCalibrationCpuId()) |freq| {
            @branchHint(.likely);
            // the value is per sec, so convert it into per ms for better precision
            return std.math.divCeil(u64, freq, 1000) catch @panic("Tsc.getTicksPerMs: division error converting frequency into ticks per ms");
        }
        log.warn("Couldn't determine TSC frequency with CPUID method, falling back to PIT based calibration", .{});
        return getCalibrationPit();
    }

    // TODO: this doesn't seem to work, find a fix
    /// gets ticks per seconds of the TSC using CPUID method
    fn getCalibrationCpuId() ?u64 {
        // CPUID EAX=15h: TSC and Core Crystal frequency information
        const leaf15h = cpu.cpuid(0x15, 0);
        // EAX: Ratio of TSC frequency to Core Crystal Clock frequency, denominator
        // EBX: Ratio of TSC frequency to Core Crystal Clock frequency, numerator
        // ECX: Core Crystal Clock frequency, in units of Hz
        if (leaf15h.ebx != 0 and leaf15h.ecx != 0) {
            // If the returned values in EBX and ECX of leaf 15h are both nonzero,
            // then the TSC frequency in Hz is given by:
            // TSCFreq = ECX*(EBX/EAX).
            const ratio = std.math.divCeil(u32, leaf15h.ebx, leaf15h.eax) catch @panic("Tsc.getTscFreqHz: division error with leaf15h ebx/eax");
            return std.math.mulWide(u32, leaf15h.ecx, ratio);
        }
        log.warn("Couldn't determine TSC frequency with CPUID 15h, falling back to CPUID 16h", .{});

        // on some processors, leaf15h.ecx == 0 but leaf16h.eax is present. In this case, the TSC
        // frequency is equal to the processor base frequency.

        // CPUID EAX=16h: Processor and Bus specification frequencies
        const leaf16h = cpu.cpuid(0x16, 0);
        // EAX: Processor Base Frequency (in MHz)
        if (leaf16h.eax != 0) {
            // convert MHz to Hz
            return std.math.mulWide(u32, leaf16h.eax, 1e6);
        }
        log.warn("Couldn't determine TSC frequency with CPUID 16h", .{});
        return null;
    }
    // gets ticks per seconds of the TSC using PIT method
    fn getCalibrationPit() u64 {
        // we will use the PIT to find out how many ticks correspond to a given duration in TSC
        const sample_ms = 50;

        const start = cpu.rdtsc();

        // sleep for sample ms
        pit.sleep(sample_ms);

        // snapshot ending counts
        const end = cpu.rdtsc();

        // compute deltas
        const delta: u64 = end - start;

        // how many APIC ticks correspond to this ms
        const ticks_per_ms: u64 = std.math.divCeil(u64, delta, sample_ms) catch @panic("Tsc.getTicksPerPitMs: division error");

        // convert per ms into per s
        return ticks_per_ms;
    }
};
