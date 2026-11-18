const DTB = @This();

const VERSION: u32 = 17;
const LAST_COMPAT: u32 = 16;
const header_size: u32 = 40;
const max_dtb_size: u32 = 16 * 1024 * 1024;

const std = @import("std");
const mem = std.mem;

ptr: [*]const u8,

pub const HeaderField = enum(u4) {
    magic = 0,
    totalsize = 1,
    off_dt_struct = 2,
    off_dt_strings = 3,
    off_mem_rsvmap = 4,
    version = 5,
    last_comp_version = 6,
    boot_cpuid_phys = 7,
    size_dt_strings = 8,
    size_dt_struct = 9,
};

pub fn header(dtb: *const @This(), comptime field: HeaderField) u32 {
    const backing: usize = @intCast(@backingInt(field));
    const ptr: [*]const u8 = @ptrFromInt(@intFromPtr(dtb.ptr) + backing * @sizeOf(u32));
    return mem.readInt(u32, ptr[0..4], .big);
}

fn rangeWithin(offset: u32, size: u32, total: u32) bool {
    const end = @as(u64, offset) + @as(u64, size);
    return end <= total;
}

fn rangesOverlap(a_offset: u32, a_size: u32, b_offset: u32, b_size: u32) bool {
    const a_end = @as(u64, a_offset) + @as(u64, a_size);
    const b_end = @as(u64, b_offset) + @as(u64, b_size);
    return a_offset < b_end and b_offset < a_end;
}

pub fn validate(dtb: *const @This()) bool {
    return dtb.validateInternal() catch false;
}

fn validateInternal(dtb: *const @This()) error{MalformedDTB}!bool {
    if (dtb.header(.magic) != 0xd00dfeed) return false;

    const total_size = dtb.header(.totalsize);
    if (total_size < header_size or total_size > max_dtb_size) return false;

    const version = dtb.header(.version);
    const last_compat = dtb.header(.last_comp_version);
    if (version < LAST_COMPAT) return false;
    if (last_compat < LAST_COMPAT or last_compat > VERSION) return false;

    const struct_offset = dtb.header(.off_dt_struct);
    const struct_size = dtb.header(.size_dt_struct);
    const strings_offset = dtb.header(.off_dt_strings);
    const strings_size = dtb.header(.size_dt_strings);
    const reserve_offset = dtb.header(.off_mem_rsvmap);

    if (struct_offset < header_size or struct_offset % 4 != 0) return false;
    if (strings_offset < header_size) return false;
    if (reserve_offset < header_size or reserve_offset % 8 != 0) return false;

    if (!rangeWithin(struct_offset, struct_size, total_size)) return false;
    if (!rangeWithin(strings_offset, strings_size, total_size)) return false;
    if (!rangeWithin(reserve_offset, 16, total_size)) return false;

    if (struct_size < 8 or struct_size % 4 != 0) return false;
    if (rangesOverlap(struct_offset, struct_size, strings_offset, strings_size)) return false;
    if (rangesOverlap(reserve_offset, 16, struct_offset, struct_size)) return false;
    if (rangesOverlap(reserve_offset, 16, strings_offset, strings_size)) return false;

    var iter = dtb.struct_tokens();
    var depth: u32 = 0;
    var root_count: u32 = 0;

    while (true) {
        const kind = try iter.next();
        switch (kind) {
            .nop => {},
            .begin_node => {
                _ = try iter.node_name();
                if (depth == 0) root_count += 1;
                depth += 1;
            },
            .end_node => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .prop => {
                if (depth == 0) return false;
                const meta = try iter.prop_meta();
                if (dtb.string(meta.name_offset) == null) return false;
            },
            .end => {
                return depth == 0 and root_count == 1;
            },
        }
    }
}

pub const NodeRef = struct {
    offset: u32,
};

pub fn findNode(dtb: *const @This(), path: []const u8) ?NodeRef {
    if (path.len == 0 or path[0] != '/') return null;
    if (path.len == 1) return .{ .offset = 0 };

    var iter = dtb.struct_tokens();

    // Skip the root node, which is not a path component.
    while (true) {
        const kind = iter.next() catch return null;
        switch (kind) {
            .nop => {},
            .begin_node => {
                _ = iter.node_name() catch return null;
                break;
            },
            else => return null,
        }
    }

    var path_iter = mem.splitScalar(u8, path[1..], '/');
    var current_level_target_node = path_iter.next() orelse return null;
    if (current_level_target_node.len == 0) return null;

    var skip_depth: u32 = 0;

    while (true) {
        const offset = iter.currentOffset();
        const kind = iter.next() catch return null;

        switch (kind) {
            .nop => {},
            .end => return null,
            .begin_node => {
                const name = iter.node_name() catch return null;
                if (skip_depth != 0) {
                    skip_depth += 1;
                } else if (mem.eql(u8, name, current_level_target_node)) {
                    if (path_iter.next()) |child_target| {
                        if (child_target.len == 0) return null;
                        current_level_target_node = child_target;
                    } else {
                        return .{ .offset = offset };
                    }
                } else {
                    // Ignore the whole subtree: a nested node must not be
                    // mistaken for the target (e.g. /a/c/b when looking for
                    // /a/b).
                    skip_depth += 1;
                }
            },
            .end_node => {
                if (skip_depth == 0) return null;
                skip_depth -= 1;
            },
            .prop => {
                _ = iter.prop_meta() catch return null;
            },
        }
    }
}

pub fn getProperty(dtb: *const DTB, node: NodeRef, property: []const u8) ?[]const u8 {
    var iter = dtb.tokensAt(node) orelse return null;

    const kind = iter.next() catch return null;
    if (kind != .begin_node) return null;
    _ = iter.node_name() catch return null;

    var skip_depth: u32 = 0;

    while (true) {
        const token = iter.next() catch return null;

        switch (token) {
            .nop => {},
            .end => return null,
            .begin_node => {
                _ = iter.node_name() catch return null;
                skip_depth += 1;
            },
            .end_node => {
                if (skip_depth == 0) return null;
                skip_depth -= 1;
            },
            .prop => {
                const meta = iter.prop_meta() catch return null;
                if (skip_depth != 0) continue;
                const name = dtb.string(meta.name_offset) orelse return null;
                if (mem.eql(u8, name, property)) return meta.value;
            },
        }
    }
}

pub fn getU32Property(dtb: *const DTB, node: NodeRef, property: []const u8) ?u32 {
    const value = dtb.getProperty(node, property) orelse return null;
    if (value.len != 4) return null;
    return mem.readInt(u32, value[0..4], .big);
}

pub const Token = struct {
    pub const Kind = enum(u32) {
        begin_node = 1,
        end_node = 2,
        prop = 3,
        nop = 4,
        end = 9,
    };

    pub const PropMeta = struct {
        value: []const u8,
        name_offset: u32,
    };

    pub const Iterator = struct {
        cursor: [*]const u8,
        start: [*]const u8,
        end: [*]const u8,

        pub fn currentOffset(iter: *const Iterator) u32 {
            return @intCast(@intFromPtr(iter.cursor) - @intFromPtr(iter.start));
        }

        fn remaining(iter: *const Iterator) usize {
            return @intFromPtr(iter.end) - @intFromPtr(iter.cursor);
        }

        fn readU32(iter: *Iterator) error{MalformedDTB}!u32 {
            if (iter.remaining() < 4) return error.MalformedDTB;
            const value = mem.readInt(u32, iter.cursor[0..4], .big);
            iter.cursor += 4;
            return value;
        }

        pub fn next(iter: *Iterator) error{MalformedDTB}!Kind {
            const value = try iter.readU32();
            return std.enums.fromInt(Kind, value) orelse return error.MalformedDTB;
        }

        pub fn node_name(iter: *Iterator) error{MalformedDTB}![]const u8 {
            const length = mem.indexOfScalar(u8, iter.cursor[0..iter.remaining()], 0) orelse
                return error.MalformedDTB;
            const name = iter.cursor[0..length];

            const next_address = mem.alignForward(
                usize,
                @intFromPtr(iter.cursor) + length + 1,
                4,
            );
            if (next_address > @intFromPtr(iter.end)) return error.MalformedDTB;
            iter.cursor = @ptrFromInt(next_address);
            return name;
        }

        pub fn prop_meta(iter: *Iterator) error{MalformedDTB}!PropMeta {
            const length = try iter.readU32();
            const name_offset = try iter.readU32();

            if (iter.remaining() < length) return error.MalformedDTB;
            const value = iter.cursor[0..length];

            const next_address = mem.alignForward(
                usize,
                @intFromPtr(iter.cursor) + length,
                4,
            );
            if (next_address > @intFromPtr(iter.end)) return error.MalformedDTB;
            iter.cursor = @ptrFromInt(next_address);

            return .{
                .value = value,
                .name_offset = name_offset,
            };
        }
    };
};

pub fn struct_tokens(dtb: *const @This()) Token.Iterator {
    const offset = dtb.header(.off_dt_struct);
    const size = dtb.header(.size_dt_struct);
    const start: [*]const u8 = @ptrFromInt(@intFromPtr(dtb.ptr) + offset);
    return .{
        .cursor = start,
        .start = start,
        .end = start + size,
    };
}

fn tokensAt(dtb: *const @This(), node: NodeRef) ?Token.Iterator {
    if (node.offset >= dtb.header(.size_dt_struct)) return null;
    var iter = dtb.struct_tokens();
    iter.cursor = @ptrFromInt(@intFromPtr(iter.start) + node.offset);
    return iter;
}

pub const NodeIterator = struct {
    tokens: Token.Iterator,
    depth: u32 = 0,
    finished: bool = false,

    pub const Entry = struct {
        node: NodeRef,
        name: []const u8,
    };

    pub fn next(self: *NodeIterator) error{MalformedDTB}!?Entry {
        while (!self.finished) {
            const offset = self.tokens.currentOffset();
            const kind = try self.tokens.next();

            switch (kind) {
                .nop => {},
                .begin_node => {
                    const name = try self.tokens.node_name();
                    self.depth += 1;
                    if (self.depth == 2) {
                        return .{
                            .node = .{ .offset = offset },
                            .name = name,
                        };
                    }
                },
                .end_node => {
                    if (self.depth == 0) return error.MalformedDTB;
                    self.depth -= 1;
                    if (self.depth == 0) self.finished = true;
                },
                .prop => {
                    _ = try self.tokens.prop_meta();
                },
                .end => {
                    if (self.depth != 0) return error.MalformedDTB;
                    self.finished = true;
                },
            }
        }
        return null;
    }
};

pub fn rootChildren(dtb: *const @This()) NodeIterator {
    return .{ .tokens = dtb.struct_tokens() };
}

pub fn string(dtb: *const @This(), offset: u32) ?[:0]const u8 {
    const strings_offset = dtb.header(.off_dt_strings);
    const strings_size = dtb.header(.size_dt_strings);
    if (offset >= strings_size) return null;

    const remaining = strings_size - offset;
    const start: [*]const u8 = @ptrFromInt(
        @intFromPtr(dtb.ptr) + strings_offset + offset,
    );
    const length = mem.indexOfScalar(u8, start[0..remaining], 0) orelse return null;
    return start[0..length :0];
}

pub const ReserveEntry = struct {
    address: u64,
    size: u64,
};

test "findNode ignores matching names in skipped subtrees" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.beginNode("a");
    builder.beginNode("c");
    builder.beginNode("b");
    builder.property("kind", "nested");
    builder.endNode();
    builder.endNode();
    builder.beginNode("b");
    builder.property("kind", "direct");
    builder.endNode();
    builder.endNode();
    builder.beginNode("b");
    builder.property("kind", "root");
    builder.endNode();
    builder.endNode();
    const blob = builder.finish();

    const dtb: DTB = .{ .ptr = blob.ptr };
    try std.testing.expect(dtb.validate());

    const direct = dtb.findNode("/a/b") orelse return error.TestExpectedNode;
    const direct_kind = dtb.getProperty(direct, "kind") orelse return error.TestExpectedProperty;
    try std.testing.expectEqualSlices(u8, "direct", direct_kind);

    const nested = dtb.findNode("/a/c/b") orelse return error.TestExpectedNode;
    const nested_kind = dtb.getProperty(nested, "kind") orelse return error.TestExpectedProperty;
    try std.testing.expectEqualSlices(u8, "nested", nested_kind);

    try std.testing.expect(dtb.findNode("/a/missing") == null);
    try std.testing.expect(dtb.findNode("/missing") == null);
}

test "findNode handles root and invalid paths" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.beginNode("a");
    builder.endNode();
    builder.endNode();
    const blob = builder.finish();

    const dtb: DTB = .{ .ptr = blob.ptr };

    const root = dtb.findNode("/") orelse return error.TestExpectedNode;
    try std.testing.expectEqual(@as(u32, 0), root.offset);

    try std.testing.expect(dtb.findNode("") == null);
    try std.testing.expect(dtb.findNode("a/b") == null);
    try std.testing.expect(dtb.findNode("/a/") == null);
}

test "rootChildren only visits direct children" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.beginNode("a");
    builder.beginNode("nested");
    builder.endNode();
    builder.endNode();
    builder.beginNode("b");
    builder.property("kind", "root");
    builder.endNode();
    builder.endNode();
    const blob = builder.finish();

    const dtb: DTB = .{ .ptr = blob.ptr };
    try std.testing.expect(dtb.validate());

    var children = dtb.rootChildren();

    const first = (try children.next()) orelse return error.TestExpectedNode;
    try std.testing.expectEqualStrings("a", first.name);

    const second = (try children.next()) orelse return error.TestExpectedNode;
    try std.testing.expectEqualStrings("b", second.name);
    const kind = dtb.getProperty(second.node, "kind") orelse return error.TestExpectedProperty;
    try std.testing.expectEqualSlices(u8, "root", kind);

    try std.testing.expect((try children.next()) == null);
}

test "validate rejects malformed DTBs" {
    const test_dtb = @import("test_dtb.zig");

    var builder: test_dtb.Builder = .{};
    builder.beginNode("");
    builder.propertyU32("#address-cells", 2);
    builder.beginNode("node");
    builder.property("name", "value");
    builder.endNode();
    builder.endNode();
    const blob = builder.finish();

    const dtb: DTB = .{ .ptr = blob.ptr };
    try std.testing.expect(dtb.validate());

    std.mem.writeInt(u32, blob[0..4], 0xdeadbeef, .big);
    try std.testing.expect(!dtb.validate());
    std.mem.writeInt(u32, blob[0..4], 0xd00dfeed, .big);

    std.mem.writeInt(u32, blob[24..28], 15, .big);
    try std.testing.expect(!dtb.validate());
    std.mem.writeInt(u32, blob[24..28], 16, .big);

    std.mem.writeInt(u32, blob[4..8], 39, .big);
    try std.testing.expect(!dtb.validate());
    std.mem.writeInt(u32, blob[4..8], @intCast(blob.len), .big);

    std.mem.writeInt(u32, blob[8..12], 0, .big);
    try std.testing.expect(!dtb.validate());
    std.mem.writeInt(u32, blob[8..12], 56, .big);

    std.mem.writeInt(u32, blob[36..40], 4, .big);
    try std.testing.expect(!dtb.validate());
    std.mem.writeInt(u32, blob[36..40], @intCast(builder.struct_len), .big);

    const length_position = builder.lastPropertyLengthPosition();
    std.mem.writeInt(u32, blob[length_position..][0..4], 0xffff, .big);
    try std.testing.expect(!dtb.validate());
    std.mem.writeInt(u32, blob[length_position..][0..4], 5, .big);

    const name_position = builder.lastPropertyNamePosition();
    std.mem.writeInt(u32, blob[name_position..][0..4], 0xffff, .big);
    try std.testing.expect(!dtb.validate());
}
