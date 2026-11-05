const DTB = @import("DTB.zig");
const exception = @import("exception.zig");
const uart = @import("uart.zig");

pub export fn kernel_main() callconv(.c) void {
    exception.init();

    const dtb: DTB = .{
        .ptr = @ptrFromInt(0x4000_0000),
    };
    if (!dtb.validate()) {
        return;
    }
    var iter = dtb.struct_tokens();
    var indent: u32 = 0;
    while (true) {
        const token = iter.next();
        switch (token) {
            .begin_node => {
                for (0..indent) |_| {
                    uart.print("  ");
                }
                const name = iter.node_name();
                uart.print(name);
                uart.print(" {\n");
                indent += 1;
            },
            .end => break,
            .end_node => {
                indent -= 1;
                for (0..indent) |_| {
                    uart.print("  ");
                }
                uart.print("}\n");
            },
            .nop => {},
            .prop => {
                for (0..indent) |_| {
                    uart.print("  ");
                }
                const meta = iter.prop_meta();
                const name = dtb.string(meta.name_offset);
                uart.print(name);
                uart.print(": ");
                uart.printEscaped(meta.value);
                uart.print("\n");
            },
        }
    }
}
