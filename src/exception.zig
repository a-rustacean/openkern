const uart = @import("uart.zig");

pub fn init() void {
    asm volatile (
        \\ msr vbar_el1, %[table]
        \\ isb
        :
        : [table] "r" (&vectorTable),
        : .{ .memory = true });
}

export fn vectorTable() align(2048) callconv(.naked) void {
    asm volatile (
        \\.balign 128
        \\ mov x0, #0
        \\ b 1f
        \\.balign 128
        \\ mov x0, #1
        \\ b 1f
        \\.balign 128
        \\ mov x0, #2
        \\ b 1f
        \\.balign 128
        \\ mov x0, #3
        \\ b 1f
        \\.balign 128
        \\ mov x0, #4
        \\ b 1f
        \\.balign 128
        \\ mov x0, #5
        \\ b 1f
        \\.balign 128
        \\ mov x0, #6
        \\ b 1f
        \\.balign 128
        \\ mov x0, #7
        \\ b 1f
        \\.balign 128
        \\ mov x0, #8
        \\ b 1f
        \\.balign 128
        \\ mov x0, #9
        \\ b 1f
        \\.balign 128
        \\ mov x0, #10
        \\ b 1f
        \\.balign 128
        \\ mov x0, #11
        \\ b 1f
        \\.balign 128
        \\ mov x0, #12
        \\ b 1f
        \\.balign 128
        \\ mov x0, #13
        \\ b 1f
        \\.balign 128
        \\ mov x0, #14
        \\ b 1f
        \\.balign 128
        \\ mov x0, #15
        \\ 1:
        \\ bl exceptionVectorHandler
        \\ 2:
        \\ wfi
        \\ b 2b
        ::: .{
            .x0 = true,
            .x30 = true,
            .memory = true,
        });
}

export fn exceptionVectorHandler(vector: u64) callconv(.c) noreturn {
    asm volatile ("msr daifset, #0xf" ::: .{ .memory = true });

    uart.print("\n=== EXCEPTION ===\n");
    uart.print("vector: ");
    uart.printDec(vector);
    uart.print(" (");
    uart.print(vectorName(vector));
    uart.print(")\n");

    const esr = readSysReg("esr_el1");
    printReg("ESR_EL1", esr);
    uart.print("  class: ");
    uart.print(exceptionClassName(esr));
    uart.print("\n");
    printReg("FAR_EL1", readSysReg("far_el1"));
    printReg("ELR_EL1", readSysReg("elr_el1"));
    printReg("SPSR_EL1", readSysReg("spsr_el1"));
    printReg("SP", currentSp());

    halt();
}

pub fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
    asm volatile ("msr daifset, #0xf" ::: .{ .memory = true });

    uart.print("\n=== PANIC ===\n");
    uart.print(msg);
    uart.print("\n");
    printReg("return address", ret_addr orelse @returnAddress());
    printReg("SP", currentSp());

    halt();
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}

fn readSysReg(comptime reg: []const u8) u64 {
    return asm volatile ("mrs %[ret], " ++ reg
        : [ret] "=r" (-> u64),
    );
}

fn currentSp() u64 {
    return asm volatile ("mov %[ret], sp"
        : [ret] "=r" (-> u64),
    );
}

fn printReg(name: []const u8, value: u64) void {
    uart.print(name);
    uart.print(": ");
    uart.printHex(value);
    uart.print("\n");
}

fn vectorName(vector: u64) []const u8 {
    return switch (vector) {
        0 => "current EL with SP0, synchronous",
        1 => "current EL with SP0, IRQ",
        2 => "current EL with SP0, FIQ",
        3 => "current EL with SP0, SError",
        4 => "current EL with SPx, synchronous",
        5 => "current EL with SPx, IRQ",
        6 => "current EL with SPx, FIQ",
        7 => "current EL with SPx, SError",
        8 => "lower EL AArch64, synchronous",
        9 => "lower EL AArch64, IRQ",
        10 => "lower EL AArch64, FIQ",
        11 => "lower EL AArch64, SError",
        12 => "lower EL AArch32, synchronous",
        13 => "lower EL AArch32, IRQ",
        14 => "lower EL AArch32, FIQ",
        15 => "lower EL AArch32, SError",
        else => "invalid",
    };
}

fn exceptionClassName(esr: u64) []const u8 {
    const ec: u8 = @intCast((esr >> 26) & 0x3f);
    return switch (ec) {
        0x00 => "unknown reason",
        0x01 => "trapped WFI/WFE",
        0x07 => "FP/SIMD access",
        0x0e => "illegal execution state",
        0x15 => "SVC (AArch64)",
        0x16 => "HVC (AArch64)",
        0x17 => "SMC (AArch64)",
        0x18 => "trapped MSR/MRS/system instruction",
        0x20 => "instruction abort from lower EL",
        0x21 => "instruction abort from same EL",
        0x22 => "PC alignment fault",
        0x24 => "data abort from lower EL",
        0x25 => "data abort from same EL",
        0x26 => "SP alignment fault",
        0x2c => "trapped FP exception",
        0x30 => "breakpoint from lower EL",
        0x31 => "breakpoint from same EL",
        0x32 => "software step from lower EL",
        0x33 => "software step from same EL",
        0x34 => "watchpoint from lower EL",
        0x35 => "watchpoint from same EL",
        0x3c => "BRK (AArch64)",
        else => "unrecognized",
    };
}
