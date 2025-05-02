const std = @import("std");
const limine = @import("limine");
const acpi = @import("../acpi.zig");
const ioapic = @import("../interrupts/ioapic.zig");
const lapic = @import("../interrupts/lapic.zig");
const paging = @import("../memory/paging.zig");

const log = std.log.scoped(.hpet);
const pagingLog = std.log.scoped(.paging);

/// Represents the High Precision Event Timer (HPET)
pub const Hpet = struct {
    /// The underlying HPET SDT instance
    hpet_sdt: *HpetSdt,
    /// The virtual base address of the HPET registers
    base: u64,
    /// General configuration register
    general_configuration: *volatile GeneralConfiguration,
    /// General capabilities register
    general_capabilities: *volatile GeneralCapabilities,
    /// Counter value
    counter: *volatile u64,

    pub fn init(rsdp_response: *limine.RsdpResponse) Hpet {
        const rsdp = acpi.Rsdp2Descriptor.init(rsdp_response);
        const xsdt = rsdp.getXSDT();
        if (xsdt.findSdtHeader("HPET")) |hpet_sdt| {
            @branchHint(.likely);

            const hpet: *HpetSdt = @ptrCast(hpet_sdt);
            const hpet_base_phys = hpet.address;
            const hpet_base = paging.physToVirtRaw(hpet_base_phys);

            log.debug("Retrieved HPET base address: {x:0>16}", .{hpet_base_phys});
            pagingLog.info("Mapping HPET registers virt {x:0>16}-{x:0>16} -> phys {x:0>16}", .{
                hpet_base,
                hpet_base + paging.PAGE_SIZE,
                hpet_base_phys,
            });
            paging.mapPage(hpet_base, hpet_base_phys, &.{ .Present, .Writable, .NoCache, .NoExecute });

            const general_configuration = getRegister(GeneralConfiguration, hpet_base, Registers.GeneralConfiguration);
            const general_capabilities = getRegister(GeneralCapabilities, hpet_base, Registers.GeneralCapabilities);
            const counter = getRegister(u64, hpet_base, Registers.MainCounterValue);

            return Hpet{
                .hpet_sdt = hpet,
                .base = hpet_base,
                .general_configuration = general_configuration,
                .general_capabilities = general_capabilities,
                .counter = counter,
            };
        }

        @panic("HPET not found in XSDT");
    }

    /// Enable the HPET
    pub fn enableCounter(self: Hpet) void {
        if (self.general_capabilities.long_mode != 1) {
            @branchHint(.unlikely);
            @panic("HPET is not 64-bit");
        }

        // In order for the main counter to actually begin counting, we need to enable it.
        // Furthermore, the default setting is for the HPET to be in legacy mode, but since we want
        // to use the HPET this bit should be cleared.
        self.general_configuration.legacy_mode = 0;
        self.general_configuration.enable_cnf = 1;
    }

    /// Return the main counter of the HPET as a number of femtoseconds since it was last reset.
    pub fn poll(self: Hpet) u64 {
        const period = self.general_capabilities.precision;
        return self.counter.* * period;
    }

    /// Program a HPET comparator to fire an interrupt at a fixed, periodic interval.
    ///
    /// period: Desired interval between interrupts
    pub fn armComparator(self: Hpet, comparator: u8, period: u64) void {
        const config_reg = ComparatorRegisters.Config.get(self.base, comparator);

        // Determine allowed I/O APIC routing:
        //
        // Every comparator in the HPET has a 32-bit route mask in the top half of its 64-bit config
        // register. 1s in that mask tell us which GSI the HPET can drive.
        // By doing the following, we're scanning from GSI 0 up until we hit the first bit the HPET
        // supports. That index is the pin we will wire our comparator to.
        var allowed_routes: u32 = @truncate(config_reg.* >> 32);
        var used_route: u32 = 0;
        while ((allowed_routes & 1) == 0) {
            used_route += 1;
            allowed_routes >>= 1;
        }
        log.debug("Using GSI {d} for comparator {d}", .{ used_route, comparator });

        // Tell the comparator which pin to use and enable its interrupt:
        //
        // Bit 2 is the interrupt enable bit
        // Bits 3-4 control periodic vs one-shot mode
        // Bits 9-12 hold the GSI number we want
        config_reg.* &= ~@as(u64, (0xF << 9)); // clear any old GSI number
        config_reg.* |= used_route << 9; // program the new GSI
        config_reg.* |= @as(u64, 0b11 << 2); // flip on the interrupt and turn on periodic

        // Nothing will actually ring at the CPU until we program the I/O APIC
        // After the HPET asserts `used_route`, the I/O APIC must forward that GSI into our LAPIC
        // (and then into the IDT).
        const pin: u32 = used_route + ioapic.global_ioapic.gsi_base;
        const vector = ioapic.InterruptVectors.HpetTimer.get();
        const lvt = ioapic.Lvt.init(vector, false);
        ioapic.global_ioapic.program(pin, lvt, lapic.global_lapic.id());

        // Scheduling the next tick:
        //
        // Read the main counter
        // Add the desired interval (in femtoseconds)
        // Write that value to the comparator's value register
        //
        // Once the main counter reaches that value, the comparator's config latch will fire the IRQ
        const counter = self.counter;
        const target: u64 = counter.* + (period / self.general_capabilities.precision);
        const compare_reg = ComparatorRegisters.Value.get(self.base, comparator);
        compare_reg.* = target;
    }

    fn getRegister(comptime T: type, base: u64, register: Registers) *volatile T {
        const offset = register.get();
        return @ptrFromInt(base + offset);
    }
};

pub const HpetSdt = extern struct {
    header: acpi.AcpiSdtHeader align(1),
    event_timer_block_id: u32 align(1),
    /// Note: This is actually some type information describing the address space where the HPET
    /// registers are located. We can safely ignore that as the HPET spec required the registers to
    /// be memory mapped.
    reserved: u32 align(1),
    /// The physical address of the HPET registers.
    address: u64 align(1),
    id: u8 align(1),
    min_ticks: u16 align(1),
    page_protection: u8 align(1),
};

const Registers = enum(u8) {
    GeneralCapabilities = 0x0,
    GeneralConfiguration = 0x10,
    MainCounterValue = 0xF0,
    pub fn get(self: Registers) u8 {
        return @intFromEnum(self);
    }
};

/// The General Capabilities Register is a 64-bit register that contains the general
/// capabilities of the HPET
const GeneralCapabilities = packed struct(u64) {
    /// Hardware revision id.
    revision_id: u8,
    /// The number of timers in the HPET.
    ///
    /// This is the id of the last timer; a value of 2 means there are three timers (0, 1, 2).
    timer_count: u5,
    /// If 1 indicates the main counter is 64-bits, otherwise it's 32-bits
    long_mode: u1,
    reserved: u1 = 0,
    /// If set indicates the HPET can emulate the PIT and RTC timers
    legacy_routing: u1,
    /// Contains the PCI vendor ID of the HPET manufacturer
    vendor_id: u16,
    /// Contains the number of femtoseconds for each tick of the main clock
    precision: u32,
};

/// General Configuration Register
const GeneralConfiguration = packed struct(u64) {
    /// Overall enable.
    ///
    /// 0 - main counter is halted, timer interrupts are disabled
    /// 1 - main counter is running, timer interrupts are allowed if enabled
    enable_cnf: u1,
    /// Legacy replacement mapping
    ///
    /// If set the HPET is in legacy replacement mode, where it pretends to be the PIT and RTC
    /// timer.
    legacy_mode: u1,
    reserved: u62,
};

const ComparatorRegisters = enum(u16) {
    Config = 0x100,
    Value = 0x108,

    /// Get comparator registers for the comparator `n` using the given HPET base.
    pub fn get(self: ComparatorRegisters, hpet_base: u64, n: u8) *volatile u64 {
        const offset = @intFromEnum(self);
        return @ptrFromInt(hpet_base + offset + (n * 0x20));
    }
};

/// Layout of the comparator config and value registers
const Comparator = packed struct(u64) {
    reserved1: u2 = 0,
    /// Even if this is cleared the comparator will still operate, and set the interrupt pending
    /// bit, but no interrupt will be sent to the IO APIC. This bit acts in reverse to how a mask
    /// bit would: if this bit is set, interrupts are generated.
    enable: u1,
    /// First bit is used to select periodic mode if supported.
    /// Second bit is set if the comparator supports periodic mode.
    /// If either bit is cleared, the comparator is in one-shot mode.
    periodic: u2,
    reserved2: u4 = 0,
    /// Write the integer value of the interrupt that should be triggered by this comparator. It’s
    /// recommended to read this register back after writing to verify the comparator accepted the
    /// interrupt number that has been set.
    interrupt_number: u5,
    reserved3: u18 = 0,
    triggerable: u32,
};
