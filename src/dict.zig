const std = @import("std");
const fmt = @import("mdict_format.zig");
const reader = @import("mdict_reader.zig");
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
    gpa: Allocator,
    buf: []const u8,
    owns_buf: bool,
    view: reader.View,
    arrays: std.ArrayList([]const []const u8) = .empty,

    pub fn loadFromFile(gpa: Allocator, path: []const u8) !Dictionary {
        const result = try reader.loadFromFile(gpa, path);
        return .{ .gpa = gpa, .buf = result.buf, .owns_buf = true, .view = result.view };
    }

    pub fn loadFromBuf(gpa: Allocator, buf: []const u8) !Dictionary {
        const v = try reader.load(buf);
        return .{ .gpa = gpa, .buf = buf, .owns_buf = false, .view = v };
    }

    pub fn deinit(self: *Dictionary) void {
        for (self.arrays.items) |arr| self.gpa.free(arr);
        self.arrays.deinit(self.gpa);
        if (self.owns_buf) self.gpa.free(self.buf);
    }

    pub fn categoryCount(self: *const Dictionary) usize {
        return self.view.categories.len;
    }

    pub fn getCategory(self: *Dictionary, name: []const u8) !?Category {
        const idx = findByKey(self, name, self.view.categories.len, categoryKey) orelse return null;
        return try self.materializeCategory(idx);
    }

    pub fn getItem(self: *Dictionary, name: []const u8) !?Item {
        const idx = findByKey(self, name, self.view.items.len, itemKey) orelse return null;
        return try self.materializeItem(idx);
    }

    pub fn listCategoryNames(self: *const Dictionary, allocator: Allocator) ![][]const u8 {
        const out = try allocator.alloc([]const u8, self.view.categories.len);
        for (self.view.categories, 0..) |rec, i| out[i] = self.view.resolveStr(rec.id);
        return out;
    }

    pub fn getRelationsForCategory(self: *Dictionary, allocator: Allocator, category_id: []const u8) ![]const Relation {
        var list: std.ArrayList(Relation) = .empty;
        errdefer list.deinit(allocator);

        // Relations are sorted by child_category_id; binary search for the first match.
        const start = lowerBoundKey(self, category_id, self.view.relations.len, relationChildKey);
        var i: usize = start;
        while (i < self.view.relations.len) : (i += 1) {
            const rec = self.view.relations[i];
            if (!std.mem.eql(u8, self.view.resolveStr(rec.child_category_id), category_id)) break;
            try list.append(allocator, self.materializeRelation(rec));
        }
        // Include rows where this category is the parent (linear scan — rare path).
        for (self.view.relations) |rec| {
            if (std.mem.eql(u8, self.view.resolveStr(rec.parent_category_id), category_id) and
                !std.mem.eql(u8, self.view.resolveStr(rec.child_category_id), category_id))
            {
                try list.append(allocator, self.materializeRelation(rec));
            }
        }
        return list.toOwnedSlice(allocator);
    }

    pub fn searchDescriptions(self: *Dictionary, allocator: Allocator, query: []const u8) !SearchResults {
        var cats: std.ArrayList(Category) = .empty;
        errdefer cats.deinit(allocator);
        var items: std.ArrayList(Item) = .empty;
        errdefer items.deinit(allocator);

        for (self.view.categories, 0..) |rec, i| {
            if (containsInsensitive(self.view.resolveStr(rec.description), query)) {
                try cats.append(allocator, try self.materializeCategory(i));
            }
        }
        for (self.view.items, 0..) |rec, i| {
            if (containsInsensitive(self.view.resolveStr(rec.description), query)) {
                try items.append(allocator, try self.materializeItem(i));
            }
        }
        return .{
            .categories = try cats.toOwnedSlice(allocator),
            .items = try items.toOwnedSlice(allocator),
        };
    }

    // --- private ---

    fn materializeCategory(self: *Dictionary, idx: usize) !Category {
        const rec = self.view.categories[idx];
        return .{
            .id = self.view.resolveStr(rec.id),
            .description = self.view.resolveStr(rec.description),
            .mandatory_code = self.view.resolveStr(rec.mandatory_code),
            .key_names = try self.strArrayToSlice(rec.key_names),
            .group_ids = try self.strArrayToSlice(rec.group_ids),
            .example_details = try self.strArrayToSlice(rec.example_details),
            .example_cases = try self.strArrayToSlice(rec.example_cases),
            .items = try self.strArrayToSlice(rec.items),
        };
    }

    fn materializeItem(self: *Dictionary, idx: usize) !Item {
        const rec = self.view.items[idx];
        return .{
            .name = self.view.resolveStr(rec.name),
            .category_id = self.view.resolveStr(rec.category_id),
            .description = self.view.resolveStr(rec.description),
            .mandatory_code = self.view.resolveStr(rec.mandatory_code),
            .type_code = self.view.resolveStr(rec.type_code),
            .enum_values = try self.strArrayToSlice(rec.enum_values),
        };
    }

    fn materializeRelation(self: *const Dictionary, rec: fmt.RelationRecord) Relation {
        return .{
            .child_category_id = self.view.resolveStr(rec.child_category_id),
            .parent_category_id = self.view.resolveStr(rec.parent_category_id),
            .child_name = self.view.resolveStr(rec.child_name),
            .parent_name = self.view.resolveStr(rec.parent_name),
            .link_group_id = self.view.resolveStr(rec.link_group_id),
        };
    }

    /// Allocates `[]const []const u8` on the GPA, stored in `self.arrays`
    /// and freed on `deinit`. Propagates OOM to the caller rather than
    /// returning an empty slice silently (which would misreport data as
    /// missing).
    fn strArrayToSlice(self: *Dictionary, ref: fmt.StrArrayRef) ![]const []const u8 {
        if (ref.count == 0) return &.{};
        const out = try self.gpa.alloc([]const u8, ref.count);
        errdefer self.gpa.free(out);
        self.view.resolveStrArray(ref, out);
        try self.arrays.append(self.gpa, out);
        return out;
    }
};

fn categoryKey(d: *const Dictionary, idx: usize) []const u8 {
    return d.view.resolveStr(d.view.categories[idx].id);
}

fn itemKey(d: *const Dictionary, idx: usize) []const u8 {
    return d.view.resolveStr(d.view.items[idx].name);
}

fn relationChildKey(d: *const Dictionary, idx: usize) []const u8 {
    return d.view.resolveStr(d.view.relations[idx].child_category_id);
}

fn findByKey(
    d: *const Dictionary,
    needle: []const u8,
    len: usize,
    comptime keyFn: fn (*const Dictionary, usize) []const u8,
) ?usize {
    var lo: usize = 0;
    var hi: usize = len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cmp = std.mem.order(u8, keyFn(d, mid), needle);
        if (cmp == .eq) return mid;
        if (cmp == .lt) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn lowerBoundKey(
    d: *const Dictionary,
    needle: []const u8,
    len: usize,
    comptime keyFn: fn (*const Dictionary, usize) []const u8,
) usize {
    var lo: usize = 0;
    var hi: usize = len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, keyFn(d, mid), needle) == .lt) lo = mid + 1 else hi = mid;
    }
    return lo;
}

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
    try std.testing.expect(containsInsensitive("Electron Density Map", "electron density"));
    try std.testing.expect(containsInsensitive("HELLO WORLD", "hello"));
    try std.testing.expect(!containsInsensitive("hello", "world"));
    try std.testing.expect(containsInsensitive("abc", ""));
    try std.testing.expect(!containsInsensitive("", "abc"));
}

test "containsInsensitive edge cases" {
    try std.testing.expect(containsInsensitive("a", "a"));
    try std.testing.expect(!containsInsensitive("a", "ab"));
    try std.testing.expect(containsInsensitive("ABC DEF", "c d"));
}

test "extractSnippet" {
    const text = "Data items in the ATOM_SITE category record details about the atom sites";
    const snippet = extractSnippet(text, "atom_site", 10);
    try std.testing.expect(snippet.len > 0);
    try std.testing.expect(containsInsensitive(snippet, "atom_site"));
}

test "Dictionary.loadFromFile on tiny fixture" {
    const allocator = std.testing.allocator;
    var d = try Dictionary.loadFromFile(allocator, "testdata/tiny.mdict");
    defer d.deinit();

    try std.testing.expectEqual(@as(usize, 1), d.categoryCount());
    const cat = (try d.getCategory("tiny_cat")).?;
    try std.testing.expectEqualStrings("tiny_cat", cat.id);
    try std.testing.expectEqualStrings("A tiny category", cat.description);

    const item = (try d.getItem("_tiny_cat.id")).?;
    try std.testing.expectEqualStrings("int", item.type_code);
    try std.testing.expectEqualStrings("tiny_cat", item.category_id);

    const rels = try d.getRelationsForCategory(allocator, "tiny_cat");
    defer allocator.free(rels);
    try std.testing.expectEqual(@as(usize, 1), rels.len);
    try std.testing.expectEqualStrings("parent_cat", rels[0].parent_category_id);
    try std.testing.expectEqualStrings("_tiny_cat.parent_id", rels[0].child_name);
}

test "Dictionary.getCategory on missing category returns null" {
    const allocator = std.testing.allocator;
    var d = try Dictionary.loadFromFile(allocator, "testdata/tiny.mdict");
    defer d.deinit();
    try std.testing.expectEqual(@as(?Category, null), try d.getCategory("nonexistent"));
    try std.testing.expectEqual(@as(?Item, null), try d.getItem("_not_a_real.item"));
}

test "Dictionary.searchDescriptions finds matches" {
    const allocator = std.testing.allocator;
    var d = try Dictionary.loadFromFile(allocator, "testdata/tiny.mdict");
    defer d.deinit();

    const results = try d.searchDescriptions(allocator, "tiny");
    defer allocator.free(results.categories);
    defer allocator.free(results.items);
    try std.testing.expectEqual(@as(usize, 1), results.categories.len);
    try std.testing.expectEqualStrings("tiny_cat", results.categories[0].id);
}
