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

pub const ReserveEntry = struct {
    address: u64,
    size: u64,
};
