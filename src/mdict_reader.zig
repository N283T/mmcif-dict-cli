const std = @import("std");
const fmt = @import("mdict_format.zig");
const Allocator = std.mem.Allocator;

pub const ReadError = error{
    InvalidMagic,
    UnsupportedVersion,
    WrongEndian,
    TruncatedHeader,
    SectionOutOfBounds,
};

pub const View = struct {
    buf: []const u8,
    header: *align(1) const fmt.Header,
    categories: []align(1) const fmt.CategoryRecord,
    items: []align(1) const fmt.ItemRecord,
    relations: []align(1) const fmt.RelationRecord,
    str_array_pool: []align(1) const fmt.StrRef,
    string_pool: []const u8,

    pub fn resolveStr(self: *const View, ref: fmt.StrRef) []const u8 {
        if (ref.len == 0) return "";
        return self.string_pool[ref.offset..][0..ref.len];
    }

    pub fn resolveStrArray(self: *const View, ref: fmt.StrArrayRef, out: [][]const u8) void {
        std.debug.assert(out.len == ref.count);
        const refs = self.str_array_pool[ref.offset..][0..ref.count];
        for (refs, 0..) |r, i| out[i] = self.resolveStr(r);
    }

    pub fn strArrayLen(self: *const View, ref: fmt.StrArrayRef) usize {
        _ = self;
        return ref.count;
    }

    pub fn strArrayAt(self: *const View, ref: fmt.StrArrayRef, index: usize) []const u8 {
        std.debug.assert(index < ref.count);
        return self.resolveStr(self.str_array_pool[ref.offset + index]);
    }
};

fn sectionEnd(off: u64, count: u64, elem_size: u64) ReadError!u64 {
    const bytes = std.math.mul(u64, count, elem_size) catch return error.SectionOutOfBounds;
    return std.math.add(u64, off, bytes) catch return error.SectionOutOfBounds;
}

fn validateStr(ref: fmt.StrRef, pool_size: u64) ReadError!void {
    if (ref.len == 0) return; // empty refs are always valid
    const end = std.math.add(u64, ref.offset, ref.len) catch return error.SectionOutOfBounds;
    if (end > pool_size) return error.SectionOutOfBounds;
}

fn validateStrArray(ref: fmt.StrArrayRef, pool_count: u64) ReadError!void {
    if (ref.count == 0) return;
    const end = std.math.add(u64, ref.offset, ref.count) catch return error.SectionOutOfBounds;
    if (end > pool_count) return error.SectionOutOfBounds;
}

pub fn load(buf: []const u8) ReadError!View {
    if (buf.len < @sizeOf(fmt.Header)) return error.TruncatedHeader;
    const header = std.mem.bytesAsValue(fmt.Header, buf[0..@sizeOf(fmt.Header)]);
    if (!std.mem.eql(u8, &header.magic, &fmt.magic)) return error.InvalidMagic;
    if (header.endian_mark != fmt.endian_mark) return error.WrongEndian;
    if (header.version != fmt.format_version) return error.UnsupportedVersion;

    const end = header.total_size;
    if (end > buf.len) return error.SectionOutOfBounds;

    const cat_end = try sectionEnd(header.categories_off, header.categories_count, @as(u64, @sizeOf(fmt.CategoryRecord)));
    const item_end = try sectionEnd(header.items_off, header.items_count, @as(u64, @sizeOf(fmt.ItemRecord)));
    const rel_end = try sectionEnd(header.relations_off, header.relations_count, @as(u64, @sizeOf(fmt.RelationRecord)));
    const sa_end = try sectionEnd(header.str_array_off, header.str_array_count, @as(u64, @sizeOf(fmt.StrRef)));
    const sp_end = std.math.add(u64, header.string_pool_off, header.string_pool_size) catch return error.SectionOutOfBounds;

    if (cat_end > end or item_end > end or rel_end > end or sa_end > end or sp_end > end) {
        return error.SectionOutOfBounds;
    }

    const view: View = .{
        .buf = buf,
        .header = header,
        .categories = std.mem.bytesAsSlice(fmt.CategoryRecord, buf[header.categories_off..cat_end]),
        .items = std.mem.bytesAsSlice(fmt.ItemRecord, buf[header.items_off..item_end]),
        .relations = std.mem.bytesAsSlice(fmt.RelationRecord, buf[header.relations_off..rel_end]),
        .str_array_pool = std.mem.bytesAsSlice(fmt.StrRef, buf[header.str_array_off..sa_end]),
        .string_pool = buf[header.string_pool_off..sp_end],
    };

    const pool_size = header.string_pool_size;
    const sa_count: u64 = header.str_array_count;

    // Validate every StrRef inside the str_array_pool against the string_pool.
    for (view.str_array_pool) |r| try validateStr(r, pool_size);

    // Validate all fields of every CategoryRecord.
    for (view.categories) |c| {
        try validateStr(c.id, pool_size);
        try validateStr(c.description, pool_size);
        try validateStr(c.mandatory_code, pool_size);
        try validateStrArray(c.key_names, sa_count);
        try validateStrArray(c.group_ids, sa_count);
        try validateStrArray(c.example_details, sa_count);
        try validateStrArray(c.example_cases, sa_count);
        try validateStrArray(c.items, sa_count);
    }

    for (view.items) |it| {
        try validateStr(it.name, pool_size);
        try validateStr(it.category_id, pool_size);
        try validateStr(it.description, pool_size);
        try validateStr(it.mandatory_code, pool_size);
        try validateStr(it.type_code, pool_size);
        try validateStrArray(it.enum_values, sa_count);
    }

    for (view.relations) |r| {
        try validateStr(r.child_category_id, pool_size);
        try validateStr(r.parent_category_id, pool_size);
        try validateStr(r.child_name, pool_size);
        try validateStr(r.parent_name, pool_size);
        try validateStr(r.link_group_id, pool_size);
    }

    return view;
}

pub fn loadFromFile(gpa: Allocator, path: []const u8) !struct { buf: []u8, view: View } {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(gpa, 128 * 1024 * 1024);
    errdefer gpa.free(bytes);
    const view = try load(bytes);
    return .{ .buf = bytes, .view = view };
}

test "load rejects too-small buffer" {
    const tiny: [10]u8 = @splat(0);
    try std.testing.expectError(error.TruncatedHeader, load(&tiny));
}

test "load rejects bad magic" {
    var buf: [@sizeOf(fmt.Header)]u8 = @splat(0);
    try std.testing.expectError(error.InvalidMagic, load(&buf));
}

const writer = @import("mdict_writer.zig");
const dic = @import("dic_loader.zig");

test "write then read preserves data" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cats = try aa.alloc(dic.Category, 2);
    cats[0] = .{
        .id = "atom_site",
        .description = "Atom site data",
        .mandatory_code = "no",
        .key_names = &.{"_atom_site.id"},
        .group_ids = &.{},
        .example_details = &.{},
        .example_cases = &.{},
        .items = &.{"_atom_site.id"},
    };
    cats[1] = .{
        .id = "entity",
        .description = "Entity data",
        .mandatory_code = "yes",
        .key_names = &.{"_entity.id"},
        .group_ids = &.{},
        .example_details = &.{},
        .example_cases = &.{},
        .items = &.{},
    };

    const items = try aa.alloc(dic.Item, 1);
    items[0] = .{
        .name = "_atom_site.id",
        .category_id = "atom_site",
        .description = "atom id",
        .mandatory_code = "yes",
        .type_code = "int",
        .enum_values = &.{},
    };

    const rels = try aa.alloc(dic.Relation, 0);

    var inner_arena = std.heap.ArenaAllocator.init(allocator);
    defer inner_arena.deinit();
    const bd: dic.BuildDict = .{
        .arena = inner_arena,
        .categories = cats,
        .items = items,
        .relations = rels,
    };

    const bytes = try writer.writeToBytes(allocator, &bd);
    defer allocator.free(bytes);

    const view = try load(bytes);
    try std.testing.expectEqual(@as(u32, 2), view.header.categories_count);
    try std.testing.expectEqual(@as(u32, 1), view.header.items_count);

    // Categories sorted alphabetically: atom_site < entity
    try std.testing.expectEqualStrings("atom_site", view.resolveStr(view.categories[0].id));
    try std.testing.expectEqualStrings("entity", view.resolveStr(view.categories[1].id));

    try std.testing.expectEqualStrings("_atom_site.id", view.resolveStr(view.items[0].name));
    try std.testing.expectEqualStrings("int", view.resolveStr(view.items[0].type_code));

    // key_names array of first category
    try std.testing.expectEqual(@as(usize, 1), view.strArrayLen(view.categories[0].key_names));
    try std.testing.expectEqualStrings("_atom_site.id", view.strArrayAt(view.categories[0].key_names, 0));
}

test "load rejects StrRef offset beyond string pool" {
    const allocator = std.testing.allocator;

    // Build a valid minimal buffer via the writer, then corrupt a StrRef in the
    // category record so its offset exceeds string_pool_size.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cats = try aa.alloc(dic.Category, 1);
    cats[0] = .{
        .id = "a",
        .description = "d",
        .mandatory_code = "no",
        .key_names = &.{},
        .group_ids = &.{},
        .example_details = &.{},
        .example_cases = &.{},
        .items = &.{},
    };
    var inner = std.heap.ArenaAllocator.init(allocator);
    defer inner.deinit();
    const bd: dic.BuildDict = .{
        .arena = inner,
        .categories = cats,
        .items = &.{},
        .relations = &.{},
    };
    const bytes = try writer.writeToBytes(allocator, &bd);
    defer allocator.free(bytes);

    // CategoryRecord starts immediately after the 128-byte header.
    // CategoryRecord begins with StrRef id { offset: u32, len: u32 }.
    // Overwrite id.offset with a huge value so the validation pass rejects it.
    const cat_off: usize = @sizeOf(fmt.Header);
    const bogus: u32 = 0xFFFF_FFFF;
    @memcpy(bytes[cat_off .. cat_off + 4], std.mem.asBytes(&bogus));

    try std.testing.expectError(error.SectionOutOfBounds, load(bytes));
}

test "load rejects categories_count overflow" {
    var buf: [@sizeOf(fmt.Header)]u8 = @splat(0);
    // Trigger true overflow in off + count*elem_size by using a huge offset
    // and a non-trivial count.
    const h: fmt.Header = .{
        .magic = fmt.magic,
        .version = fmt.format_version,
        .endian_mark = fmt.endian_mark,
        .header_size = @sizeOf(fmt.Header),
        .reserved = 0,
        .total_size = @sizeOf(fmt.Header),
        .categories_off = std.math.maxInt(u64) - 10,
        .categories_count = 100, // off + count*64 overflows u64
        ._pad0 = 0,
        .items_off = @sizeOf(fmt.Header),
        .items_count = 0,
        ._pad1 = 0,
        .relations_off = @sizeOf(fmt.Header),
        .relations_count = 0,
        ._pad2 = 0,
        .str_array_off = @sizeOf(fmt.Header),
        .str_array_count = 0,
        ._pad3 = 0,
        .string_pool_off = @sizeOf(fmt.Header),
        .string_pool_size = 0,
        .reserved_tail = @splat(0),
    };
    @memcpy(buf[0..@sizeOf(fmt.Header)], std.mem.asBytes(&h));

    try std.testing.expectError(error.SectionOutOfBounds, load(&buf));
}
