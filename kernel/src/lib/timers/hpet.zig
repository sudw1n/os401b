const std = @import("std");
const limine = @import("limine");
const acpi = @import("../acpi.zig");
const paging = @import("../memory/paging.zig");

const log = std.log.scoped(.hpet);
const pagingLog = std.log.scoped(.paging);

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
    pub fn init(xsdt: *acpi.Xsdt) ?*HpetSdt {
        const result = xsdt.findSdtHeader("HPET");
        if (result) |hpet_sdt| {
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

            return hpet;
        }
        // in this case, result == null
        return null;
    }
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

pub fn init(rsdp_response: *limine.RsdpResponse) void {
    const rsdp = acpi.Rsdp2Descriptor.init(rsdp_response);
    const xsdt = rsdp.getXSDT();
    if (HpetSdt.init(xsdt)) |hpet| {
        const hpet_base = paging.physToVirtRaw(hpet.address);

        const general_configuration = getRegister(GeneralConfiguration, hpet_base, Registers.GeneralConfiguration);
        // In order for the main counter to actually begin counting, we need to enable it.
        // Furthermore, the default setting is for the HPET to be in legacy mode, but since we want
        // to use the HPET this bit should be cleared.
        general_configuration.legacy_mode = 0;
        general_configuration.enable_cnf = 1;
    }
}

fn getRegister(comptime T: type, base: u64, register: Registers) *volatile T {
    const offset = register.get();
    return @ptrFromInt(base + offset);
}
