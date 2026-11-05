const DTB = @This();

const VERSION: u32 = 17;
const LAST_COMPAT: u32 = 16;

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

pub fn validate(dtb: *const @This()) bool {
    return dtb.header(.magic) == 0xd00dfeed and
        dtb.header(.last_comp_version) >= LAST_COMPAT;
}

pub const NodeRef = struct {
    offset: u32,
};

pub fn findNode(dtb: *const @This(), path: []const u8) ?NodeRef {
    var iter = dtb.struct_tokens();
    var path_iter = mem.splitScalar(u8, path, '/');
    _ = path_iter.next();

    var current_level_target_node = path_iter.next().?;
    var skip_depth: u32 = 0;

    while (true) {
        const cursor_usize = @intFromPtr(iter.cursor);
        const cursor: u32 = @intCast(cursor_usize);
        const offset = cursor - dtb.header(.off_dt_struct);
        const token = iter.next();

        switch (token) {
            .nop => {},
            .end => {
                return null;
            },
            .begin_node => {
                const name = iter.node_name();
                if (skip_depth != 0) {
                    skip_depth += 1;
                }
                if (mem.eql(u8, name, current_level_target_node)) {
                    if (path_iter.next()) |child_target| {
                        current_level_target_node = child_target;
                    } else {
                        return .{ .offset = offset };
                    }
                } else {
                    skip_depth += 1;
                }
            },
            .end_node => {
                if (skip_depth == 0) {
                    return null;
                } else {
                    skip_depth -= 1;
                }
            },
            .prop => {
                _ = iter.prop_meta();
            },
        }
    }
}

pub fn getProperty(dtb: *const DTB, node: NodeRef, property: []const u8) ?[]const u8 {
    var iter: Token.Iterator = .{
        .cursor = @ptrFromInt(dtb.header(.off_dt_struct) + node.offset),
    };
    const token1 = iter.next();
    std.debug.assert(token1 == .begin_node);
    _ = iter.node_name();

    var skip_depth: u32 = 0;

    while (true) {
        const token = iter.next();

        switch (token) {
            .nop => {},
            .end => {
                return null;
            },
            .begin_node => {
                skip_depth += 1;
            },
            .end_node => {
                if (skip_depth == 0) {
                    return null;
                } else {
                    skip_depth -= 1;
                }
            },
            .prop => {
                const meta = iter.prop_meta();
                if (skip_depth != 0) continue;
                const name = dtb.string(meta.name_offset);
                if (mem.eql(u8, name, property)) {
                    return meta.value;
                }
            },
        }
    }
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
        cursor: [*]u32,

        pub fn advance_u32(iter: *Iterator) void {
            iter.cursor += 1;
        }

        pub fn read_u32(iter: *Iterator) u32 {
            const value = iter.cursor[0];
            iter.cursor += 1;
            return std.mem.bigToNative(u32, value);
        }

        pub fn next(iter: *Iterator) Kind {
            const value = iter.read_u32();
            return @fromBackingInt(value);
        }

        pub fn node_name(iter: *Iterator) []const u8 {
            const name: [*]const u8 = @ptrCast(iter.cursor);
            var len: usize = 0;
            while (name[len] != 0) {
                len += 1;
            }
            iter.cursor = @ptrFromInt(mem.alignForward(usize, @intFromPtr(name) + len + 1, 4));
            return name[0..len];
        }

        pub fn prop_meta(iter: *Iterator) PropMeta {
            const len: usize = @intCast(iter.read_u32());
            const name_offset = iter.read_u32();

            const value_ptr: [*]u8 = @ptrCast(iter.cursor);
            const value = value_ptr[0..len];

            iter.cursor = @ptrFromInt(mem.alignForward(usize, @intFromPtr(value_ptr + len), 4));

            return .{
                .value = value,
                .name_offset = name_offset,
            };
        }
    };
};

pub fn struct_tokens(dtb: *const @This()) Token.Iterator {
    return .{
        .cursor = @ptrFromInt(@intFromPtr(dtb.ptr) + dtb.header(.off_dt_struct)),
    };
}

pub fn string(dtb: *const @This(), offset: u32) [:0]const u8 {
    const total_offset: usize = @intCast(dtb.header(.off_dt_strings) + offset);
    return mem.sliceTo(dtb.ptr + total_offset, 0);
}

pub const ReserveEntry = struct {
    address: u64,
    size: u64,
};
