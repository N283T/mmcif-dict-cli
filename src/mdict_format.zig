const std = @import("std");

pub const magic: [8]u8 = .{ 'M', 'D', 'I', 'C', 'T', 0, 0, 0 };
pub const format_version: u32 = 1;
pub const endian_mark: u32 = 0x04030201;

/// Offset + length into the string pool.
pub const StrRef = extern struct {
    offset: u32 = 0,
    len: u32 = 0,

    pub fn isEmpty(self: StrRef) bool {
        return self.len == 0;
    }
};

/// Offset + count into the StrRef array pool.
pub const StrArrayRef = extern struct {
    offset: u32 = 0,
    count: u32 = 0,
};

pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    endian_mark: u32,
    header_size: u32,
    reserved: u32,
    total_size: u64,
    categories_off: u64,
    categories_count: u32,
    _pad0: u32,
    items_off: u64,
    items_count: u32,
    _pad1: u32,
    relations_off: u64,
    relations_count: u32,
    _pad2: u32,
    str_array_off: u64,
    str_array_count: u32,
    _pad3: u32,
    string_pool_off: u64,
    string_pool_size: u64,
    reserved_tail: [16]u8, // room for future fields; zeroed by writer
};

comptime {
    std.debug.assert(@sizeOf(Header) == 128);
    std.debug.assert(@sizeOf(StrRef) == 8);
    std.debug.assert(@sizeOf(StrArrayRef) == 8);
}

pub const CategoryRecord = extern struct {
    id: StrRef,
    description: StrRef,
    mandatory_code: StrRef,
    key_names: StrArrayRef,
    group_ids: StrArrayRef,
    example_details: StrArrayRef,
    example_cases: StrArrayRef,
    items: StrArrayRef,
};

pub const ItemRecord = extern struct {
    name: StrRef,
    category_id: StrRef,
    description: StrRef,
    mandatory_code: StrRef,
    type_code: StrRef,
    enum_values: StrArrayRef,
};

pub const RelationRecord = extern struct {
    child_category_id: StrRef,
    parent_category_id: StrRef,
    child_name: StrRef,
    parent_name: StrRef,
    link_group_id: StrRef,
};

comptime {
    std.debug.assert(@sizeOf(CategoryRecord) == 64);
    std.debug.assert(@sizeOf(ItemRecord) == 48);
    std.debug.assert(@sizeOf(RelationRecord) == 40);
}

test "struct sizes match spec" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(CategoryRecord));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ItemRecord));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RelationRecord));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StrRef));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(StrArrayRef));
}

test "format constants" {
    try std.testing.expectEqualSlices(u8, "MDICT\x00\x00\x00", &magic);
    try std.testing.expectEqual(@as(u32, 1), format_version);
}
