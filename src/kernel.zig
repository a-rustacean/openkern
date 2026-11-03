const std = @import("std");

comptime {
    asm (
        \\ .global _start
        \\ _start:
        \\     ldr x30, =stack_top
        \\     mov sp, x30
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
