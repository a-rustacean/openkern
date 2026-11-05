const kernel = @import("kernel.zig");

export var stack_bytes: [16 * 1024]u8 align(16) linksection(".bss") = undefined;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\

        // Mask interrupts while setting up the CPU.
        \\ msr daifset, #0xf

        // Find the current exception level.
        \\ mrs x0, CurrentEL
        \\ lsr x0, x0, #2
        \\ cmp x0, #3
        \\ b.eq 3f
        \\ cmp x0, #2
        \\ b.eq 2f

        // Already at EL1: switch to SP_EL1 to get EL1h.
        \\ msr spsel, #1
        \\ b 1f

        // EL3: drop to non-secure AArch64 EL1h.
        \\ 3:
        \\ mov x1, #1
        \\ lsl x1, x1, #31
        \\ msr hcr_el2, x1          // HCR_EL2.RW = 1: EL1 is AArch64
        \\ mrs x1, scr_el3
        \\ orr x1, x1, #1           // SCR_EL3.NS = 1: lower ELs are non-secure
        \\ orr x1, x1, #0x400       // SCR_EL3.RW = 1: lower ELs are AArch64
        \\ msr scr_el3, x1
        \\ adr x1, 1f
        \\ msr elr_el3, x1
        \\ mov x1, #0x3c5           // EL1h, AArch64, DAIF masked
        \\ msr spsr_el3, x1
        \\ eret

        // EL2: drop to AArch64 EL1h.
        \\ 2:
        \\ mov x1, #1
        \\ lsl x1, x1, #31
        \\ msr hcr_el2, x1          // HCR_EL2.RW = 1: EL1 is AArch64
        \\ adr x1, 1f
        \\ msr elr_el2, x1
        \\ mov x1, #0x3c5           // EL1h, AArch64, DAIF masked
        \\ msr spsr_el2, x1
        \\ eret

        // Now at EL1h, non-secure, AArch64.
        \\ 1:
        \\ adrp x8, stack_bytes
        \\ add x8, x8, #:lo12:stack_bytes
        \\ add x8, x8, %[stack_size]
        \\ mov sp, x8

        // Enable FP/NEON
        \\ mrs x9, cpacr_el1
        \\ mov x10, #0x300000
        \\ orr x9, x9, x10
        \\ msr cpacr_el1, x9
        \\ isb

        // Enter kernel_main
        \\ blr %[kernel_main]
        \\ 4:
        \\ wfi
        \\ b 4b
        :
        : [stack_size] "r" (stack_bytes.len),
          [kernel_main] "r" (&kernel.kernel_main),
        : .{
          .x0 = true,
          .x1 = true,
          .x8 = true,
          .x9 = true,
          .x10 = true,
          .x30 = true,
          .memory = true,
        });
}
