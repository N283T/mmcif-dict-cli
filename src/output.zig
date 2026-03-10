const std = @import("std");
const dict = @import("dict.zig");

pub const Format = enum { text, json };

pub fn printCategory(w: *std.io.Writer, cat: dict.Category, format: Format) !void {
    switch (format) {
        .text => {
            try w.print("Category: {s}\n", .{cat.id});
            try w.print("Mandatory: {s}\n", .{cat.mandatory_code});
            if (cat.key_names.len > 0) {
                try w.print("Keys: ", .{});
                for (cat.key_names, 0..) |k, i| {
                    if (i > 0) try w.print(", ", .{});
                    try w.print("{s}", .{k});
                }
                try w.print("\n", .{});
            }
            if (cat.group_ids.len > 0) {
                try w.print("Groups: ", .{});
                for (cat.group_ids, 0..) |g, i| {
                    if (i > 0) try w.print(", ", .{});
                    try w.print("{s}", .{g});
                }
                try w.print("\n", .{});
            }
            try w.print("\nDescription:\n{s}\n", .{cat.description});
            if (cat.items.len > 0) {
                try w.print("\nItems ({d}):\n", .{cat.items.len});
                for (cat.items) |item| {
                    try w.print("  {s}\n", .{item});
                }
            }
        },
        .json => {
            try w.print("{{\"id\":", .{});
            try writeJsonString(w, cat.id);
            try w.print(",\"description\":", .{});
            try writeJsonString(w, cat.description);
            try w.print(",\"mandatory_code\":", .{});
            try writeJsonString(w, cat.mandatory_code);
            try w.print(",\"keys\":", .{});
            try writeJsonStringArray(w, cat.key_names);
            try w.print(",\"groups\":", .{});
            try writeJsonStringArray(w, cat.group_ids);
            try w.print(",\"items\":", .{});
            try writeJsonStringArray(w, cat.items);
            try w.print("}}\n", .{});
        },
    }
}

pub fn printItem(w: *std.io.Writer, item: dict.Item, format: Format) !void {
    switch (format) {
        .text => {
            try w.print("Item: {s}\n", .{item.name});
            try w.print("Category: {s}\n", .{item.category_id});
            try w.print("Type: {s}\n", .{item.type_code});
            try w.print("Mandatory: {s}\n", .{item.mandatory_code});
            try w.print("\nDescription:\n{s}\n", .{item.description});
            if (item.enum_values.len > 0) {
                try w.print("\nAllowed values:\n", .{});
                for (item.enum_values) |v| {
                    try w.print("  {s}\n", .{v});
                }
            }
        },
        .json => {
            try w.print("{{\"name\":", .{});
            try writeJsonString(w, item.name);
            try w.print(",\"category_id\":", .{});
            try writeJsonString(w, item.category_id);
            try w.print(",\"type\":", .{});
            try writeJsonString(w, item.type_code);
            try w.print(",\"mandatory\":", .{});
            try writeJsonString(w, item.mandatory_code);
            try w.print(",\"description\":", .{});
            try writeJsonString(w, item.description);
            try w.print(",\"enum_values\":", .{});
            try writeJsonStringArray(w, item.enum_values);
            try w.print("}}\n", .{});
        },
    }
}

pub fn printRelations(w: *std.io.Writer, category_id: []const u8, rels: []const dict.Relation, format: Format) !void {
    switch (format) {
        .text => {
            try w.print("Relations for: {s}\n\n", .{category_id});
            if (rels.len == 0) {
                try w.print("  No relations found.\n", .{});
                return;
            }
            for (rels) |rel| {
                if (std.mem.eql(u8, rel.child_category_id, category_id)) {
                    try w.print("  {s} -> {s} (parent: {s})\n", .{
                        rel.child_name, rel.parent_name, rel.parent_category_id,
                    });
                } else {
                    try w.print("  {s} <- {s} (child: {s})\n", .{
                        rel.parent_name, rel.child_name, rel.child_category_id,
                    });
                }
            }
        },
        .json => {
            try w.print("{{\"category\":", .{});
            try writeJsonString(w, category_id);
            try w.print(",\"relations\":[", .{});
            for (rels, 0..) |rel, i| {
                if (i > 0) try w.print(",", .{});
                try w.print("{{\"child_name\":", .{});
                try writeJsonString(w, rel.child_name);
                try w.print(",\"parent_name\":", .{});
                try writeJsonString(w, rel.parent_name);
                try w.print(",\"child_category\":", .{});
                try writeJsonString(w, rel.child_category_id);
                try w.print(",\"parent_category\":", .{});
                try writeJsonString(w, rel.parent_category_id);
                try w.print("}}", .{});
            }
            try w.print("]}}\n", .{});
        },
    }
}

pub fn printSearchResults(w: *std.io.Writer, query: []const u8, results: dict.SearchResults, format: Format) !void {
    switch (format) {
        .text => {
            if (results.categories.len > 0) {
                try w.print("Categories ({d}):\n", .{results.categories.len});
                for (results.categories) |cat| {
                    const snippet = dict.extractSnippet(cat.description, query, 40);
                    try w.print("  {s}\n    ...{s}...\n", .{ cat.id, snippet });
                }
            }
            if (results.items.len > 0) {
                try w.print("\nItems ({d}):\n", .{results.items.len});
                for (results.items) |item| {
                    const snippet = dict.extractSnippet(item.description, query, 40);
                    try w.print("  {s}\n    ...{s}...\n", .{ item.name, snippet });
                }
            }
            if (results.categories.len == 0 and results.items.len == 0) {
                try w.print("No results found.\n", .{});
            }
        },
        .json => {
            try w.print("{{\"query\":", .{});
            try writeJsonString(w, query);
            try w.print(",\"categories\":[", .{});
            for (results.categories, 0..) |cat, i| {
                if (i > 0) try w.print(",", .{});
                try writeJsonString(w, cat.id);
            }
            try w.print("],\"items\":[", .{});
            for (results.items, 0..) |item, i| {
                if (i > 0) try w.print(",", .{});
                try writeJsonString(w, item.name);
            }
            try w.print("]}}\n", .{});
        },
    }
}

pub fn printCategoryList(w: *std.io.Writer, names: []const []const u8, format: Format) !void {
    switch (format) {
        .text => {
            for (names) |name| {
                try w.print("{s}\n", .{name});
            }
        },
        .json => {
            try writeJsonStringArray(w, names);
            try w.print("\n", .{});
        },
    }
}

fn writeJsonString(w: *std.io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                try w.print("\\u{x:0>4}", .{c});
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeJsonStringArray(w: *std.io.Writer, arr: []const []const u8) !void {
    try w.writeByte('[');
    for (arr, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonString(w, s);
    }
    try w.writeByte(']');
}

test "writeJsonString escapes special characters" {
    // Write to a temporary file to get a *std.io.Writer
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("test_json.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);

    try writeJsonString(&w.interface, "hello\x00world\x01\n\"\\");
    try w.interface.flush();

    try file.seekTo(0);
    var read_buf: [256]u8 = undefined;
    const n = try file.readAll(&read_buf);
    try std.testing.expectEqualStrings("\"hello\\u0000world\\u0001\\n\\\"\\\\\"", read_buf[0..n]);
}

test "writeJsonString handles tab and backslash" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("test_json2.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var w = file.writer(&buf);

    try writeJsonString(&w.interface, "a\tb\\c");
    try w.interface.flush();

    try file.seekTo(0);
    var read_buf: [256]u8 = undefined;
    const n = try file.readAll(&read_buf);
    try std.testing.expectEqualStrings("\"a\\tb\\\\c\"", read_buf[0..n]);
}
