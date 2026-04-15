const std = @import("std");
const cif = @import("cif_parser.zig");
const Allocator = std.mem.Allocator;

pub const Category = struct {
    id: []const u8,
    description: []const u8,
    mandatory_code: []const u8,
    key_names: []const []const u8,
    group_ids: []const []const u8,
    example_details: []const []const u8,
    example_cases: []const []const u8,
    items: []const []const u8,
};

pub const Item = struct {
    name: []const u8,
    category_id: []const u8,
    description: []const u8,
    mandatory_code: []const u8,
    type_code: []const u8,
    enum_values: []const []const u8,
};

pub const Relation = struct {
    child_category_id: []const u8,
    parent_category_id: []const u8,
    child_name: []const u8,
    parent_name: []const u8,
    link_group_id: []const u8,
};

pub const BuildDict = struct {
    arena: std.heap.ArenaAllocator,
    categories: []Category,
    items: []Item,
    relations: []Relation,

    pub fn deinit(self: *BuildDict) void {
        self.arena.deinit();
    }
};

pub fn loadFromDicFile(gpa: Allocator, path: []const u8) !BuildDict {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(gpa, 128 * 1024 * 1024);
    defer gpa.free(content);

    return loadFromDicBytes(gpa, content);
}

pub fn loadFromDicBytes(gpa: Allocator, content: []const u8) !BuildDict {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var doc = try cif.parse(gpa, content);
    defer doc.deinit();
    if (doc.blocks.len == 0) return error.EmptyDictionary;
    const block = doc.blocks[0];

    var categories: std.ArrayList(Category) = .empty;
    defer categories.deinit(aa);
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(aa);
    var relations: std.ArrayList(Relation) = .empty;
    defer relations.deinit(aa);

    var cat_items = std.StringHashMap(std.ArrayList([]const u8)).init(aa);

    for (block.frames) |frame| {
        const classified = try classifyFrame(aa, frame);
        switch (classified) {
            .category => |cat| try categories.append(aa, cat),
            .item => |it| {
                try items.append(aa, it);
                const gop = try cat_items.getOrPut(it.category_id);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(aa, it.name);
            },
            .unknown => {},
        }
    }

    for (block.items) |blk_item| switch (blk_item) {
        .loop => |loop| {
            if (isLinkedGroupLoop(loop)) try appendRelations(aa, loop, &relations);
        },
        .pair => {},
    };

    for (categories.items) |*cat| {
        if (cat_items.get(cat.id)) |lst| {
            cat.items = try aa.dupe([]const u8, lst.items);
        }
    }

    return .{
        .arena = arena,
        .categories = try categories.toOwnedSlice(aa),
        .items = try items.toOwnedSlice(aa),
        .relations = try relations.toOwnedSlice(aa),
    };
}

const Classified = union(enum) {
    category: Category,
    item: Item,
    unknown,
};

fn classifyFrame(aa: Allocator, frame: cif.Frame) !Classified {
    if (frame.name.len > 0 and frame.name[0] == '_') {
        return .{ .item = try buildItem(aa, frame) };
    }
    return .{ .category = try buildCategory(aa, frame) };
}

fn buildCategory(aa: Allocator, frame: cif.Frame) !Category {
    return .{
        .id = (try findPair(aa, frame, "_category.id")) orelse try aa.dupe(u8, frame.name),
        .description = (try findPair(aa, frame, "_category.description")) orelse "",
        .mandatory_code = (try findPair(aa, frame, "_category.mandatory_code")) orelse "no",
        .key_names = (try findLoopCol(aa, frame, "_category_key.name")) orelse &.{},
        .group_ids = (try findLoopCol(aa, frame, "_category_group.id")) orelse &.{},
        .example_details = (try findLoopCol(aa, frame, "_category_examples.detail")) orelse &.{},
        .example_cases = (try findLoopCol(aa, frame, "_category_examples.case")) orelse &.{},
        .items = &.{},
    };
}

fn buildItem(aa: Allocator, frame: cif.Frame) !Item {
    const name = (try findPair(aa, frame, "_item.name")) orelse try aa.dupe(u8, frame.name);
    const explicit_cat = try findPair(aa, frame, "_item.category_id");
    const category_id = explicit_cat orelse inferCategoryId(name);
    return .{
        .name = name,
        .category_id = category_id,
        .description = (try findPair(aa, frame, "_item_description.description")) orelse "",
        .mandatory_code = (try findPair(aa, frame, "_item.mandatory_code")) orelse "no",
        .type_code = (try findPair(aa, frame, "_item_type.code")) orelse "",
        .enum_values = (try findLoopCol(aa, frame, "_item_enumeration.value")) orelse &.{},
    };
}

fn findPair(aa: Allocator, frame: cif.Frame, tag: []const u8) !?[]const u8 {
    for (frame.items) |it| switch (it) {
        .pair => |p| if (std.mem.eql(u8, p.tag, tag)) return try aa.dupe(u8, stripQuotes(p.value)),
        .loop => |loop| for (loop.tags, 0..) |t, i| {
            if (std.mem.eql(u8, t, tag) and loop.rowCount() > 0) {
                return try aa.dupe(u8, stripQuotes(loop.val(0, i)));
            }
        },
    };
    return null;
}

fn findLoopCol(aa: Allocator, frame: cif.Frame, tag: []const u8) !?[]const []const u8 {
    for (frame.items) |it| switch (it) {
        .loop => |loop| {
            for (loop.tags, 0..) |t, col| {
                if (!std.mem.eql(u8, t, tag)) continue;
                const n = loop.rowCount();
                const out = try aa.alloc([]const u8, n);
                for (0..n) |r| out[r] = try aa.dupe(u8, stripQuotes(loop.val(r, col)));
                return out;
            }
        },
        .pair => |p| if (std.mem.eql(u8, p.tag, tag)) {
            const one = try aa.alloc([]const u8, 1);
            one[0] = try aa.dupe(u8, stripQuotes(p.value));
            return one;
        },
    };
    return null;
}

fn isLinkedGroupLoop(loop: cif.Loop) bool {
    for (loop.tags) |t| {
        if (std.mem.startsWith(u8, t, "_pdbx_item_linked_group_list.")) return true;
    }
    return false;
}

fn appendRelations(aa: Allocator, loop: cif.Loop, out: *std.ArrayList(Relation)) !void {
    const cc = colIndex(loop, "_pdbx_item_linked_group_list.child_category_id") orelse return;
    const pc = colIndex(loop, "_pdbx_item_linked_group_list.parent_category_id") orelse return;
    const cn = colIndex(loop, "_pdbx_item_linked_group_list.child_name") orelse return;
    const pn = colIndex(loop, "_pdbx_item_linked_group_list.parent_name") orelse return;
    const lg = colIndex(loop, "_pdbx_item_linked_group_list.link_group_id") orelse return;

    const n = loop.rowCount();
    for (0..n) |r| {
        try out.append(aa, .{
            .child_category_id = try aa.dupe(u8, stripQuotes(loop.val(r, cc))),
            .parent_category_id = try aa.dupe(u8, stripQuotes(loop.val(r, pc))),
            .child_name = try aa.dupe(u8, stripQuotes(loop.val(r, cn))),
            .parent_name = try aa.dupe(u8, stripQuotes(loop.val(r, pn))),
            .link_group_id = try aa.dupe(u8, stripQuotes(loop.val(r, lg))),
        });
    }
}

fn colIndex(loop: cif.Loop, tag: []const u8) ?usize {
    for (loop.tags, 0..) |t, i| if (std.mem.eql(u8, t, tag)) return i;
    return null;
}

fn inferCategoryId(name: []const u8) []const u8 {
    const start: usize = if (name.len > 0 and name[0] == '_') 1 else 0;
    const dot = std.mem.indexOfScalar(u8, name[start..], '.') orelse return "";
    return name[start .. start + dot];
}

fn stripQuotes(v: []const u8) []const u8 {
    if (v.len >= 2 and (v[0] == '"' or v[0] == '\'') and v[v.len - 1] == v[0]) {
        return v[1 .. v.len - 1];
    }
    return v;
}

test "loadFromDicBytes parses minimal dictionary" {
    const allocator = std.testing.allocator;
    const input =
        \\data_test_dic
        \\save_test_cat
        \\    _category.id            test_cat
        \\    _category.description   'A test category'
        \\    _category.mandatory_code no
        \\    loop_ _category_key.name _test_cat.id stop_
        \\save_
        \\save__test_cat.id
        \\    _item.name               '_test_cat.id'
        \\    _item.category_id        test_cat
        \\    _item.mandatory_code     yes
        \\    _item_type.code          int
        \\    _item_description.description 'Primary key'
        \\save_
        \\loop_
        \\_pdbx_item_linked_group_list.child_category_id
        \\_pdbx_item_linked_group_list.parent_category_id
        \\_pdbx_item_linked_group_list.child_name
        \\_pdbx_item_linked_group_list.parent_name
        \\_pdbx_item_linked_group_list.link_group_id
        \\test_cat parent_cat '_test_cat.parent_id' '_parent_cat.id' 1
    ;

    var bd = try loadFromDicBytes(allocator, input);
    defer bd.deinit();

    try std.testing.expectEqual(@as(usize, 1), bd.categories.len);
    try std.testing.expectEqualStrings("test_cat", bd.categories[0].id);
    try std.testing.expectEqual(@as(usize, 1), bd.categories[0].items.len);
    try std.testing.expectEqualStrings("_test_cat.id", bd.categories[0].items[0]);

    try std.testing.expectEqual(@as(usize, 1), bd.items.len);
    try std.testing.expectEqualStrings("_test_cat.id", bd.items[0].name);
    try std.testing.expectEqualStrings("test_cat", bd.items[0].category_id);
    try std.testing.expectEqualStrings("int", bd.items[0].type_code);

    try std.testing.expectEqual(@as(usize, 1), bd.relations.len);
    try std.testing.expectEqualStrings("parent_cat", bd.relations[0].parent_category_id);
}
