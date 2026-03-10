# mmcif-dict-cli Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Zig CLI that queries mmCIF PDBx dictionary definitions from PDBj's JSON.

**Architecture:** Read pre-decompressed JSON (~4.7MB, 7370 save blocks) with an arena allocator. Build lookup indices for categories/items/relations. Serve CLI queries. The arena owns all parsed string data and is freed when Dictionary is deinitialized.

**Tech Stack:** Zig 0.15.2, std.json, no external dependencies.

**Spec:** `docs/superpowers/specs/2026-03-10-mmcif-dict-cli-design.md`

**Key decisions:**
- Use `std.json.parseFromSlice` with an `ArenaAllocator` stored in `Dictionary`. All string data is owned by the arena — no copying needed.
- Relationships use `pdbx_item_linked_group_list` (not `pdbx_item_linked_group`) — this is the key that has `child_name`/`parent_name` fields.
- Tests use inline `test` blocks (Zig convention) instead of separate test files. `build.zig` runs tests from `src/main.zig` which transitively imports all modules.

---

## Chunk 1: Project Setup & Data Model

### Task 1: Initialize Zig project

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`
- Create: `.gitignore`

- [ ] **Step 1: Init Zig project**

```bash
cd /Users/nagaet/mmcif-dict-cli
zig init
```

- [ ] **Step 2: Replace build.zig with project config**

`build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mmcif-dict",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run mmcif-dict");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

- [ ] **Step 3: Update .gitignore**

`.gitignore`:
```
zig-out/
zig-cache/
.zig-cache/
data/mmcif_pdbx.json
data/mmcif_pdbx.json.gz
```

- [ ] **Step 4: Prepare data file**

```bash
mkdir -p /Users/nagaet/mmcif-dict-cli/data
gzip -dkf /Users/nagaet/pdb/pdbj/pdbjplus/dictionaries/mmcif_pdbx.json.gz
cp /Users/nagaet/pdb/pdbj/pdbjplus/dictionaries/mmcif_pdbx.json /Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json
```

- [ ] **Step 5: Create minimal main.zig**

`src/main.zig`:
```zig
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("mmcif-dict v0.1.0\n", .{});
}
```

- [ ] **Step 6: Verify build**

```bash
cd /Users/nagaet/mmcif-dict-cli
zig build run
```
Expected: `mmcif-dict v0.1.0`

- [ ] **Step 7: Initialize git and commit**

```bash
cd /Users/nagaet/mmcif-dict-cli
git init
git checkout -b feature/initial-setup
git add build.zig build.zig.zon src/main.zig .gitignore docs/
git commit -m "feat: initialize Zig project with build config"
```

---

### Task 2: Data model and JSON loader

**Files:**
- Create: `src/dict.zig`
- Create: `src/json_loader.zig`

The PDBj JSON has this structure:
```json
{
  "data_mmcif_pdbx.dic": {
    "save_atom_site": {
      "category": { "description": ["..."], "id": ["atom_site"], "mandatory_code": ["no"] },
      "category_key": { "name": ["_atom_site.id"] },
      "category_group": { "id": ["inclusive_group", "atom_group"] },
      "category_examples": { "detail": ["..."], "case": ["..."] }
    },
    "save__atom_site.group_PDB": {
      "item_description": { "description": ["..."] },
      "item": { "name": ["_atom_site.group_PDB"], "category_id": ["atom_site"], "mandatory_code": ["no"] },
      "item_type": { "code": ["code"] },
      "item_enumeration": { "value": ["ATOM", "HETATM"] }
    },
    "pdbx_item_linked_group_list": {
      "child_category_id": ["cat1", "cat2", ...],
      "parent_category_id": ["pcat1", "pcat2", ...],
      "child_name": ["_cat1.field", ...],
      "parent_name": ["_pcat1.field", ...],
      "link_group_id": ["1", "1", ...]
    }
  }
}
```

All leaf values are arrays of strings. Parallel arrays (same index = same record).

- [ ] **Step 1: Write dict.zig with data model and tests**

`src/dict.zig`:
```zig
const std = @import("std");
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

pub const SearchResults = struct {
    categories: []const Category,
    items: []const Item,
};

pub const Dictionary = struct {
    /// Arena that owns all parsed JSON string data. Must outlive all queries.
    arena: std.heap.ArenaAllocator,
    /// General-purpose allocator for dynamic collections (ArrayList results, etc.)
    gpa: Allocator,
    categories: std.StringHashMap(Category),
    items: std.StringHashMap(Item),
    relations: []const Relation,

    pub fn getCategory(self: *const Dictionary, name: []const u8) ?Category {
        return self.categories.get(name);
    }

    pub fn getItem(self: *const Dictionary, name: []const u8) ?Item {
        return self.items.get(name);
    }

    pub fn getRelationsForCategory(self: *const Dictionary, category_id: []const u8) ![]const Relation {
        var results = std.ArrayList(Relation).init(self.gpa);
        for (self.relations) |rel| {
            if (std.mem.eql(u8, rel.child_category_id, category_id) or
                std.mem.eql(u8, rel.parent_category_id, category_id))
            {
                try results.append(rel);
            }
        }
        return results.toOwnedSlice();
    }

    pub fn searchDescriptions(self: *const Dictionary, query: []const u8) !SearchResults {
        var cat_results = std.ArrayList(Category).init(self.gpa);
        var item_results = std.ArrayList(Item).init(self.gpa);

        var cat_iter = self.categories.valueIterator();
        while (cat_iter.next()) |cat| {
            if (containsInsensitive(cat.description, query)) {
                try cat_results.append(cat.*);
            }
        }

        var item_iter = self.items.valueIterator();
        while (item_iter.next()) |item| {
            if (containsInsensitive(item.description, query)) {
                try item_results.append(item.*);
            }
        }

        return .{
            .categories = try cat_results.toOwnedSlice(),
            .items = try item_results.toOwnedSlice(),
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.categories.deinit();
        self.items.deinit();
        self.gpa.free(self.relations);
        self.arena.deinit(); // Frees all parsed JSON string data
    }
};

pub fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Extract a snippet of text around the first match of needle in haystack.
/// Returns up to `context_chars` characters before and after the match.
pub fn extractSnippet(haystack: []const u8, needle: []const u8, context_chars: usize) []const u8 {
    if (needle.len == 0 or haystack.len < needle.len) return haystack[0..@min(haystack.len, context_chars * 2)];

    const end = haystack.len - needle.len + 1;
    for (0..end) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) {
            const start = if (i > context_chars) i - context_chars else 0;
            const match_end = i + needle.len;
            const snippet_end = @min(haystack.len, match_end + context_chars);
            return haystack[start..snippet_end];
        }
    }
    return haystack[0..@min(haystack.len, context_chars * 2)];
}

test "containsInsensitive basic" {
    const testing = std.testing;
    try testing.expect(containsInsensitive("Electron Density Map", "electron density"));
    try testing.expect(containsInsensitive("HELLO WORLD", "hello"));
    try testing.expect(!containsInsensitive("hello", "world"));
    try testing.expect(containsInsensitive("abc", ""));
    try testing.expect(!containsInsensitive("", "abc"));
}

test "containsInsensitive edge cases" {
    const testing = std.testing;
    try testing.expect(containsInsensitive("a", "a"));
    try testing.expect(!containsInsensitive("a", "ab"));
    try testing.expect(containsInsensitive("ABC DEF", "c d"));
}

test "extractSnippet" {
    const testing = std.testing;
    const text = "Data items in the ATOM_SITE category record details about the atom sites";
    const snippet = extractSnippet(text, "atom_site", 10);
    // Should contain "ATOM_SITE" with surrounding context
    try testing.expect(snippet.len > 0);
    try testing.expect(containsInsensitive(snippet, "atom_site"));
}
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/nagaet/mmcif-dict-cli
zig build test
```
Expected: all 3 tests PASS

- [ ] **Step 3: Write json_loader.zig**

`src/json_loader.zig`:
```zig
const std = @import("std");
const dict = @import("dict.zig");
const Allocator = std.mem.Allocator;

pub fn loadFromFile(gpa: Allocator, path: []const u8) !dict.Dictionary {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    // Read entire file content using gpa (temporary — freed after parsing)
    const content = try file.readToEndAlloc(gpa, 64 * 1024 * 1024);
    defer gpa.free(content);

    return loadFromString(gpa, content);
}

pub fn loadFromString(gpa: Allocator, content: []const u8) !dict.Dictionary {
    // Arena allocator owns all parsed JSON string data.
    // It lives inside Dictionary and is freed in Dictionary.deinit().
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const arena_alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena_alloc, content, .{});
    // parsed is allocated on arena — no need to deinit separately.
    // All string data from JSON lives in arena memory.

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidInput,
    };
    const dic_val = root_obj.get("data_mmcif_pdbx.dic") orelse return error.InvalidInput;
    const dic_obj = switch (dic_val) {
        .object => |o| o,
        else => return error.InvalidInput,
    };

    // Use gpa for hash maps and array lists (they need stable memory)
    var categories = std.StringHashMap(dict.Category).init(gpa);
    errdefer categories.deinit();
    var items = std.StringHashMap(dict.Item).init(gpa);
    errdefer items.deinit();
    var relations_list = std.ArrayList(dict.Relation).init(gpa);
    errdefer relations_list.deinit();

    // Collect items per category for reverse lookup
    var category_items = std.StringHashMap(std.ArrayList([]const u8)).init(gpa);
    defer {
        var it = category_items.valueIterator();
        while (it.next()) |list| {
            list.deinit();
        }
        category_items.deinit();
    }

    // Parse all save blocks
    var iter = dic_obj.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "save__")) {
            // Item definition (double underscore)
            const item = parseItem(arena_alloc, entry.value_ptr.*) orelse continue;
            try items.put(item.name, item);

            // Track items per category
            const gop = try category_items.getOrPut(item.category_id);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList([]const u8).init(gpa);
            }
            try gop.value_ptr.append(item.name);
        } else if (std.mem.startsWith(u8, key, "save_")) {
            // Category definition (single underscore)
            const cat = parseCategory(arena_alloc, entry.value_ptr.*) orelse continue;
            try categories.put(cat.id, cat);
        } else if (std.mem.eql(u8, key, "pdbx_item_linked_group_list")) {
            const rels = try parseRelations(gpa, entry.value_ptr.*);
            for (rels) |rel| {
                try relations_list.append(rel);
            }
            gpa.free(rels);
        }
    }

    // Attach item lists to categories (copy from ArrayList to arena-owned slice)
    var cat_iter = categories.iterator();
    while (cat_iter.next()) |entry| {
        if (category_items.get(entry.key_ptr.*)) |item_list| {
            const slice = try arena_alloc.alloc([]const u8, item_list.items.len);
            @memcpy(slice, item_list.items);
            entry.value_ptr.*.items = slice;
        }
    }

    return .{
        .arena = arena,
        .gpa = gpa,
        .categories = categories,
        .items = items,
        .relations = try relations_list.toOwnedSlice(),
    };
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

/// Extract all strings from a nested JSON array: val[outer_key][inner_key] = ["a", "b", ...]
/// Returns an arena-allocated slice of string pointers.
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

fn parseCategory(allocator: Allocator, val: std.json.Value) ?dict.Category {
    const id = getFirstString(val, "category", "id");
    if (id.len == 0) return null;

    return .{
        .id = id,
        .description = getFirstString(val, "category", "description"),
        .mandatory_code = getFirstString(val, "category", "mandatory_code"),
        .key_names = getStringArray(allocator, val, "category_key", "name") catch &.{},
        .group_ids = getStringArray(allocator, val, "category_group", "id") catch &.{},
        .example_details = getStringArray(allocator, val, "category_examples", "detail") catch &.{},
        .example_cases = getStringArray(allocator, val, "category_examples", "case") catch &.{},
        .items = &.{},
    };
}

fn parseItem(allocator: Allocator, val: std.json.Value) ?dict.Item {
    const name = getFirstString(val, "item", "name");
    if (name.len == 0) return null;

    return .{
        .name = name,
        .category_id = getFirstString(val, "item", "category_id"),
        .description = getFirstString(val, "item_description", "description"),
        .mandatory_code = getFirstString(val, "item", "mandatory_code"),
        .type_code = getFirstString(val, "item_type", "code"),
        .enum_values = getStringArray(allocator, val, "item_enumeration", "value") catch &.{},
    };
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
    var results = try allocator.alloc(dict.Relation, len);
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
    const testing = std.testing;
    const allocator = testing.allocator;

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

    // Test category lookup
    const cat = d.getCategory("test_cat").?;
    try testing.expectEqualStrings("test_cat", cat.id);
    try testing.expectEqualStrings("A test category", cat.description);
    try testing.expectEqual(@as(usize, 2), cat.items.len); // id and name

    // Test item lookup
    const item = d.getItem("_test_cat.name").?;
    try testing.expectEqualStrings("_test_cat.name", item.name);
    try testing.expectEqualStrings("text", item.type_code);
    try testing.expectEqual(@as(usize, 3), item.enum_values.len);
    try testing.expectEqualStrings("alpha", item.enum_values[0]);

    // Test relations
    const rels = try d.getRelationsForCategory("test_cat");
    defer d.gpa.free(rels);
    try testing.expectEqual(@as(usize, 1), rels.len);
    try testing.expectEqualStrings("parent_cat", rels[0].parent_category_id);

    // Test search
    const results = try d.searchDescriptions("name field");
    defer d.gpa.free(results.categories);
    defer d.gpa.free(results.items);
    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("_test_cat.name", results.items[0].name);

    // Test missing lookups
    try testing.expect(d.getCategory("nonexistent") == null);
    try testing.expect(d.getItem("_nonexistent.field") == null);
}
```

- [ ] **Step 4: Update main.zig to import new modules (for test discovery)**

Add to `src/main.zig` (after the existing code):
```zig
test {
    _ = @import("dict.zig");
    _ = @import("json_loader.zig");
}
```

- [ ] **Step 5: Run tests**

```bash
zig build test
```
Expected: all tests PASS (containsInsensitive x2, extractSnippet x1, loadFromString x1)

- [ ] **Step 6: Commit**

```bash
git add src/dict.zig src/json_loader.zig src/main.zig
git commit -m "feat: add dictionary data model and JSON loader with tests"
```

---

## Chunk 2: CLI Commands & Output

### Task 3: Output formatter

**Files:**
- Create: `src/output.zig`

- [ ] **Step 1: Write output.zig with complete text and JSON formatting**

`src/output.zig`:
```zig
const std = @import("std");
const dict = @import("dict.zig");

pub const Format = enum { text, json };

pub fn printCategory(writer: anytype, cat: dict.Category, format: Format) !void {
    switch (format) {
        .text => {
            try writer.print("Category: {s}\n", .{cat.id});
            try writer.print("Mandatory: {s}\n", .{cat.mandatory_code});
            if (cat.key_names.len > 0) {
                try writer.print("Keys: ", .{});
                for (cat.key_names, 0..) |k, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{k});
                }
                try writer.print("\n", .{});
            }
            if (cat.group_ids.len > 0) {
                try writer.print("Groups: ", .{});
                for (cat.group_ids, 0..) |g, i| {
                    if (i > 0) try writer.print(", ", .{});
                    try writer.print("{s}", .{g});
                }
                try writer.print("\n", .{});
            }
            try writer.print("\nDescription:\n{s}\n", .{cat.description});
            if (cat.items.len > 0) {
                try writer.print("\nItems ({d}):\n", .{cat.items.len});
                for (cat.items) |item| {
                    try writer.print("  {s}\n", .{item});
                }
            }
        },
        .json => {
            try writer.print("{{\"id\":", .{});
            try writeJsonString(writer, cat.id);
            try writer.print(",\"description\":", .{});
            try writeJsonString(writer, cat.description);
            try writer.print(",\"mandatory_code\":", .{});
            try writeJsonString(writer, cat.mandatory_code);
            try writer.print(",\"keys\":", .{});
            try writeJsonStringArray(writer, cat.key_names);
            try writer.print(",\"groups\":", .{});
            try writeJsonStringArray(writer, cat.group_ids);
            try writer.print(",\"items\":", .{});
            try writeJsonStringArray(writer, cat.items);
            try writer.print("}}\n", .{});
        },
    }
}

pub fn printItem(writer: anytype, item: dict.Item, format: Format) !void {
    switch (format) {
        .text => {
            try writer.print("Item: {s}\n", .{item.name});
            try writer.print("Category: {s}\n", .{item.category_id});
            try writer.print("Type: {s}\n", .{item.type_code});
            try writer.print("Mandatory: {s}\n", .{item.mandatory_code});
            try writer.print("\nDescription:\n{s}\n", .{item.description});
            if (item.enum_values.len > 0) {
                try writer.print("\nAllowed values:\n", .{});
                for (item.enum_values) |v| {
                    try writer.print("  {s}\n", .{v});
                }
            }
        },
        .json => {
            try writer.print("{{\"name\":", .{});
            try writeJsonString(writer, item.name);
            try writer.print(",\"category_id\":", .{});
            try writeJsonString(writer, item.category_id);
            try writer.print(",\"type\":", .{});
            try writeJsonString(writer, item.type_code);
            try writer.print(",\"mandatory\":", .{});
            try writeJsonString(writer, item.mandatory_code);
            try writer.print(",\"description\":", .{});
            try writeJsonString(writer, item.description);
            try writer.print(",\"enum_values\":", .{});
            try writeJsonStringArray(writer, item.enum_values);
            try writer.print("}}\n", .{});
        },
    }
}

pub fn printRelations(writer: anytype, category_id: []const u8, rels: []const dict.Relation, format: Format) !void {
    switch (format) {
        .text => {
            try writer.print("Relations for: {s}\n\n", .{category_id});
            if (rels.len == 0) {
                try writer.print("  No relations found.\n", .{});
                return;
            }
            for (rels) |rel| {
                if (std.mem.eql(u8, rel.child_category_id, category_id)) {
                    try writer.print("  {s} -> {s} (parent: {s})\n", .{
                        rel.child_name, rel.parent_name, rel.parent_category_id,
                    });
                } else {
                    try writer.print("  {s} <- {s} (child: {s})\n", .{
                        rel.parent_name, rel.child_name, rel.child_category_id,
                    });
                }
            }
        },
        .json => {
            try writer.print("{{\"category\":", .{});
            try writeJsonString(writer, category_id);
            try writer.print(",\"relations\":[", .{});
            for (rels, 0..) |rel, i| {
                if (i > 0) try writer.print(",", .{});
                try writer.print("{{\"child_name\":", .{});
                try writeJsonString(writer, rel.child_name);
                try writer.print(",\"parent_name\":", .{});
                try writeJsonString(writer, rel.parent_name);
                try writer.print(",\"child_category\":", .{});
                try writeJsonString(writer, rel.child_category_id);
                try writer.print(",\"parent_category\":", .{});
                try writeJsonString(writer, rel.parent_category_id);
                try writer.print("}}", .{});
            }
            try writer.print("]}}\n", .{});
        },
    }
}

pub fn printSearchResults(writer: anytype, query: []const u8, results: dict.SearchResults, format: Format) !void {
    switch (format) {
        .text => {
            if (results.categories.len > 0) {
                try writer.print("Categories ({d}):\n", .{results.categories.len});
                for (results.categories) |cat| {
                    const snippet = dict.extractSnippet(cat.description, query, 40);
                    try writer.print("  {s}\n    ...{s}...\n", .{ cat.id, snippet });
                }
            }
            if (results.items.len > 0) {
                try writer.print("\nItems ({d}):\n", .{results.items.len});
                for (results.items) |item| {
                    const snippet = dict.extractSnippet(item.description, query, 40);
                    try writer.print("  {s}\n    ...{s}...\n", .{ item.name, snippet });
                }
            }
            if (results.categories.len == 0 and results.items.len == 0) {
                try writer.print("No results found.\n", .{});
            }
        },
        .json => {
            try writer.print("{{\"query\":", .{});
            try writeJsonString(writer, query);
            try writer.print(",\"categories\":[", .{});
            for (results.categories, 0..) |cat, i| {
                if (i > 0) try writer.print(",", .{});
                try writeJsonString(writer, cat.id);
            }
            try writer.print("],\"items\":[", .{});
            for (results.items, 0..) |item, i| {
                if (i > 0) try writer.print(",", .{});
                try writeJsonString(writer, item.name);
            }
            try writer.print("]}}\n", .{});
        },
    }
}

pub fn printCategoryList(writer: anytype, names: []const []const u8, format: Format) !void {
    switch (format) {
        .text => {
            for (names) |name| {
                try writer.print("{s}\n", .{name});
            }
        },
        .json => {
            try writeJsonStringArray(writer, names);
            try writer.print("\n", .{});
        },
    }
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeJsonStringArray(writer: anytype, arr: []const []const u8) !void {
    try writer.writeByte('[');
    for (arr, 0..) |s, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, s);
    }
    try writer.writeByte(']');
}
```

- [ ] **Step 2: Verify compile**

```bash
zig build test
```

- [ ] **Step 3: Commit**

```bash
git add src/output.zig
git commit -m "feat: add text and JSON output formatters"
```

---

### Task 4: CLI argument parsing and command dispatch

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Write main.zig with full CLI**

Replace entire `src/main.zig`:
```zig
const std = @import("std");
const dict = @import("dict.zig");
const json_loader = @import("json_loader.zig");
const output = @import("output.zig");

const usage =
    \\Usage: mmcif-dict <command> [options] [arguments]
    \\
    \\Commands:
    \\  category [NAME]       List all categories or show details for NAME
    \\  item ITEM_NAME        Show item details (e.g., _atom_site.label_atom_id)
    \\  relations CATEGORY    Show parent-child relationships for CATEGORY
    \\  search QUERY          Search descriptions for QUERY
    \\
    \\Options:
    \\  --json                Output in JSON format
    \\  --dict PATH           Path to mmcif_pdbx.json
    \\  --help                Show this help
    \\
    \\Environment:
    \\  MMCIF_DICT_PATH       Default path to mmcif_pdbx.json
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    var format: output.Format = .text;
    var dict_path: ?[]const u8 = null;
    var positional = std.ArrayList([]const u8).init(allocator);
    defer positional.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try stdout.writeAll(usage);
            return;
        } else if (std.mem.eql(u8, arg, "--dict")) {
            i += 1;
            if (i >= args.len) {
                try stderr.writeAll("Error: --dict requires a path argument\n");
                std.process.exit(1);
            }
            dict_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--dict=")) {
            dict_path = arg[7..];
        } else {
            try positional.append(arg);
        }
    }

    if (positional.items.len == 0) {
        try stderr.writeAll(usage);
        std.process.exit(1);
    }

    // Resolve dictionary path: --dict > $MMCIF_DICT_PATH > exe_dir/../data/mmcif_pdbx.json
    const path = dict_path orelse
        std.process.getEnvVarOwned(allocator, "MMCIF_DICT_PATH") catch blk: {
        const exe_dir = std.fs.selfExeDirPathAlloc(allocator) catch {
            try stderr.writeAll("Error: cannot determine executable directory. Use --dict or set MMCIF_DICT_PATH.\n");
            std.process.exit(1);
        };
        break :blk try std.fmt.allocPrint(allocator, "{s}/../data/mmcif_pdbx.json", .{exe_dir});
    };

    var dictionary = json_loader.loadFromFile(allocator, path) catch |err| {
        try stderr.print("Error loading dictionary from {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer dictionary.deinit();

    const command = positional.items[0];
    const cmd_args = positional.items[1..];

    if (std.mem.eql(u8, command, "category")) {
        try runCategory(allocator, &dictionary, cmd_args, stdout, stderr, format);
    } else if (std.mem.eql(u8, command, "item")) {
        try runItem(allocator, &dictionary, cmd_args, stdout, stderr, format);
    } else if (std.mem.eql(u8, command, "relations")) {
        try runRelations(&dictionary, cmd_args, stdout, stderr, format);
    } else if (std.mem.eql(u8, command, "search")) {
        try runSearch(&dictionary, cmd_args, stdout, stderr, format);
    } else {
        try stderr.print("Unknown command: {s}\n\n", .{command});
        try stderr.writeAll(usage);
        std.process.exit(1);
    }
}

fn runCategory(
    allocator: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        var names = std.ArrayList([]const u8).init(allocator);
        defer names.deinit();
        var cat_iter = dictionary.categories.keyIterator();
        while (cat_iter.next()) |key| {
            try names.append(key.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        try output.printCategoryList(stdout, names.items, format);
    } else {
        const cat = dictionary.getCategory(cmd_args[0]) orelse {
            try stderr.print("Category not found: {s}\n", .{cmd_args[0]});
            std.process.exit(1);
        };
        try output.printCategory(stdout, cat, format);
    }
}

fn runItem(
    allocator: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try stderr.writeAll("Usage: mmcif-dict item ITEM_NAME\n");
        std.process.exit(1);
    }
    var name = cmd_args[0];
    // Normalize: add leading underscore if missing
    if (name.len > 0 and name[0] != '_') {
        name = try std.fmt.allocPrint(allocator, "_{s}", .{name});
    }
    const item = dictionary.getItem(name) orelse {
        try stderr.print("Item not found: {s}\n", .{name});
        std.process.exit(1);
    };
    try output.printItem(stdout, item, format);
}

fn runRelations(
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try stderr.writeAll("Usage: mmcif-dict relations CATEGORY\n");
        std.process.exit(1);
    }
    const rels = try dictionary.getRelationsForCategory(cmd_args[0]);
    try output.printRelations(stdout, cmd_args[0], rels, format);
}

fn runSearch(
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try stderr.writeAll("Usage: mmcif-dict search QUERY\n");
        std.process.exit(1);
    }
    _ = stderr;
    const results = try dictionary.searchDescriptions(cmd_args[0]);
    try output.printSearchResults(stdout, cmd_args[0], results, format);
}

test {
    _ = @import("dict.zig");
    _ = @import("json_loader.zig");
    _ = @import("output.zig");
}
```

- [ ] **Step 2: Build and test**

```bash
zig build
zig build test
```

- [ ] **Step 3: Test with actual dictionary data**

```bash
# Help
zig build run -- --help

# List categories
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json category | head -20

# Category details
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json category atom_site

# Item details
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json item _atom_site.label_atom_id

# Item with enumeration
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json item _atom_site.group_PDB

# Relations
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json relations atom_site

# Search
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json search "electron density"

# JSON output
zig build run -- --dict=/Users/nagaet/mmcif-dict-cli/data/mmcif_pdbx.json --json category atom_site
```

Verify each command produces correct output. Fix any issues before committing.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "feat: add CLI argument parsing and command dispatch"
```

---

## Chunk 3: Polish & PR

### Task 5: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
# mmcif-dict-cli

CLI tool for querying mmCIF PDBx dictionary definitions.

Uses PDBj's JSON representation of the mmCIF dictionary for fast lookups of categories, items, and their relationships.

## Setup

1. Download and decompress the PDBj dictionary JSON:

```bash
mkdir -p data
curl -o data/mmcif_pdbx.json.gz https://pdbj.org/dictionaries/mmcif_pdbx.json.gz
gunzip data/mmcif_pdbx.json.gz
```

2. Build:

```bash
zig build -Doptimize=ReleaseFast
```

The binary is at `zig-out/bin/mmcif-dict`.

## Usage

```bash
# List all categories (604 categories)
mmcif-dict category

# Show category details
mmcif-dict category atom_site

# Show item details
mmcif-dict item _atom_site.label_atom_id

# Show parent-child relationships
mmcif-dict relations atom_site

# Full-text search across descriptions
mmcif-dict search "electron density"

# JSON output (for AI tools / scripts)
mmcif-dict --json category atom_site
```

## Options

| Option | Description |
|--------|-------------|
| `--json` | Output in JSON format |
| `--dict PATH` | Path to `mmcif_pdbx.json` |
| `--help` | Show usage |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `MMCIF_DICT_PATH` | Default path to `mmcif_pdbx.json` (overrides exe-relative lookup) |

## Data Source

Dictionary data from [PDBj](https://pdbj.org/) (`mmcif_pdbx.json.gz`), a JSON representation of the [wwPDB mmCIF PDBx dictionary](http://mmcif.pdb.org/).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with setup and usage instructions"
```

### Task 6: Push and create PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feature/initial-setup
```

- [ ] **Step 2: Create PR**

```bash
gh pr create --title "feat: mmcif-dict CLI tool" --body "$(cat <<'EOF'
## Summary
- Zig CLI tool for querying mmCIF PDBx dictionary definitions
- Commands: category, item, relations, search
- Text and JSON output formats
- Uses PDBj JSON dictionary data

## Test plan
- [ ] `zig build test` passes
- [ ] `mmcif-dict category` lists all 604 categories
- [ ] `mmcif-dict category atom_site` shows description, keys, items
- [ ] `mmcif-dict item _atom_site.label_atom_id` shows item details
- [ ] `mmcif-dict item _atom_site.group_PDB` shows enumeration values
- [ ] `mmcif-dict relations atom_site` shows parent-child links
- [ ] `mmcif-dict search "electron density"` finds matching entries
- [ ] `--json` flag produces valid JSON for all commands
EOF
)"
```

---

- [ ] **DONE** - All phases complete
