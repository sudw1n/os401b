const std = @import("std");
const cpu = @import("../cpu.zig");
const pit = @import("pit.zig");
const lapic = @import("../interrupts/lapic.zig");
const ioapic = @import("../interrupts/ioapic.zig");

const Registers = lapic.Registers;

const log = std.log.scoped(.lapic_timer);

pub const LApicTimer = struct {
    /// The underlying LAPIC to which this timer belongs to
    apic: *lapic.LApic,
    /// Ticks per millisecond
    ticks_per_ms: u64,

    pub fn init(apic: *lapic.LApic) LApicTimer {
        // Check if the LAPIC Timer is ARAT (Always Running APIC Timer)
        checkArat();
        var lapic_timer = LApicTimer{
            .apic = apic,
            .ticks_per_ms = 0,
        };
        lapic_timer.calibrate();
        return lapic_timer;
    }

    pub fn arm(self: LApicTimer, ms: u32, vector: u8) void {
        const lvt_reg = self.apic.get(u32, Registers.Timer);
        lvt_reg.* = @bitCast(ioapic.Lvt.init(vector, false));

        const ticks = self.msToTicks(ms);
        const initial_count = self.apic.get(u64, Registers.InitialCount);
        initial_count.* = ticks;
    }

    fn msToTicks(self: LApicTimer, ms: u32) u64 {
        // Convert milliseconds to ticks
        const ticks = std.math.mul(u64, ms, self.ticks_per_ms) catch @panic("msToTicks: multiplication error");
        return ticks;
    }

    /// Check if the LAPIC Timer is ARAT (Always Running APIC Timer)
    fn checkArat() void {
        // CPUID EAX=6: Thermal/power management feature bits in EAX
        const leaf = cpu.cpuid(6, 0);
        // Bit 2: ARAT capability
        const arat_mask = (1 << 2);
        if ((leaf.eax & arat_mask) == 0) {
            // If the CPU doesn't have this bit set, the LAPIC Timer may stop in low power states
            log.warn("LAPIC Timer is not ARAT", .{});
        }
    }

    /// Find the number of ticks per millisecond using the PIT
    fn calibrate(self: *LApicTimer) void {
        // we will use the PIT to find out how many ticks correspond to a given duration in LAPIC
        const sample_ms = 50;
        const apic = self.apic;

        // slow down the APIC so it's easier to measure
        const divisor = apic.get(u16, Registers.Divisor);
        // bits 0-3 select divisor
        // 0b0011 => divide by 4
        divisor.* = 0b0011;

        // arm one-shot at max count
        const timer = apic.get(u8, Registers.Timer);
        // vector = 0, mask = 0, mode = 0
        timer.* = ~@as(u8, 0b111);

        const initial_count = apic.get(u32, Registers.InitialCount);
        initial_count.* = ~@as(u32, 0);

        const current_count = apic.get(u32, Registers.CurrentCount);

        // snapshot starting counts
        const apic_start = current_count.*;

        // sleep for sample ms
        pit.sleep(sample_ms);

        // snapshot ending counts
        const apic_end = current_count.*;

        // compute deltas
        const apic_delta: u64 = apic_start - apic_end;

        // how many APIC ticks correspond to this ms
        const ticks_per_ms: u64 = std.math.divCeil(u64, apic_delta, sample_ms) catch @panic("getCalibration: division error");
        self.ticks_per_ms = ticks_per_ms;
    }
};
