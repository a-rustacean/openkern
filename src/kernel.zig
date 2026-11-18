const DTB = @import("DTB.zig");
const exception = @import("exception.zig");
const memory = @import("memory.zig");
const mmu = @import("mmu.zig");
const uart = @import("uart.zig");

pub export fn kernel_main() callconv(.c) void {
    exception.init();

    // We pass an ELF image to QEMU, so it uses the bare-metal boot path rather
    // than the Linux boot protocol. In that case the DTB is placed at the start
    // of RAM, and x0 is not guaranteed to hold its address.
    const dtb_address = 0x4000_0000;
    const dtb: DTB = .{
        .ptr = @ptrFromInt(dtb_address),
    };

    if (!dtb.validate()) {
        uart.print("dtb: invalid\n");
        exception.halt();
    }

    const memory_map = memory.parse(&dtb) catch |err| {
        uart.print("memory: parse failed: ");
        uart.print(@errorName(err));
        uart.print("\n");
        exception.halt();
    };

    uart.print("memory ranges:\n");
    for (memory_map.slice()) |range| {
        uart.print("  ");
        uart.printHex(range.start);
        uart.print(" - ");
        uart.printHex(range.end());
        uart.print(" (size ");
        uart.printHex(range.size);
        uart.print(")\n");
    }

    mmu.init(memory_map.slice()) catch |err| {
        uart.print("mmu: init failed: ");
        uart.print(@errorName(err));
        uart.print("\n");
        exception.halt();
    };

    uart.print("mmu: enabled, page tables: ");
    uart.printDec(mmu.tablesUsed());
    uart.print("\n");

    dumpDtb(&dtb);
}

fn dumpDtb(dtb: *const DTB) void {
    var iter = dtb.struct_tokens();
    var indent: u32 = 0;

    while (true) {
        const token = iter.next() catch {
            uart.print("dtb: malformed structure\n");
            return;
        };

        switch (token) {
            .begin_node => {
                for (0..indent) |_| uart.print("  ");
                const name = iter.node_name() catch {
                    uart.print("dtb: malformed node name\n");
                    return;
                };
                uart.print(name);
                uart.print(" {\n");
                indent += 1;
            },
            .end => break,
            .end_node => {
                if (indent != 0) indent -= 1;
                for (0..indent) |_| uart.print("  ");
                uart.print("}\n");
            },
            .nop => {},
            .prop => {
                for (0..indent) |_| uart.print("  ");
                const meta = iter.prop_meta() catch {
                    uart.print("dtb: malformed property\n");
                    return;
                };
                const name = dtb.string(meta.name_offset) orelse {
                    uart.print("<invalid property name>\n");
                    continue;
                };
                uart.print(name);
                uart.print(": ");
                uart.printEscaped(meta.value);
                uart.print("\n");
            },
        }
    }
}
