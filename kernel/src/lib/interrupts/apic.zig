const std = @import("std");
const cpu = @import("../cpu.zig");
const term = @import("../tty/terminal.zig");

const log = std.log.scoped(.apic);

const Leaf = cpu.Leaf;

pub fn init() void {
    log.info("checking APIC support", .{});
    if (!checkApic()) {
        log.err("APIC not supported", .{});
        return;
    }
    log.info("APIC seems to be supported", .{});
}

pub fn checkApic() bool {
    const leaf = cpu.cpuid(1, 0);
    // check the 9th bit
    return (leaf.edx & (1 << 8)) != 0;
}
