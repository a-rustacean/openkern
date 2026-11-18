const std = @import("std");
const DTB = @import("DTB.zig");

pub const max_ranges = 16;

pub const Range = struct {
    start: u64,
    size: u64,

    pub fn end(self: Range) u64 {
        return self.start + self.size;
    }
};

pub const MemoryMap = struct {
    ranges: [max_ranges]Range = undefined,
    len: usize = 0,

    pub fn slice(self: *const MemoryMap) []const Range {
        return self.ranges[0..self.len];
    }
};

pub const Error = error{
    InvalidDTB,
    NoMemoryNodes,
    UnsupportedAddressCells,
    UnsupportedSizeCells,
    MalformedCells,
    MalformedReg,
    Overflow,
    TooManyRanges,
};

pub fn parse(dtb: *const DTB) Error!MemoryMap {
    if (!dtb.validate()) return error.InvalidDTB;
    const root = dtb.findNode("/") orelse return error.InvalidDTB;

    const root_address_cells = try parseCellCount(dtb, root, "#address-cells", 2);
    const root_size_cells = try parseCellCount(dtb, root, "#size-cells", 1);

    var map: MemoryMap = .{};
    var found_memory = false;

    var nodes = dtb.rootChildren();
    while (true) {
        const entry = nodes.next() catch return error.InvalidDTB;
        const node = entry orelse break;
        if (!isMemoryNode(dtb, node)) continue;

        found_memory = true;
        const address_cells = try parseCellCount(
            dtb,
            node.node,
            "#address-cells",
            root_address_cells,
        );
        const size_cells = try parseCellCount(
            dtb,
            node.node,
            "#size-cells",
            root_size_cells,
        );

        const reg = dtb.getProperty(node.node, "reg") orelse return error.MalformedReg;
        try parseReg(&map, reg, address_cells, size_cells);
    }

    if (!found_memory) return error.NoMemoryNodes;
    return map;
}

fn parseCellCount(
    dtb: *const DTB,
    node: DTB.NodeRef,
    property: []const u8,
    default: u32,
) Error!u32 {
    const value = dtb.getProperty(node, property) orelse return default;
    if (value.len != 4) return error.MalformedCells;

    const count = std.mem.readInt(u32, value[0..4], .big);
    if (count == 1 or count == 2) return count;

    if (std.mem.eql(u8, property, "#address-cells")) {
        return error.UnsupportedAddressCells;
    }
    return error.UnsupportedSizeCells;
}

fn isMemoryNode(dtb: *const DTB, node: DTB.NodeIterator.Entry) bool {
    if (dtb.getProperty(node.node, "device_type")) |value| {
        const trimmed = std.mem.trimEnd(u8, value, "\x00");
        return std.mem.eql(u8, trimmed, "memory");
    }

    return std.mem.startsWith(u8, node.name, "memory@") or
        std.mem.eql(u8, node.name, "memory");
}

fn parseReg(
    map: *MemoryMap,
    reg: []const u8,
    address_cells: u32,
    size_cells: u32,
) Error!void {
    const address_bytes: usize = @intCast(address_cells * 4);
    const size_bytes: usize = @intCast(size_cells * 4);
    const stride = address_bytes + size_bytes;

    if (reg.len == 0 or reg.len % stride != 0) return error.MalformedReg;

    var offset: usize = 0;
    while (offset < reg.len) : (offset += stride) {
        const start = readCells(reg[offset..][0..address_bytes], address_cells);
        const size = readCells(reg[offset + address_bytes ..][0..size_bytes], size_cells);

        if (size == 0) continue;

        const end = std.math.add(u64, start, size) catch return error.Overflow;
        // A one-cell address cannot describe memory beyond the 32-bit
        // address space.
        if (address_cells == 1 and end > (@as(u64, 1) << 32)) {
            return error.Overflow;
        }
        try insertRange(map, .{ .start = start, .size = size });
    }
}

fn readCells(bytes: []const u8, cells: u32) u64 {
    var value: u64 = 0;
    var i: u32 = 0;
    while (i < cells) : (i += 1) {
        const index: usize = @intCast(i);
        const cell = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .big);
        value = (value << 32) | cell;
    }
    return value;
}

fn insertRange(map: *MemoryMap, new_range: Range) Error!void {
    var start = new_range.start;
    var end = std.math.add(u64, new_range.start, new_range.size) catch return error.Overflow;

    var i: usize = 0;
    while (i < map.len) {
        const existing = map.ranges[i];
        const existing_end = std.math.add(u64, existing.start, existing.size) catch
            return error.Overflow;

        if (start <= existing_end and existing.start <= end) {
            start = @min(start, existing.start);
            end = @max(end, existing_end);

            var j = i;
            while (j + 1 < map.len) : (j += 1) {
                map.ranges[j] = map.ranges[j + 1];
            }
            map.len -= 1;
            i = 0;
        } else {
            i += 1;
        }
    }

    if (map.len == max_ranges) return error.TooManyRanges;
    map.ranges[map.len] = .{ .start = start, .size = end - start };
    map.len += 1;

    var k = map.len - 1;
    while (k > 0) : (k -= 1) {
        if (map.ranges[k - 1].start <= map.ranges[k].start) break;
        std.mem.swap(Range, &map.ranges[k - 1], &map.ranges[k]);
    }
}

test "parses and merges 64-bit memory ranges" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.propertyU32("#address-cells", 2);
    builder.propertyU32("#size-cells", 2);
    builder.memoryNode("memory@40000000", 2, 2, 0x4000_0000, 0x4000_0000);
    builder.memoryNode("memory@80000000", 2, 2, 0x8000_0000, 0x4000_0000);
    builder.endNode();

    const blob = builder.finish();
    const dtb: DTB = .{ .ptr = blob.ptr };
    const map = try parse(&dtb);

    try std.testing.expectEqual(@as(usize, 1), map.len);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), map.ranges[0].start);
    try std.testing.expectEqual(@as(u64, 0x8000_0000), map.ranges[0].size);
}

test "parses 32-bit cells and merges overlaps" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.propertyU32("#address-cells", 1);
    builder.propertyU32("#size-cells", 1);
    builder.memoryNode("memory@40000000", 1, 1, 0x4000_0000, 0x3000_0000);
    builder.memoryNode("memory@60000000", 1, 1, 0x6000_0000, 0x1000_0000);
    builder.endNode();

    const blob = builder.finish();
    const dtb: DTB = .{ .ptr = blob.ptr };
    const map = try parse(&dtb);

    try std.testing.expectEqual(@as(usize, 1), map.len);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), map.ranges[0].start);
    try std.testing.expectEqual(@as(u64, 0x3000_0000), map.ranges[0].size);
    try std.testing.expectEqual(@as(u64, 0x7000_0000), map.ranges[0].end());
}

test "keeps disjoint memory ranges separate" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.propertyU32("#address-cells", 2);
    builder.propertyU32("#size-cells", 2);
    builder.memoryNode("memory@40000000", 2, 2, 0x4000_0000, 0x4000_0000);
    builder.memoryNode("memory@100000000", 2, 2, 0x1_0000_0000, 0x4000_0000);
    builder.endNode();

    const blob = builder.finish();
    const dtb: DTB = .{ .ptr = blob.ptr };
    const map = try parse(&dtb);

    try std.testing.expectEqual(@as(usize, 2), map.len);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), map.ranges[0].start);
    try std.testing.expectEqual(@as(u64, 0x1_0000_0000), map.ranges[1].start);
}

test "accepts device_type memory with an arbitrary node name" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.propertyU32("#address-cells", 2);
    builder.propertyU32("#size-cells", 2);
    builder.memoryNode("ram", 2, 2, 0x4000_0000, 0x4000_0000);
    builder.endNode();

    const blob = builder.finish();
    const dtb: DTB = .{ .ptr = blob.ptr };
    const map = try parse(&dtb);

    try std.testing.expectEqual(@as(usize, 1), map.len);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), map.ranges[0].start);
}

test "rejects more ranges than the bounded map can hold" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.propertyU32("#address-cells", 2);
    builder.propertyU32("#size-cells", 2);

    var name_buffer: [32]u8 = undefined;
    for (0..max_ranges + 1) |i| {
        const start: u64 = 0x4000_0000 + @as(u64, @intCast(i)) * 0x10000;
        const name = try std.fmt.bufPrint(&name_buffer, "memory@{x}", .{start});
        builder.memoryNode(name, 2, 2, start, 0x1000);
    }
    builder.endNode();

    const blob = builder.finish();
    const dtb: DTB = .{ .ptr = blob.ptr };
    try std.testing.expectError(error.TooManyRanges, parse(&dtb));
}

test "rejects malformed and unsupported memory nodes" {
    const test_dtb = @import("test_dtb.zig");

    {
        var builder: test_dtb.Builder = .{};
        builder.beginNode("");
        builder.propertyU32("#address-cells", 2);
        builder.propertyU32("#size-cells", 2);
        builder.beginNode("memory@40000000");
        builder.property("device_type", "memory\x00");
        builder.property("reg", &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
        builder.endNode();
        builder.endNode();

        const blob = builder.finish();
        const dtb: DTB = .{ .ptr = blob.ptr };
        try std.testing.expectError(error.MalformedReg, parse(&dtb));
    }

    {
        var builder: test_dtb.Builder = .{};
        builder.beginNode("");
        builder.propertyU32("#address-cells", 3);
        builder.propertyU32("#size-cells", 2);
        builder.endNode();

        const blob = builder.finish();
        const dtb: DTB = .{ .ptr = blob.ptr };
        try std.testing.expectError(error.UnsupportedAddressCells, parse(&dtb));
    }

    {
        var builder: test_dtb.Builder = .{};
        builder.beginNode("");
        builder.propertyU32("#address-cells", 1);
        builder.propertyU32("#size-cells", 1);
        builder.memoryNode("memory@40000000", 1, 1, 0xffff_ffff, 2);
        builder.endNode();

        const blob = builder.finish();
        const dtb: DTB = .{ .ptr = blob.ptr };
        try std.testing.expectError(error.Overflow, parse(&dtb));
    }

    {
        var builder: test_dtb.Builder = .{};
        builder.beginNode("");
        builder.endNode();

        const blob = builder.finish();
        const dtb: DTB = .{ .ptr = blob.ptr };
        try std.testing.expectError(error.NoMemoryNodes, parse(&dtb));
    }
}
