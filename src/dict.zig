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
    arena: std.heap.ArenaAllocator,
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

    pub fn getRelationsForCategory(self: *const Dictionary, allocator: Allocator, category_id: []const u8) ![]const Relation {
        var results: std.ArrayList(Relation) = .empty;
        defer results.deinit(allocator);
        for (self.relations) |rel| {
            if (std.mem.eql(u8, rel.child_category_id, category_id) or
                std.mem.eql(u8, rel.parent_category_id, category_id))
            {
                try results.append(allocator, rel);
            }
        }
        return results.toOwnedSlice(allocator);
    }

    pub fn searchDescriptions(self: *const Dictionary, allocator: Allocator, query: []const u8) !SearchResults {
        var cat_results: std.ArrayList(Category) = .empty;
        defer cat_results.deinit(allocator);
        var item_results: std.ArrayList(Item) = .empty;
        defer item_results.deinit(allocator);

        var cat_iter = self.categories.valueIterator();
        while (cat_iter.next()) |cat| {
            if (containsInsensitive(cat.description, query)) {
                try cat_results.append(allocator, cat.*);
            }
        }

        var item_iter = self.items.valueIterator();
        while (item_iter.next()) |item| {
            if (containsInsensitive(item.description, query)) {
                try item_results.append(allocator, item.*);
            }
        }

        return .{
            .categories = try cat_results.toOwnedSlice(allocator),
            .items = try item_results.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Dictionary) void {
        self.categories.deinit();
        self.items.deinit();
        self.gpa.free(self.relations);
        self.arena.deinit();
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
