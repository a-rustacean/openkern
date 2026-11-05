const std = @import("std");

const uart: *volatile u8 = @ptrFromInt(0x0900_0000);

pub fn putChar(c: u8) void {
    uart.* = c;
}

pub fn print(s: []const u8) void {
    for (s) |c| {
        putChar(c);
    }
}

pub fn printDec(value: u64) void {
    if (value == 0) {
        putChar('0');
        return;
    }

    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var remaining = value;
    while (remaining != 0) : (remaining /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + remaining % 10);
    }
    print(buf[i..]);
}

pub fn printHex(value: u64) void {
    print("0x");
    var shift: u6 = 60;
    while (true) {
        const digit: u8 = @intCast((value >> shift) & 0xf);
        putChar(if (digit < 10) '0' + digit else 'a' + digit - 10);
        if (shift == 0) break;
        shift -= 4;
    }
}

pub fn printEscaped(s: []const u8) void {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    std.zig.fmtString(s).format(&writer) catch unreachable;
    print(buf[0..writer.end]);
}
