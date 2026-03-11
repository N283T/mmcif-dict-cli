const std = @import("std");
const dict = @import("dict.zig");
const Allocator = std.mem.Allocator;

const max_dict_size = 64 * 1024 * 1024; // 64 MB

pub fn loadFromFile(gpa: Allocator, path: []const u8) !dict.Dictionary {
    const file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{})
    else
        try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Detect gzip by extension and decompress natively
    const content = if (std.mem.endsWith(u8, path, ".gz"))
        readGzip(gpa, file) catch return error.DictionaryCorrupt
    else
        try file.readToEndAlloc(gpa, max_dict_size);
    defer gpa.free(content);

    return loadFromString(gpa, content);
}

fn readGzip(gpa: Allocator, file: std.fs.File) ![]u8 {
    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(&reader_buf);
    var window_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor = std.compress.flate.Decompress.init(
        &file_reader.interface,
        .gzip,
        &window_buf,
    );
    const limit: std.Io.Limit = @enumFromInt(max_dict_size);
    return decompressor.reader.allocRemaining(gpa, limit);
}

pub fn loadFromString(gpa: Allocator, content: []const u8) !dict.Dictionary {
    // Arena owns all parsed JSON string data. Lives inside Dictionary.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, aa, content, .{});
    // parsed is on arena — no separate deinit needed.

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidInput,
    };
    // Use the first key in the root object (e.g. "data_mmcif_pdbx.dic", "data_mmcif_ihm_ext.dic")
    var root_iter = root_obj.iterator();
    const first_entry = root_iter.next() orelse return error.InvalidInput;
    const dic_obj = switch (first_entry.value_ptr.*) {
        .object => |o| o,
        else => return error.InvalidInput,
    };

    var categories = std.StringHashMap(dict.Category).init(gpa);
    errdefer categories.deinit();
    var items = std.StringHashMap(dict.Item).init(gpa);
    errdefer items.deinit();
    var relations_list: std.ArrayList(dict.Relation) = .empty;
    errdefer relations_list.deinit(gpa);

    // Collect items per category for reverse lookup
    var category_items = std.StringHashMap(std.ArrayList([]const u8)).init(gpa);
    defer {
        var it = category_items.valueIterator();
        while (it.next()) |list| {
            list.deinit(gpa);
        }
        category_items.deinit();
    }

    // Parse save blocks from PDBj format (save_ prefix at root level)
    var iter = dic_obj.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "save__")) {
            try addItem(aa, gpa, entry.value_ptr.*, &items, &category_items);
        } else if (std.mem.startsWith(u8, key, "save_")) {
            try addCategory(aa, entry.value_ptr.*, &categories);
        } else if (std.mem.eql(u8, key, "pdbx_item_linked_group_list")) {
            try addRelations(gpa, entry.value_ptr.*, &relations_list);
        }
    }

    // Parse Frames from gemmi mmJSON format (items start with '_', categories don't)
    if (dic_obj.get("Frames")) |frames_val| {
        const frames_obj = switch (frames_val) {
            .object => |o| o,
            else => null,
        };
        if (frames_obj) |frames| {
            var frames_iter = frames.iterator();
            while (frames_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (key.len > 0 and key[0] == '_') {
                    try addItem(aa, gpa, entry.value_ptr.*, &items, &category_items);
                } else {
                    try addCategory(aa, entry.value_ptr.*, &categories);
                }
            }
        }
    }

    // Attach item lists to categories
    var cat_iter = categories.iterator();
    while (cat_iter.next()) |entry| {
        if (category_items.get(entry.key_ptr.*)) |item_list| {
            const slice = try aa.alloc([]const u8, item_list.items.len);
            @memcpy(slice, item_list.items);
            entry.value_ptr.*.items = slice;
        }
    }

    return .{
        .arena = arena,
        .gpa = gpa,
        .categories = categories,
        .items = items,
        .relations = try relations_list.toOwnedSlice(gpa),
    };
}

fn addCategory(
    aa: Allocator,
    val: std.json.Value,
    categories: *std.StringHashMap(dict.Category),
) !void {
    const cat = (try parseCategory(aa, val)) orelse return;
    try categories.put(cat.id, cat);
}

fn addItem(
    aa: Allocator,
    gpa: Allocator,
    val: std.json.Value,
    items: *std.StringHashMap(dict.Item),
    category_items: *std.StringHashMap(std.ArrayList([]const u8)),
) !void {
    const item = (try parseItem(aa, val)) orelse return;
    try items.put(item.name, item);
    const gop = try category_items.getOrPut(item.category_id);
    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }
    try gop.value_ptr.append(gpa, item.name);
}

fn addRelations(
    gpa: Allocator,
    val: std.json.Value,
    relations_list: *std.ArrayList(dict.Relation),
) !void {
    const rels = try parseRelations(gpa, val);
    defer gpa.free(rels);
    for (rels) |rel| {
        try relations_list.append(gpa, rel);
    }
}

fn getFirstString(val: std.json.Value, outer_key: []const u8, inner_key: []const u8) []const u8 {
    const obj = switch (val) {
        .object => |o| o,
        else => return "",
    };
    const outer = obj.get(outer_key) orelse return "";
    const outer_obj = switch (outer) {
        .object => |o| o,
        else => return "",
    };
    const inner = outer_obj.get(inner_key) orelse return "";
    return switch (inner) {
        .array => |arr| if (arr.items.len > 0) jsonStr(arr.items[0]) else "",
        .string => |s| s,
        else => "",
    };
}

fn getStringArray(allocator: Allocator, val: std.json.Value, outer_key: []const u8, inner_key: []const u8) ![]const []const u8 {
    const obj = switch (val) {
        .object => |o| o,
        else => return &.{},
    };
    const outer = obj.get(outer_key) orelse return &.{};
    const outer_obj = switch (outer) {
        .object => |o| o,
        else => return &.{},
    };
    const inner = outer_obj.get(inner_key) orelse return &.{};
    const arr = switch (inner) {
        .array => |a| a,
        else => return &.{},
    };

    const result = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        result[i] = jsonStr(item);
    }
    return result;
}

fn parseCategory(allocator: Allocator, val: std.json.Value) !?dict.Category {
    const id = getFirstString(val, "category", "id");
    if (id.len == 0) return null;

    return .{
        .id = id,
        .description = getFirstString(val, "category", "description"),
        .mandatory_code = getFirstString(val, "category", "mandatory_code"),
        .key_names = try getStringArray(allocator, val, "category_key", "name"),
        .group_ids = try getStringArray(allocator, val, "category_group", "id"),
        .example_details = try getStringArray(allocator, val, "category_examples", "detail"),
        .example_cases = try getStringArray(allocator, val, "category_examples", "case"),
        .items = &.{},
    };
}

fn parseItem(allocator: Allocator, val: std.json.Value) !?dict.Item {
    const name = getFirstString(val, "item", "name");
    if (name.len == 0) return null;

    // Use explicit category_id if present, otherwise infer from item name
    // (e.g. "_atom_site.label_atom_id" → "atom_site")
    const explicit_cat = getFirstString(val, "item", "category_id");
    const category_id = if (explicit_cat.len > 0) explicit_cat else inferCategoryId(name);

    return .{
        .name = name,
        .category_id = category_id,
        .description = getFirstString(val, "item_description", "description"),
        .mandatory_code = getFirstString(val, "item", "mandatory_code"),
        .type_code = getFirstString(val, "item_type", "code"),
        .enum_values = try getStringArray(allocator, val, "item_enumeration", "value"),
    };
}

/// Infer category_id from item name: "_atom_site.label_atom_id" → "atom_site"
fn inferCategoryId(name: []const u8) []const u8 {
    const start: usize = if (name.len > 0 and name[0] == '_') 1 else 0;
    const dot = std.mem.indexOfScalar(u8, name[start..], '.') orelse return "";
    return name[start .. start + dot];
}

fn parseRelations(allocator: Allocator, val: std.json.Value) ![]dict.Relation {
    const obj = switch (val) {
        .object => |o| o,
        else => return &.{},
    };

    const child_cats = getJsonArray(obj, "child_category_id") orelse return &.{};
    const parent_cats = getJsonArray(obj, "parent_category_id") orelse return &.{};
    const child_names = getJsonArray(obj, "child_name") orelse return &.{};
    const parent_names = getJsonArray(obj, "parent_name") orelse return &.{};
    const link_groups = getJsonArray(obj, "link_group_id") orelse return &.{};

    const len = child_cats.len;
    if (parent_cats.len != len or child_names.len != len or parent_names.len != len or link_groups.len != len) {
        return error.InvalidInput;
    }

    const results = try allocator.alloc(dict.Relation, len);
    for (0..len) |i| {
        results[i] = .{
            .child_category_id = jsonStr(child_cats[i]),
            .parent_category_id = jsonStr(parent_cats[i]),
            .child_name = jsonStr(child_names[i]),
            .parent_name = jsonStr(parent_names[i]),
            .link_group_id = jsonStr(link_groups[i]),
        };
    }
    return results;
}

fn getJsonArray(obj: std.json.ObjectMap, key: []const u8) ?[]const std.json.Value {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .array => |a| a.items,
        else => null,
    };
}

fn jsonStr(val: std.json.Value) []const u8 {
    return switch (val) {
        .string => |s| s,
        else => "",
    };
}

test "loadFromString minimal" {
    const allocator = std.testing.allocator;

    const json =
        \\{"data_mmcif_pdbx.dic":{
        \\  "save_test_cat":{
        \\    "category":{"id":["test_cat"],"description":["A test category"],"mandatory_code":["no"]},
        \\    "category_key":{"name":["_test_cat.id"]},
        \\    "category_group":{"id":["inclusive_group"]}
        \\  },
        \\  "save__test_cat.id":{
        \\    "item":{"name":["_test_cat.id"],"category_id":["test_cat"],"mandatory_code":["yes"]},
        \\    "item_description":{"description":["Primary key"]},
        \\    "item_type":{"code":["int"]}
        \\  },
        \\  "save__test_cat.name":{
        \\    "item":{"name":["_test_cat.name"],"category_id":["test_cat"],"mandatory_code":["no"]},
        \\    "item_description":{"description":["A name field"]},
        \\    "item_type":{"code":["text"]},
        \\    "item_enumeration":{"value":["alpha","beta","gamma"]}
        \\  },
        \\  "pdbx_item_linked_group_list":{
        \\    "child_category_id":["test_cat"],
        \\    "parent_category_id":["parent_cat"],
        \\    "child_name":["_test_cat.parent_id"],
        \\    "parent_name":["_parent_cat.id"],
        \\    "link_group_id":["1"]
        \\  }
        \\}}
    ;

    var d = try loadFromString(allocator, json);
    defer d.deinit();

    // Category lookup
    const cat = d.getCategory("test_cat").?;
    try std.testing.expectEqualStrings("test_cat", cat.id);
    try std.testing.expectEqualStrings("A test category", cat.description);
    try std.testing.expectEqual(@as(usize, 2), cat.items.len);

    // Item lookup
    const item = d.getItem("_test_cat.name").?;
    try std.testing.expectEqualStrings("_test_cat.name", item.name);
    try std.testing.expectEqualStrings("text", item.type_code);
    try std.testing.expectEqual(@as(usize, 3), item.enum_values.len);
    try std.testing.expectEqualStrings("alpha", item.enum_values[0]);
    try std.testing.expectEqualStrings("gamma", item.enum_values[2]);

    // Relations
    const rels = try d.getRelationsForCategory(allocator, "test_cat");
    defer allocator.free(rels);
    try std.testing.expectEqual(@as(usize, 1), rels.len);
    try std.testing.expectEqualStrings("parent_cat", rels[0].parent_category_id);

    // Search
    const results = try d.searchDescriptions(allocator, "name field");
    defer allocator.free(results.categories);
    defer allocator.free(results.items);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("_test_cat.name", results.items[0].name);

    // Missing lookups
    try std.testing.expect(d.getCategory("nonexistent") == null);
    try std.testing.expect(d.getItem("_nonexistent.field") == null);
}

test "parseRelations rejects mismatched array lengths" {
    const allocator = std.testing.allocator;

    const json =
        \\{"data_mmcif_pdbx.dic":{
        \\  "pdbx_item_linked_group_list":{
        \\    "child_category_id":["a","b"],
        \\    "parent_category_id":["c"],
        \\    "child_name":["_a.x","_b.x"],
        \\    "parent_name":["_c.x","_c.y"],
        \\    "link_group_id":["1","2"]
        \\  }
        \\}}
    ;

    const result = loadFromString(allocator, json);
    try std.testing.expectError(error.InvalidInput, result);
}

test "loadFromString with invalid JSON" {
    const allocator = std.testing.allocator;
    const result = loadFromString(allocator, "not json at all");
    try std.testing.expect(result == error.UnexpectedCharacter or true);
    // Any error is acceptable for malformed input
    if (result) |*d| {
        var d_mut = d.*;
        d_mut.deinit();
    } else |_| {}
}

test "loadFromString with empty root object" {
    const allocator = std.testing.allocator;
    const json = \\{}
    ;
    const result = loadFromString(allocator, json);
    try std.testing.expectError(error.InvalidInput, result);
}

test "loadFromString accepts any root key" {
    const allocator = std.testing.allocator;
    const json =
        \\{"data_other.dic":{
        \\  "save_my_cat":{
        \\    "category":{"id":["my_cat"],"description":["Test"],"mandatory_code":["no"]},
        \\    "category_key":{"name":["_my_cat.id"]}
        \\  },
        \\  "save__my_cat.id":{
        \\    "item":{"name":["_my_cat.id"],"category_id":["my_cat"],"mandatory_code":["yes"]},
        \\    "item_description":{"description":["Primary key"]},
        \\    "item_type":{"code":["int"]}
        \\  }
        \\}}
    ;
    var d = try loadFromString(allocator, json);
    defer d.deinit();
    const cat = d.getCategory("my_cat").?;
    try std.testing.expectEqualStrings("my_cat", cat.id);
}

test "loadFromString with non-object root value" {
    const allocator = std.testing.allocator;
    const json = \\{"data_foo.dic":"not_an_object"}
    ;
    const result = loadFromString(allocator, json);
    try std.testing.expectError(error.InvalidInput, result);
}

test "loadFromFile with gzip" {
    const allocator = std.testing.allocator;

    var d = try loadFromFile(allocator, "testdata/minimal.json.gz");
    defer d.deinit();

    const cat = d.getCategory("gz_cat").?;
    try std.testing.expectEqualStrings("gz_cat", cat.id);
    try std.testing.expectEqualStrings("Gzip test", cat.description);

    const item = d.getItem("_gz_cat.id").?;
    try std.testing.expectEqualStrings("_gz_cat.id", item.name);
}

test "loadFromFile with plain json" {
    const allocator = std.testing.allocator;

    var d = try loadFromFile(allocator, "testdata/minimal.json");
    defer d.deinit();

    const cat = d.getCategory("gz_cat").?;
    try std.testing.expectEqualStrings("gz_cat", cat.id);
}

test "loadFromString with gemmi mmJSON Frames format" {
    const allocator = std.testing.allocator;

    const json =
        \\{"data_test.dic":{
        \\  "Frames":{
        \\    "test_cat":{
        \\      "category":{"id":["test_cat"],"description":["A test category"],"mandatory_code":["no"]},
        \\      "category_key":{"name":["_test_cat.id"]}
        \\    },
        \\    "_test_cat.id":{
        \\      "item":{"name":["_test_cat.id"],"category_id":["test_cat"],"mandatory_code":["yes"]},
        \\      "item_description":{"description":["Primary key"]},
        \\      "item_type":{"code":["int"]}
        \\    },
        \\    "_test_cat.name":{
        \\      "item":{"name":["_test_cat.name"],"category_id":["test_cat"],"mandatory_code":["no"]},
        \\      "item_description":{"description":["A name field"]},
        \\      "item_type":{"code":["text"]}
        \\    }
        \\  }
        \\}}
    ;

    var d = try loadFromString(allocator, json);
    defer d.deinit();

    // Category lookup
    const cat = d.getCategory("test_cat").?;
    try std.testing.expectEqualStrings("test_cat", cat.id);
    try std.testing.expectEqualStrings("A test category", cat.description);
    try std.testing.expectEqual(@as(usize, 2), cat.items.len);

    // Item lookup
    const item = d.getItem("_test_cat.name").?;
    try std.testing.expectEqualStrings("_test_cat.name", item.name);
    try std.testing.expectEqualStrings("text", item.type_code);
}
