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
    log.info("disabling the 8259 PIC", .{});
    disablePic();
    log.info("PIC disabled", .{});
}

pub fn checkApic() bool {
    const leaf = cpu.cpuid(1, 0);
    // check the 9th bit
    return (leaf.edx & (1 << 8)) != 0;
}

// PIC "master" and "slave" command/data ports
const PIC_COMMAND_MASTER = 0x20;
const PIC_DATA_MASTER = 0x21;
const PIC_COMMAND_SLAVE = 0xA0;
const PIC_DATA_SLAVE = 0xA1;

// ICW (Initialization Command Words) for the PICs

// indicates start of initialization sequence, same for master and slave
const ICW_1: u8 = 0x11;
// interrupt vector address values (IDT entries) for master and slave
// this is since the first 31 interrupts are exceptions/reserved,
// both PICs occupy 8 IRQs each
const ICW_2_M: u8 = 0x20;
const ICW_2_S: u8 = 0x28;
// used to indicate if the pin has a slave or not.
// since the slave pic will be connected to one of the interrupt pins of the master, we need to
// indicate which one it is. On x86, the slave is connected to second IRQ pin of the master.
// for the slave, the value will be its id.
const ICW_3_M: u8 = 0x2;
const ICW_3_S: u8 = 0x4;
// contains some configuration bits for the mode of operation, in this case we just tell we are
// going to use the 8086 mode.
const ICW_4: u8 = 0;

// mask all interrupts
const MASK_INTERRUPTS: u8 = 0xff;
fn disablePic() void {
    const out = cpu.out;

    out(PIC_COMMAND_MASTER, ICW_1);
    out(PIC_COMMAND_SLAVE, ICW_1);

    out(PIC_DATA_MASTER, ICW_2_M);
    out(PIC_DATA_SLAVE, ICW_2_S);

    out(PIC_DATA_MASTER, ICW_3_M);
    out(PIC_DATA_SLAVE, ICW_3_S);

    out(PIC_DATA_MASTER, ICW_4);
    out(PIC_DATA_SLAVE, ICW_4);

    out(PIC_DATA_MASTER, MASK_INTERRUPTS);
    out(PIC_DATA_SLAVE, MASK_INTERRUPTS);
}
