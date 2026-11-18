const std = @import("std");

pub const page_size: u64 = 4096;
pub const block_size: u64 = 2 * 1024 * 1024;
pub const table_entries: usize = 512;
pub const max_virtual_address: u64 = 1 << 48;

pub const Table = [table_entries]u64;

pub const bits = struct {
    pub const valid: u64 = 1 << 0;
    pub const desc_type_mask: u64 = 0b11;
    pub const block: u64 = 0b01;
    pub const table_or_page: u64 = 0b11;
    pub const attr_index_shift: u6 = 2;
    pub const attr_index_mask: u64 = 0b111 << attr_index_shift;
    pub const ap_ro: u64 = 1 << 7;
    pub const sh_mask: u64 = 0b11 << 8;
    pub const sh_inner: u64 = 0b11 << 8;
    pub const af: u64 = 1 << 10;
    pub const pxn: u64 = 1 << 53;
    pub const uxn: u64 = 1 << 54;
};

/// Physical address bits used by page and table descriptors.
pub const address_mask: u64 = ((@as(u64, 1) << 48) - 1) & ~(page_size - 1);
const block_address_mask: u64 = ((@as(u64, 1) << 48) - 1) & ~(block_size - 1);

pub const Attributes = struct {
    kind: Kind = .normal,
    read_only: bool = false,
    executable: bool = false,
    shareable: bool = true,

    pub const Kind = enum {
        normal,
        device,
    };
};

const attr_normal: u64 = 0;
const attr_device: u64 = 1;

pub const Error = error{
    OutOfMemory,
    InvalidAddress,
    UnalignedRange,
    Conflict,
};

pub const Translation = struct {
    descriptor: u64,
    level: u2,
};

pub fn isBlock(descriptor: u64) bool {
    return descriptor & bits.desc_type_mask == bits.block;
}

pub fn isTableOrPage(descriptor: u64) bool {
    return descriptor & bits.desc_type_mask == bits.table_or_page;
}

pub fn attributeIndex(descriptor: u64) u3 {
    return @intCast((descriptor & bits.attr_index_mask) >> bits.attr_index_shift);
}

pub fn isReadOnly(descriptor: u64) bool {
    return descriptor & bits.ap_ro != 0;
}

pub fn isEl1Executable(descriptor: u64) bool {
    return descriptor & bits.pxn == 0;
}

pub fn isUserExecutable(descriptor: u64) bool {
    return descriptor & bits.uxn == 0;
}

fn descriptorAttributes(attrs: Attributes) Error!u64 {
    var value: u64 = bits.af;

    if (attrs.read_only) value |= bits.ap_ro;

    switch (attrs.kind) {
        .normal => {
            if (attrs.shareable) value |= bits.sh_inner;
            value |= @as(u64, attr_normal) << bits.attr_index_shift;
        },
        .device => {
            if (attrs.executable) return error.InvalidAddress;
            value |= @as(u64, attr_device) << bits.attr_index_shift;
        },
    }

    if (attrs.executable) {
        // EL1 may execute; user execution is still disabled.
        value |= bits.uxn;
    } else {
        value |= bits.pxn | bits.uxn;
    }
    return value;
}

fn tableDescriptor(table: *const Table) u64 {
    return (@intFromPtr(table) & address_mask) | bits.table_or_page;
}

fn tableFromDescriptor(descriptor: u64) *Table {
    return @ptrFromInt(@as(usize, @intCast(descriptor & address_mask)));
}

fn index(address: u64, shift: u6) usize {
    return @intCast((address >> shift) & (table_entries - 1));
}

fn checkedEnd(start: u64, size: u64) Error!u64 {
    const end = std.math.add(u64, start, size) catch return error.InvalidAddress;
    if (end > max_virtual_address) return error.InvalidAddress;
    return end;
}

pub const Builder = struct {
    pool: []Table,
    used: usize,
    root: *Table,

    pub fn init(pool: []Table) Error!Builder {
        if (pool.len == 0) return error.OutOfMemory;
        const root = &pool[0];
        @memset(root, 0);
        return .{
            .pool = pool,
            .used = 1,
            .root = root,
        };
    }

    pub fn tablesUsed(self: *const Builder) usize {
        return self.used;
    }

    fn allocTable(self: *Builder) Error!*Table {
        if (self.used >= self.pool.len) return error.OutOfMemory;
        const table = &self.pool[self.used];
        self.used += 1;
        @memset(table, 0);
        return table;
    }

    fn ensureChild(self: *Builder, table: *Table, entry_index: usize) Error!*Table {
        const descriptor = table[entry_index];
        if (descriptor & bits.valid == 0) {
            const child = try self.allocTable();
            table[entry_index] = tableDescriptor(child);
            return child;
        }
        if (isTableOrPage(descriptor)) return tableFromDescriptor(descriptor);
        return error.Conflict;
    }

    fn l2Table(self: *Builder, address: u64) Error!*Table {
        const l1 = try self.ensureChild(self.root, index(address, 39));
        return try self.ensureChild(l1, index(address, 30));
    }

    fn l3Table(self: *Builder, address: u64) Error!*Table {
        const l2 = try self.l2Table(address);
        const entry_index = index(address, 21);
        const descriptor = l2[entry_index];

        if (descriptor & bits.valid == 0) {
            const l3 = try self.allocTable();
            l2[entry_index] = tableDescriptor(l3);
            return l3;
        }

        if (isTableOrPage(descriptor)) return tableFromDescriptor(descriptor);

        if (isBlock(descriptor)) {
            const l3 = try self.allocTable();
            const base = descriptor & block_address_mask;
            const reusable = descriptor & ~address_mask;
            for (0..table_entries) |i| {
                const page = base + @as(u64, @intCast(i)) * page_size;
                l3[i] = reusable | (page & address_mask) | bits.table_or_page;
            }
            l2[entry_index] = tableDescriptor(l3);
            return l3;
        }

        return error.Conflict;
    }

    pub fn mapBlock(self: *Builder, address: u64, attrs: Attributes) Error!void {
        if (address % block_size != 0) return error.UnalignedRange;
        if (address >= max_virtual_address) return error.InvalidAddress;

        const attrs_bits = try descriptorAttributes(attrs);
        const l2 = try self.l2Table(address);
        const entry_index = index(address, 21);
        const descriptor = l2[entry_index];

        if (descriptor & bits.valid != 0 and !isBlock(descriptor)) {
            return error.Conflict;
        }

        l2[entry_index] = (address & block_address_mask) | attrs_bits | bits.block;
    }

    pub fn mapPage(self: *Builder, address: u64, attrs: Attributes) Error!void {
        if (address % page_size != 0) return error.UnalignedRange;
        if (address >= max_virtual_address) return error.InvalidAddress;

        const attrs_bits = try descriptorAttributes(attrs);
        const l3 = try self.l3Table(address);
        l3[index(address, 12)] = (address & address_mask) | attrs_bits | bits.table_or_page;
    }

    /// Maps a page-aligned range, using 2 MiB blocks where possible.
    pub fn mapRange(self: *Builder, start: u64, size: u64, attrs: Attributes) Error!void {
        if (size == 0) return;

        const end = try checkedEnd(start, size);
        if (start % page_size != 0 or end % page_size != 0) {
            return error.UnalignedRange;
        }

        var address = start;
        while (address < end) {
            if (address % block_size == 0 and end - address >= block_size) {
                try self.mapBlock(address, attrs);
                address += block_size;
            } else {
                try self.mapPage(address, attrs);
                address += page_size;
            }
        }
    }

    pub fn translate(self: *const Builder, address: u64) ?Translation {
        if (address >= max_virtual_address) return null;

        var table = self.root;

        const l0_descriptor = table[index(address, 39)];
        if (!isTableOrPage(l0_descriptor)) return null;
        table = tableFromDescriptor(l0_descriptor);

        const l1_descriptor = table[index(address, 30)];
        if (!isTableOrPage(l1_descriptor)) return null;
        table = tableFromDescriptor(l1_descriptor);

        const l2_descriptor = table[index(address, 21)];
        if (isBlock(l2_descriptor)) {
            return .{ .descriptor = l2_descriptor, .level = 2 };
        }
        if (!isTableOrPage(l2_descriptor)) return null;
        table = tableFromDescriptor(l2_descriptor);

        const l3_descriptor = table[index(address, 12)];
        if (!isTableOrPage(l3_descriptor)) return null;
        return .{ .descriptor = l3_descriptor, .level = 3 };
    }
};

test "maps blocks and translates them" {
    var pool: [8]Table align(page_size) = undefined;
    var builder = try Builder.init(pool[0..]);

    try builder.mapRange(0x4000_0000, 4 * block_size, .{});

    const translation = builder.translate(0x403f_f000) orelse return error.TestExpectedMapping;
    try std.testing.expectEqual(@as(u2, 2), translation.level);
    try std.testing.expect(isBlock(translation.descriptor));
    try std.testing.expect(translation.descriptor & bits.af != 0);
    try std.testing.expect(!isReadOnly(translation.descriptor));
    try std.testing.expect(!isEl1Executable(translation.descriptor));
    try std.testing.expect(!isUserExecutable(translation.descriptor));
    try std.testing.expectEqual(@as(u3, 0), attributeIndex(translation.descriptor));
    try std.testing.expect(translation.descriptor & bits.sh_inner != 0);

    try std.testing.expect(builder.translate(0x4080_0000) == null);
}

test "splits a block when mapping pages" {
    var pool: [8]Table align(page_size) = undefined;
    var builder = try Builder.init(pool[0..]);

    try builder.mapRange(0x4000_0000, 2 * block_size, .{});
    const before = builder.tablesUsed();

    try builder.mapRange(0x4000_0000, page_size, .{
        .read_only = true,
        .executable = true,
    });

    try std.testing.expectEqual(before + 1, builder.tablesUsed());

    const text = builder.translate(0x4000_0000) orelse return error.TestExpectedMapping;
    try std.testing.expectEqual(@as(u2, 3), text.level);
    try std.testing.expect(isReadOnly(text.descriptor));
    try std.testing.expect(isEl1Executable(text.descriptor));
    try std.testing.expect(!isUserExecutable(text.descriptor));

    const neighbour = builder.translate(0x4000_1000) orelse return error.TestExpectedMapping;
    try std.testing.expectEqual(@as(u2, 3), neighbour.level);
    try std.testing.expect(!isReadOnly(neighbour.descriptor));
    try std.testing.expect(!isEl1Executable(neighbour.descriptor));

    const second_block = builder.translate(0x4020_0000) orelse return error.TestExpectedMapping;
    try std.testing.expectEqual(@as(u2, 2), second_block.level);
}

test "maps device memory with device attributes" {
    var pool: [8]Table align(page_size) = undefined;
    var builder = try Builder.init(pool[0..]);

    try builder.mapRange(0x0800_0000, 0x0200_0000, .{ .kind = .device });

    const translation = builder.translate(0x0900_0000) orelse return error.TestExpectedMapping;
    try std.testing.expectEqual(@as(u2, 2), translation.level);
    try std.testing.expectEqual(@as(u3, 1), attributeIndex(translation.descriptor));
    try std.testing.expect(translation.descriptor & bits.sh_mask == 0);
    try std.testing.expect(!isEl1Executable(translation.descriptor));
    try std.testing.expect(!isUserExecutable(translation.descriptor));
}

test "rejects invalid ranges and reports exhaustion" {
    var pool: [8]Table align(page_size) = undefined;
    var builder = try Builder.init(pool[0..]);

    try std.testing.expectError(error.UnalignedRange, builder.mapRange(0x4000_1001, block_size, .{}));
    try std.testing.expectError(error.InvalidAddress, builder.mapRange(max_virtual_address, page_size, .{}));

    var tiny: [1]Table align(page_size) = undefined;
    var tiny_builder = try Builder.init(tiny[0..]);
    try std.testing.expectError(error.OutOfMemory, tiny_builder.mapRange(0x4000_0000, block_size, .{}));
}
