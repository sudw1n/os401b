const cpu = @import("../cpu.zig");
const term = @import("../tty/terminal.zig");

const CpuidResult = cpu.CpuidResult;

pub fn init() !void {
    try term.logStepBegin("Detecting APIC", .{});
    try term.logStepEnd(checkApic());
}

pub fn checkApic() bool {
    const cpuid = cpu.cpuid(1, 0);
    // check the 9th bit
    return (cpuid.edx & (1 << 8)) != 0;
}
