const std = @import("std");
const memory = @import("memory.zig");
const pagetable = @import("pagetable.zig");

// Static page-table pool until a physical frame allocator exists. Each table
// covers one 4 KiB granule; exhaustion is reported as an initialization error
// instead of silently corrupting memory.
const table_pool_size = 64;
var table_pool: [table_pool_size]pagetable.Table align(pagetable.page_size) = undefined;

var last_table_count: usize = 0;

pub fn tablesUsed() usize {
    return last_table_count;
}

const kernel_symbols = struct {
    extern const __kernel_start: u8;
    extern const __kernel_end: u8;
    extern const __text_start: u8;
    extern const __text_end: u8;
    extern const __rodata_start: u8;
    extern const __rodata_end: u8;
    extern const __data_start: u8;
};

const ram_attributes: pagetable.Attributes = .{};
const text_attributes: pagetable.Attributes = .{
    .read_only = true,
    .executable = true,
};
const rodata_attributes: pagetable.Attributes = .{ .read_only = true };
const data_attributes: pagetable.Attributes = .{};
const device_attributes: pagetable.Attributes = .{ .kind = .device };

const device_start: u64 = 0x0800_0000;
const device_size: u64 = 0x0400_0000;

pub const InitError = pagetable.Error || error{
    NoMemoryRanges,
    KernelOutsideMemory,
    DeviceOverlapsMemory,
    SelfTestFailed,
};

pub fn init(ranges: []const memory.Range) InitError!void {
    if (ranges.len == 0) return error.NoMemoryRanges;

    for (ranges) |range| {
        if (rangesOverlap(device_start, device_size, range.start, range.size)) {
            return error.DeviceOverlapsMemory;
        }
    }

    const kernel_start = @intFromPtr(&kernel_symbols.__kernel_start);
    const kernel_end = @intFromPtr(&kernel_symbols.__kernel_end);
    if (kernel_end <= kernel_start) return error.SelfTestFailed;
    if (!rangeContains(ranges, kernel_start, kernel_end - kernel_start)) {
        return error.KernelOutsideMemory;
    }

    var builder = try pagetable.Builder.init(table_pool[0..]);

    for (ranges) |range| {
        try builder.mapRange(range.start, range.size, ram_attributes);
    }

    try builder.mapRange(device_start, device_size, device_attributes);

    const text_start = @intFromPtr(&kernel_symbols.__text_start);
    const text_end = @intFromPtr(&kernel_symbols.__text_end);
    if (text_end > text_start) {
        try mapPagesRange(&builder, text_start, text_end, text_attributes);
    }

    const rodata_start = @intFromPtr(&kernel_symbols.__rodata_start);
    const rodata_end = @intFromPtr(&kernel_symbols.__rodata_end);
    if (rodata_end > rodata_start) {
        try mapPagesRange(&builder, rodata_start, rodata_end, rodata_attributes);
    }

    const data_start = @intFromPtr(&kernel_symbols.__data_start);
    if (kernel_end > data_start) {
        try mapPagesRange(&builder, data_start, kernel_end, data_attributes);
    }

    last_table_count = builder.tablesUsed();

    try selfTest(
        &builder,
        ranges,
        kernel_start,
        kernel_end,
        text_start,
        text_end,
        rodata_start,
        rodata_end,
        data_start,
    );

    enable(builder.root);
    try verifyEnabled();
}

fn rangeContains(ranges: []const memory.Range, start: u64, size: u64) bool {
    const end = std.math.add(u64, start, size) catch return false;
    for (ranges) |range| {
        if (start >= range.start and end <= range.end()) return true;
    }
    return false;
}

fn mapPagesRange(
    builder: *pagetable.Builder,
    start: u64,
    end: u64,
    attrs: pagetable.Attributes,
) InitError!void {
    var address = start;
    while (address < end) : (address += pagetable.page_size) {
        try builder.mapPage(address, attrs);
    }
}

fn rangesOverlap(a_start: u64, a_size: u64, b_start: u64, b_size: u64) bool {
    const a_end = std.math.add(u64, a_start, a_size) catch return true;
    const b_end = std.math.add(u64, b_start, b_size) catch return true;
    return a_start < b_end and b_start < a_end;
}

fn selfTest(
    builder: *const pagetable.Builder,
    ranges: []const memory.Range,
    kernel_start: u64,
    kernel_end: u64,
    text_start: u64,
    text_end: u64,
    rodata_start: u64,
    rodata_end: u64,
    data_start: u64,
) InitError!void {
    for (ranges) |range| {
        if (range.size == 0) continue;

        const end = range.end();
        var address = range.start;
        while (address < end) : (address += pagetable.block_size) {
            if (builder.translate(address) == null) return error.SelfTestFailed;

            const block_end = @min(address + pagetable.block_size, end);
            const outside_kernel = block_end <= kernel_start or address >= kernel_end;
            const full_block = address % pagetable.block_size == 0 and
                block_end - address == pagetable.block_size;

            if (outside_kernel and full_block) {
                const translation = builder.translate(address) orelse
                    return error.SelfTestFailed;
                if (translation.level != 2) return error.SelfTestFailed;
                if (!attributesMatch(translation.descriptor, ram_attributes)) {
                    return error.SelfTestFailed;
                }
            }
        }
        if (builder.translate(end - 1) == null) return error.SelfTestFailed;
    }

    try expectPages(builder, text_start, text_end, text_attributes);
    try expectPages(builder, rodata_start, rodata_end, rodata_attributes);
    try expectPages(builder, data_start, kernel_end, data_attributes);

    const uart = builder.translate(0x0900_0000) orelse return error.SelfTestFailed;
    if (uart.level != 2) return error.SelfTestFailed;
    if (!attributesMatch(uart.descriptor, device_attributes)) {
        return error.SelfTestFailed;
    }

    const gic = builder.translate(0x0800_0000) orelse return error.SelfTestFailed;
    if (gic.level != 2) return error.SelfTestFailed;
    if (!attributesMatch(gic.descriptor, device_attributes)) {
        return error.SelfTestFailed;
    }
}

fn expectPages(
    builder: *const pagetable.Builder,
    start: u64,
    end: u64,
    expected: pagetable.Attributes,
) InitError!void {
    if (end <= start) return;

    var address = start;
    while (address < end) : (address += pagetable.page_size) {
        const translation = builder.translate(address) orelse return error.SelfTestFailed;
        if (translation.level != 3) return error.SelfTestFailed;
        if (!attributesMatch(translation.descriptor, expected)) {
            return error.SelfTestFailed;
        }
    }
}

fn attributesMatch(descriptor: u64, expected: pagetable.Attributes) bool {
    if (descriptor & pagetable.bits.af == 0) return false;
    if (pagetable.isReadOnly(descriptor) != expected.read_only) return false;
    if (pagetable.isEl1Executable(descriptor) != expected.executable) return false;
    if (pagetable.isUserExecutable(descriptor)) return false;

    const expected_index: u3 = switch (expected.kind) {
        .normal => 0,
        .device => 1,
    };
    if (pagetable.attributeIndex(descriptor) != expected_index) return false;

    return switch (expected.kind) {
        .normal => descriptor & pagetable.bits.sh_inner != 0,
        .device => descriptor & pagetable.bits.sh_mask == 0,
    };
}

fn enable(root: *const pagetable.Table) void {
    const parange = readSysReg("id_aa64mmfr0_el1") & 0xf;
    const ips: u64 = if (parange <= 5) parange else 5;

    // Attr0: Normal write-back, read/write allocate. Attr1: Device-nGnRnE.
    const mair: u64 = 0xff;

    const tcr: u64 =
        (16 << 0) | // T0SZ: 48-bit VA
        (1 << 8) | // IRGN0: write-back, write allocate
        (1 << 10) | // ORGN0: write-back, write allocate
        (3 << 12) | // SH0: inner shareable
        (0 << 14) | // TG0: 4 KiB
        (16 << 16) | // T1SZ: unused while EPD1 is set
        (1 << 23) | // EPD1: disable the upper VA half
        (1 << 24) | // IRGN1
        (1 << 26) | // ORGN1
        (3 << 28) | // SH1
        (2 << 30) | // TG1: 4 KiB
        (ips << 32); // IPS

    writeSysReg("mair_el1", mair);
    writeSysReg("tcr_el1", tcr);
    writeSysReg("ttbr0_el1", @intFromPtr(root));

    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
    asm volatile ("tlbi vmalle1" ::: .{ .memory = true });
    asm volatile ("dsb sy" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });

    var sctlr = readSysReg("sctlr_el1");
    sctlr |= (1 << 0) | // M
        (1 << 2) | // C
        (1 << 12) | // I
        (1 << 19); // WXN
    writeSysReg("sctlr_el1", sctlr);

    asm volatile ("isb" ::: .{ .memory = true });
}

fn verifyEnabled() InitError!void {
    const required = (1 << 0) | (1 << 2) | (1 << 12) | (1 << 19);
    if (readSysReg("sctlr_el1") & required != required) {
        return error.SelfTestFailed;
    }
}

fn readSysReg(comptime reg: []const u8) u64 {
    return asm volatile ("mrs %[ret], " ++ reg
        : [ret] "=r" (-> u64),
    );
}

fn writeSysReg(comptime reg: []const u8, value: u64) void {
    asm volatile ("msr " ++ reg ++ ", %[value]"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}
