const std = @import("std");
const fmt = @import("mdict_format.zig");
const dic = @import("dic_loader.zig");
const Allocator = std.mem.Allocator;

pub const WriteError = error{ OutOfMemory, WriteFailed };

const StringInterner = struct {
    aa: Allocator,
    map: std.StringHashMap(fmt.StrRef),
    pool: std.ArrayList(u8),

    fn init(aa: Allocator) StringInterner {
        return .{ .aa = aa, .map = .init(aa), .pool = .empty };
    }

    fn intern(self: *StringInterner, s: []const u8) !fmt.StrRef {
        if (s.len == 0) return .{ .offset = 0, .len = 0 };
        if (self.map.get(s)) |ref| return ref;
        const off: u32 = @intCast(self.pool.items.len);
        try self.pool.appendSlice(self.aa, s);
        const ref: fmt.StrRef = .{ .offset = off, .len = @intCast(s.len) };
        try self.map.put(s, ref);
        return ref;
    }
};

test "StringInterner dedups identical strings" {
    const allocator = std.testing.allocator;
    var interner = StringInterner.init(allocator);
    defer {
        interner.map.deinit();
        interner.pool.deinit(allocator);
    }

    const a = try interner.intern("hello");
    const b = try interner.intern("hello");
    const c = try interner.intern("world");

    try std.testing.expectEqual(a.offset, b.offset);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(a.offset != c.offset);
    try std.testing.expectEqual(@as(usize, 10), interner.pool.items.len); // "helloworld"
}

test "StringInterner empty string returns null ref" {
    const allocator = std.testing.allocator;
    var interner = StringInterner.init(allocator);
    defer {
        interner.map.deinit();
        interner.pool.deinit(allocator);
    }
    const r = try interner.intern("");
    try std.testing.expectEqual(@as(u32, 0), r.offset);
    try std.testing.expectEqual(@as(u32, 0), r.len);
}

const ArrayInterner = struct {
    aa: Allocator,
    str_refs: std.ArrayList(fmt.StrRef),

    fn init(aa: Allocator) ArrayInterner {
        return .{ .aa = aa, .str_refs = .empty };
    }

    fn appendArray(self: *ArrayInterner, interner: *StringInterner, arr: []const []const u8) !fmt.StrArrayRef {
        if (arr.len == 0) return .{ .offset = 0, .count = 0 };
        const off: u32 = @intCast(self.str_refs.items.len);
        for (arr) |s| {
            const ref = try interner.intern(s);
            try self.str_refs.append(self.aa, ref);
        }
        return .{ .offset = off, .count = @intCast(arr.len) };
    }
};

fn lessCategoryById(_: void, a: dic.Category, b: dic.Category) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn lessItemByName(_: void, a: dic.Item, b: dic.Item) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn lessRelationByChildCat(_: void, a: dic.Relation, b: dic.Relation) bool {
    const c = std.mem.order(u8, a.child_category_id, b.child_category_id);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, a.child_name, b.child_name) == .lt;
}

/// Serialise a BuildDict to bytes. Caller owns the returned slice.
pub fn writeToBytes(gpa: Allocator, bd: *const dic.BuildDict) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    // Sort inputs
    const cats = try aa.dupe(dic.Category, bd.categories);
    std.mem.sort(dic.Category, cats, {}, lessCategoryById);
    const items = try aa.dupe(dic.Item, bd.items);
    std.mem.sort(dic.Item, items, {}, lessItemByName);
    const rels = try aa.dupe(dic.Relation, bd.relations);
    std.mem.sort(dic.Relation, rels, {}, lessRelationByChildCat);

    var interner = StringInterner.init(aa);
    var arr_interner = ArrayInterner.init(aa);

    // Leading null-byte so offset=0 means "empty" unambiguously
    try interner.pool.append(aa, 0);
    // And a dummy zero-length entry at offset 0 of str_array pool
    try arr_interner.str_refs.append(aa, .{});

    var cat_records = try aa.alloc(fmt.CategoryRecord, cats.len);
    for (cats, 0..) |c, i| {
        cat_records[i] = .{
            .id = try interner.intern(c.id),
            .description = try interner.intern(c.description),
            .mandatory_code = try interner.intern(c.mandatory_code),
            .key_names = try arr_interner.appendArray(&interner, c.key_names),
            .group_ids = try arr_interner.appendArray(&interner, c.group_ids),
            .example_details = try arr_interner.appendArray(&interner, c.example_details),
            .example_cases = try arr_interner.appendArray(&interner, c.example_cases),
            .items = try arr_interner.appendArray(&interner, c.items),
        };
    }

    var item_records = try aa.alloc(fmt.ItemRecord, items.len);
    for (items, 0..) |it, i| {
        item_records[i] = .{
            .name = try interner.intern(it.name),
            .category_id = try interner.intern(it.category_id),
            .description = try interner.intern(it.description),
            .mandatory_code = try interner.intern(it.mandatory_code),
            .type_code = try interner.intern(it.type_code),
            .enum_values = try arr_interner.appendArray(&interner, it.enum_values),
        };
    }

    var rel_records = try aa.alloc(fmt.RelationRecord, rels.len);
    for (rels, 0..) |r, i| {
        rel_records[i] = .{
            .child_category_id = try interner.intern(r.child_category_id),
            .parent_category_id = try interner.intern(r.parent_category_id),
            .child_name = try interner.intern(r.child_name),
            .parent_name = try interner.intern(r.parent_name),
            .link_group_id = try interner.intern(r.link_group_id),
        };
    }

    // Layout computation (header first, records, then str-array pool, then string pool)
    const header_size: u64 = @sizeOf(fmt.Header);
    const cat_bytes: u64 = @sizeOf(fmt.CategoryRecord) * cat_records.len;
    const item_bytes: u64 = @sizeOf(fmt.ItemRecord) * item_records.len;
    const rel_bytes: u64 = @sizeOf(fmt.RelationRecord) * rel_records.len;
    const sa_bytes: u64 = @sizeOf(fmt.StrRef) * arr_interner.str_refs.items.len;
    const sp_bytes: u64 = interner.pool.items.len;

    const cats_off: u64 = header_size;
    const items_off: u64 = cats_off + cat_bytes;
    const rels_off: u64 = items_off + item_bytes;
    const sa_off: u64 = rels_off + rel_bytes;
    const sp_off: u64 = sa_off + sa_bytes;
    const total: u64 = sp_off + sp_bytes;

    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);

    const header: fmt.Header = .{
        .magic = fmt.magic,
        .version = fmt.format_version,
        .endian_mark = fmt.endian_mark,
        .header_size = @sizeOf(fmt.Header),
        .reserved = 0,
        .total_size = total,
        .categories_off = cats_off,
        .categories_count = @intCast(cat_records.len),
        ._pad0 = 0,
        .items_off = items_off,
        .items_count = @intCast(item_records.len),
        ._pad1 = 0,
        .relations_off = rels_off,
        .relations_count = @intCast(rel_records.len),
        ._pad2 = 0,
        .str_array_off = sa_off,
        .str_array_count = @intCast(arr_interner.str_refs.items.len),
        ._pad3 = 0,
        .string_pool_off = sp_off,
        .string_pool_size = sp_bytes,
        .reserved_tail = @splat(0),
    };

    @memcpy(out[0..header_size], std.mem.asBytes(&header));
    @memcpy(out[cats_off..][0..cat_bytes], std.mem.sliceAsBytes(cat_records));
    @memcpy(out[items_off..][0..item_bytes], std.mem.sliceAsBytes(item_records));
    @memcpy(out[rels_off..][0..rel_bytes], std.mem.sliceAsBytes(rel_records));
    @memcpy(out[sa_off..][0..sa_bytes], std.mem.sliceAsBytes(arr_interner.str_refs.items));
    @memcpy(out[sp_off..][0..sp_bytes], interner.pool.items);

    return out;
}

pub fn writeToFile(gpa: Allocator, bd: *const dic.BuildDict, path: []const u8) !void {
    const bytes = try writeToBytes(gpa, bd);
    defer gpa.free(bytes);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

test "writeToBytes produces header with correct magic" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const bd: dic.BuildDict = .{
        .arena = arena,
        .categories = &.{},
        .items = &.{},
        .relations = &.{},
    };
    const bytes = try writeToBytes(allocator, &bd);
    defer allocator.free(bytes);

    try std.testing.expect(bytes.len >= @sizeOf(fmt.Header));
    const header = std.mem.bytesToValue(fmt.Header, bytes[0..@sizeOf(fmt.Header)]);
    try std.testing.expectEqualSlices(u8, &fmt.magic, &header.magic);
    try std.testing.expectEqual(fmt.format_version, header.version);
    try std.testing.expectEqual(fmt.endian_mark, header.endian_mark);
    try std.testing.expectEqual(@as(u64, bytes.len), header.total_size);
}

test "writeToBytes is deterministic" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cats = try aa.alloc(dic.Category, 3);
    cats[0] = .{ .id = "zeta", .description = "z", .mandatory_code = "no", .key_names = &.{}, .group_ids = &.{}, .example_details = &.{}, .example_cases = &.{}, .items = &.{} };
    cats[1] = .{ .id = "alpha", .description = "a", .mandatory_code = "no", .key_names = &.{}, .group_ids = &.{}, .example_details = &.{}, .example_cases = &.{}, .items = &.{} };
    cats[2] = .{ .id = "beta",  .description = "b", .mandatory_code = "no", .key_names = &.{}, .group_ids = &.{}, .example_details = &.{}, .example_cases = &.{}, .items = &.{} };

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const bd: dic.BuildDict = .{
        .arena = arena2,
        .categories = cats,
        .items = &.{},
        .relations = &.{},
    };

    const a = try writeToBytes(allocator, &bd);
    defer allocator.free(a);
    const b = try writeToBytes(allocator, &bd);
    defer allocator.free(b);

    try std.testing.expectEqualSlices(u8, a, b);
}
