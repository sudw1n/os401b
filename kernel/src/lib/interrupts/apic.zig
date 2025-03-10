const cpu = @import("../cpu.zig");
const term = @import("../tty/terminal.zig");

const Leaf = cpu.Leaf;

pub fn init() !void {
    try term.logStepBegin("Detecting APIC", .{});
    // TODO: if this errors, we only get error.LogStepFail which is not very informative
    try term.logStepEnd(checkApic());
}

pub fn checkApic() bool {
    const leaf = cpu.cpuid(1, 0);
    // check the 9th bit
    return (leaf.edx & (1 << 8)) != 0;
}
