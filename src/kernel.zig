const std = @import("std");

comptime {
    asm (
        \\ .global _start
        \\ _start:

        // Setup stack
        \\     ldr x30, =stack_top
        \\     mov sp, x30

        // Enable FP/NEON
        \\     mrs x9, cpacr_el1
        \\     mov x10, #0x300000
        \\     orr x9, x9, x10
        \\     msr cpacr_el1, x9
        \\     isb

        // Enter kernel_main
        \\     bl kernel_main
        \\     b .
    );
}

const uart: *volatile u8 = @ptrFromInt(0x0900_0000);

fn putchar(c: u8) void {
    uart.* = c;
}

fn print(s: []const u8) void {
    for (s) |c| {
        putchar(c);
    }
}

pub export fn kernel_main() void {
    print("Hello world!\n");
}
