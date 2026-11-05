const std = @import("std");
const DTB = @import("DTB.zig");

const uart: *volatile u8 = @ptrFromInt(0x0900_0000);

fn putchar(c: u8) void {
    uart.* = c;
}

fn print(s: []const u8) void {
    for (s) |c| {
        putchar(c);
    }
}

fn fmtPrintString(string: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    std.zig.fmtString(string).format(&writer) catch unreachable;
    print(buf[0..(writer.end)]);
}

pub export fn kernel_main() void {
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
                    print("  ");
                }
                const name = iter.node_name();
                print(name);
                print(" {\n");
                indent += 1;
            },
            .end => break,
            .end_node => {
                indent -= 1;
                for (0..indent) |_| {
                    print("  ");
                }
                print("}\n");
            },
            .nop => {},
            .prop => {
                for (0..indent) |_| {
                    print("  ");
                }
                const meta = iter.prop_meta();
                const name = dtb.string(meta.name_offset);
                print(name);
                print(": ");
                fmtPrintString(meta.value);
                print("\n");
            },
        }
    }
}
