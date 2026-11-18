const std = @import("std");
const DTB = @import("DTB.zig");

/// Small fixed-capacity builder used by host tests to construct DTBs.
pub const Builder = struct {
    pub const capacity = 4096;
    const header_size = 40;
    const reserve_size = 16;
    const struct_offset = header_size + reserve_size;
    const max_patches = 64;

    const Patch = struct {
        position: usize,
        name: []const u8,
    };

    blob: [capacity]u8 = @splat(0),
    struct_len: usize = 0,
    strings: [capacity]u8 = @splat(0),
    strings_len: usize = 0,
    patches: [max_patches]Patch = undefined,
    patch_count: usize = 0,
    ended: bool = false,

    fn putBe32(self: *Builder, position: usize, value: u32) void {
        std.mem.writeInt(u32, self.blob[position..][0..4], value, .big);
    }

    fn putBytes(self: *Builder, bytes: []const u8) void {
        const position = struct_offset + self.struct_len;
        std.debug.assert(position + bytes.len <= self.blob.len);
        @memcpy(self.blob[position..][0..bytes.len], bytes);
        self.struct_len += bytes.len;
    }

    fn putU32(self: *Builder, value: u32) void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, value, .big);
        self.putBytes(&buffer);
    }

    fn alignStruct(self: *Builder, alignment: usize) void {
        while (self.struct_len % alignment != 0) {
            self.putBytes(&.{0});
        }
    }

    fn putToken(self: *Builder, kind: DTB.Token.Kind) void {
        self.putU32(@backingInt(kind));
    }

    pub fn beginNode(self: *Builder, name: []const u8) void {
        self.putToken(.begin_node);
        self.putBytes(name);
        self.putBytes(&.{0});
        self.alignStruct(4);
    }

    pub fn endNode(self: *Builder) void {
        self.putToken(.end_node);
    }

    pub fn property(self: *Builder, name: []const u8, value: []const u8) void {
        std.debug.assert(self.patch_count < max_patches);

        self.putToken(.prop);
        self.putU32(@intCast(value.len));

        const patch_position = struct_offset + self.struct_len;
        self.putU32(0);

        self.putBytes(value);
        self.alignStruct(4);

        self.patches[self.patch_count] = .{
            .position = patch_position,
            .name = name,
        };
        self.patch_count += 1;
    }

    pub fn propertyU32(self: *Builder, name: []const u8, value: u32) void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, value, .big);
        self.property(name, &buffer);
    }

    pub fn memoryNode(
        self: *Builder,
        name: []const u8,
        address_cells: u32,
        size_cells: u32,
        start: u64,
        size: u64,
    ) void {
        std.debug.assert(address_cells == 1 or address_cells == 2);
        std.debug.assert(size_cells == 1 or size_cells == 2);

        var reg: [16]u8 = undefined;
        var offset: usize = 0;

        var address_shift: u32 = if (address_cells == 2) 32 else 0;
        while (true) {
            std.mem.writeInt(
                u32,
                reg[offset..][0..4],
                @intCast((start >> @intCast(address_shift)) & 0xffff_ffff),
                .big,
            );
            offset += 4;
            if (address_shift == 0) break;
            address_shift -= 32;
        }

        var size_shift: u32 = if (size_cells == 2) 32 else 0;
        while (true) {
            std.mem.writeInt(
                u32,
                reg[offset..][0..4],
                @intCast((size >> @intCast(size_shift)) & 0xffff_ffff),
                .big,
            );
            offset += 4;
            if (size_shift == 0) break;
            size_shift -= 32;
        }

        self.beginNode(name);
        self.property("device_type", "memory\x00");
        self.property("reg", reg[0..offset]);
        self.endNode();
    }

    pub fn lastPropertyNamePosition(self: *const Builder) usize {
        std.debug.assert(self.patch_count != 0);
        return self.patches[self.patch_count - 1].position;
    }

    pub fn lastPropertyLengthPosition(self: *const Builder) usize {
        return self.lastPropertyNamePosition() - 4;
    }

    fn intern(self: *Builder, name: []const u8) u32 {
        var offset: usize = 0;
        while (offset < self.strings_len) {
            const existing = std.mem.sliceTo(self.strings[offset..self.strings_len], 0);
            if (std.mem.eql(u8, existing, name)) return @intCast(offset);
            offset += existing.len + 1;
        }

        const new_offset = self.strings_len;
        @memcpy(self.strings[new_offset..][0..name.len], name);
        self.strings[new_offset + name.len] = 0;
        self.strings_len += name.len + 1;
        return @intCast(new_offset);
    }

    pub fn finish(self: *Builder) []u8 {
        if (!self.ended) {
            self.putToken(.end);
            self.ended = true;
        }

        for (self.patches[0..self.patch_count]) |patch| {
            self.putBe32(patch.position, self.intern(patch.name));
        }

        const strings_offset = struct_offset + self.struct_len;
        @memcpy(self.blob[strings_offset..][0..self.strings_len], self.strings[0..self.strings_len]);
        const total_size = strings_offset + self.strings_len;

        self.putBe32(0, 0xd00dfeed);
        self.putBe32(4, @intCast(total_size));
        self.putBe32(8, struct_offset);
        self.putBe32(12, @intCast(strings_offset));
        self.putBe32(16, header_size);
        self.putBe32(20, 17);
        self.putBe32(24, 16);
        self.putBe32(28, 0);
        self.putBe32(32, @intCast(self.strings_len));
        self.putBe32(36, @intCast(self.struct_len));

        return self.blob[0..total_size];
    }
};
