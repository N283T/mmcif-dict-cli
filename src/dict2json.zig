const std = @import("std");
const cif = @import("cif_parser.zig");
const Allocator = std.mem.Allocator;

/// Convert a CIF dictionary document to PDBj-compatible JSON format.
/// Only the first data block is converted; additional blocks are ignored.
/// Writes the output to the given writer.
pub fn convert(allocator: Allocator, doc: cif.Document, w: *std.io.Writer) !void {
    if (doc.blocks.len == 0) return error.EmptyDocument;

    const block = doc.blocks[0];

    try w.writeAll("{\n  ");
    try writeJsonString(w, block.name);
    try w.writeAll(": {\n");

    var first_outer = true;

    // Collect root-level pairs and group them together
    var root_pairs: std.ArrayList(cif.Pair) = .empty;
    defer root_pairs.deinit(allocator);
    for (block.items) |item| {
        switch (item) {
            .pair => |pair| try root_pairs.append(allocator, pair),
            .loop => {},
        }
    }
    if (root_pairs.items.len > 0) {
        if (!first_outer) try w.writeAll(",\n");
        first_outer = false;
        try writePairGrouped(allocator, root_pairs.items, w, 4);
    }

    // Write root-level loops
    for (block.items) |item| {
        switch (item) {
            .loop => |loop| {
                if (!first_outer) try w.writeAll(",\n");
                first_outer = false;
                try writeLoopGrouped(allocator, loop, w, 4);
            },
            .pair => {},
        }
    }

    // Write save frames
    for (block.frames) |frame| {
        if (!first_outer) try w.writeAll(",\n");
        first_outer = false;
        try writeFrame(allocator, frame, w, 4);
    }

    try w.writeAll("\n  }\n}\n");
}

/// Write a save frame as a JSON object.
/// "save_<name>": { grouped tag-value pairs and loops }
fn writeFrame(allocator: Allocator, frame: cif.Frame, w: *std.io.Writer, indent: usize) !void {
    try writeIndent(w, indent);
    try w.writeAll("\"save_");
    // Frame names are safe ASCII identifiers, but escape for correctness
    for (frame.name) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(ch),
        }
    }
    try w.writeAll("\": {\n");

    var first = true;

    // Collect all pairs and group them
    var pairs: std.ArrayList(cif.Pair) = .empty;
    defer pairs.deinit(allocator);

    for (frame.items) |item| {
        switch (item) {
            .pair => |pair| try pairs.append(allocator, pair),
            .loop => {},
        }
    }

    if (pairs.items.len > 0) {
        if (!first) try w.writeAll(",\n");
        first = false;
        try writePairGrouped(allocator, pairs.items, w, indent + 2);
    }

    // Write loops
    for (frame.items) |item| {
        switch (item) {
            .loop => |loop| {
                if (!first) try w.writeAll(",\n");
                first = false;
                try writeLoopGrouped(allocator, loop, w, indent + 2);
            },
            .pair => {},
        }
    }

    try w.writeByte('\n');
    try writeIndent(w, indent);
    try w.writeByte('}');
}

const FieldValue = struct { field: []const u8, value: []const u8 };
const FieldCol = struct { field: []const u8, col_idx: usize };

/// Group pairs by their tag category prefix and write as JSON objects.
/// E.g., _category.id → "category": {"id": ["value"]}
fn writePairGrouped(allocator: Allocator, pairs: []const cif.Pair, w: *std.io.Writer, indent: usize) !void {
    const GroupEntry = struct {
        key: []const u8,
        values: std.ArrayList(FieldValue),
    };
    var groups: std.ArrayList(GroupEntry) = .empty;
    defer {
        for (groups.items) |*g| g.values.deinit(allocator);
        groups.deinit(allocator);
    }

    for (pairs) |pair| {
        const cat_field = splitTag(pair.tag);
        const cat = cat_field[0];
        const field = cat_field[1];

        var found = false;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.key, cat)) {
                try g.values.append(allocator, .{ .field = field, .value = pair.value });
                found = true;
                break;
            }
        }
        if (!found) {
            var new_values: std.ArrayList(FieldValue) = .empty;
            try new_values.append(allocator, .{ .field = field, .value = pair.value });
            try groups.append(allocator, .{ .key = cat, .values = new_values });
        }
    }

    for (groups.items, 0..) |group, gi| {
        if (gi > 0) try w.writeAll(",\n");
        try writeIndent(w, indent);
        try writeJsonKey(w, group.key);
        try w.writeAll("{\n");
        for (group.values.items, 0..) |entry, ei| {
            if (ei > 0) try w.writeAll(",\n");
            try writeIndent(w, indent + 2);
            try writeJsonKey(w, entry.field);
            try w.writeAll("[\n");
            try writeIndent(w, indent + 4);
            try writeJsonString(w, entry.value);
            try w.writeByte('\n');
            try writeIndent(w, indent + 2);
            try w.writeByte(']');
        }
        try w.writeByte('\n');
        try writeIndent(w, indent);
        try w.writeByte('}');
    }
}

/// Group a loop's columns by tag category prefix and write as JSON.
/// E.g., loop_ _cat.f1 _cat.f2 v1 v2 v3 v4 →
///   "cat": {"f1": ["v1", "v3"], "f2": ["v2", "v4"]}
fn writeLoopGrouped(allocator: Allocator, loop: cif.Loop, w: *std.io.Writer, indent: usize) !void {
    if (loop.width() == 0) return;

    const GroupCol = struct {
        key: []const u8,
        cols: std.ArrayList(FieldCol),
    };
    var groups: std.ArrayList(GroupCol) = .empty;
    defer {
        for (groups.items) |*g| g.cols.deinit(allocator);
        groups.deinit(allocator);
    }

    for (loop.tags, 0..) |tag, col_idx| {
        const cat_field = splitTag(tag);
        const cat = cat_field[0];
        const field = cat_field[1];

        var found = false;
        for (groups.items) |*g| {
            if (std.mem.eql(u8, g.key, cat)) {
                try g.cols.append(allocator, .{ .field = field, .col_idx = col_idx });
                found = true;
                break;
            }
        }
        if (!found) {
            var new_cols: std.ArrayList(FieldCol) = .empty;
            try new_cols.append(allocator, .{ .field = field, .col_idx = col_idx });
            try groups.append(allocator, .{ .key = cat, .cols = new_cols });
        }
    }

    const rows = loop.rowCount();

    for (groups.items, 0..) |group, gi| {
        if (gi > 0) try w.writeAll(",\n");
        try writeIndent(w, indent);
        try writeJsonKey(w, group.key);
        try w.writeAll("{\n");

        for (group.cols.items, 0..) |col, ci| {
            if (ci > 0) try w.writeAll(",\n");
            try writeIndent(w, indent + 2);
            try writeJsonKey(w, col.field);
            try w.writeAll("[\n");
            for (0..rows) |row| {
                if (row > 0) try w.writeAll(",\n");
                try writeIndent(w, indent + 4);
                try writeJsonString(w, loop.val(row, col.col_idx));
            }
            try w.writeByte('\n');
            try writeIndent(w, indent + 2);
            try w.writeByte(']');
        }
        try w.writeByte('\n');
        try writeIndent(w, indent);
        try w.writeByte('}');
    }
}

/// Split a CIF tag like "_category.field" into ("category", "field").
/// If no dot, returns (tag_without_underscore, tag_without_underscore).
fn splitTag(tag: []const u8) [2][]const u8 {
    const start: usize = if (tag.len > 0 and tag[0] == '_') 1 else 0;
    const body = tag[start..];
    if (std.mem.indexOfScalar(u8, body, '.')) |dot| {
        return .{ body[0..dot], body[dot + 1 ..] };
    }
    return .{ body, body };
}

/// Write a JSON key (escaped string followed by ": ").
fn writeJsonKey(w: *std.io.Writer, s: []const u8) !void {
    try writeJsonString(w, s);
    try w.writeAll(": ");
}

fn writeIndent(w: *std.io.Writer, n: usize) !void {
    for (0..n) |_| try w.writeByte(' ');
}

/// Write a JSON-escaped string value.
fn writeJsonString(w: *std.io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 0x20) {
                    try w.print("\\u{x:0>4}", .{@as(u16, ch)});
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

// --- Test helpers ---

fn testConvert(allocator: Allocator, doc: cif.Document) ![]u8 {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("output.json", .{ .read = true });
    defer file.close();

    var wbuf: [65536]u8 = undefined;
    var fw = file.writer(&wbuf);
    try convert(allocator, doc, &fw.interface);
    try fw.interface.flush();

    const stat = try file.stat();
    const size = stat.size;
    try file.seekTo(0);
    const result = try allocator.alloc(u8, size);
    const n = try file.readAll(result);
    return result[0..n];
}

// --- Tests ---

test "convert simple CIF to JSON" {
    const allocator = std.testing.allocator;
    const input =
        \\data_test.dic
        \\  _datablock.id test.dic
        \\save_my_cat
        \\  _category.id my_cat
        \\  _category.description 'A test category'
        \\save_
        \\save__my_cat.field1
        \\  _item.name '_my_cat.field1'
        \\  _item.category_id my_cat
        \\  _item_description.description 'First field'
        \\save_
    ;
    var doc = try cif.parse(allocator, input);
    defer doc.deinit();

    const output = try testConvert(allocator, doc);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"test.dic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"save_my_cat\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"save__my_cat.field1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"category\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"my_cat\"") != null);
}

test "convert loop to JSON" {
    const allocator = std.testing.allocator;
    const input =
        \\data_test.dic
        \\save_my_cat
        \\  _category.id my_cat
        \\  loop_
        \\  _category_key.name
        \\  '_my_cat.id'
        \\  '_my_cat.name'
        \\save_
    ;
    var doc = try cif.parse(allocator, input);
    defer doc.deinit();

    const output = try testConvert(allocator, doc);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"category_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"_my_cat.id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"_my_cat.name\"") != null);
}

test "convert returns EmptyDocument for no blocks" {
    const allocator = std.testing.allocator;
    const input = "# just a comment\n";
    var doc = try cif.parse(allocator, input);
    defer doc.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("empty.json", .{});
    defer file.close();

    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(&wbuf);
    try std.testing.expectError(error.EmptyDocument, convert(allocator, doc, &fw.interface));
}

test "splitTag separates category and field" {
    const result1 = splitTag("_category.field");
    try std.testing.expectEqualStrings("category", result1[0]);
    try std.testing.expectEqualStrings("field", result1[1]);

    const result2 = splitTag("_item_description.description");
    try std.testing.expectEqualStrings("item_description", result2[0]);
    try std.testing.expectEqualStrings("description", result2[1]);

    const result3 = splitTag("_nodot");
    try std.testing.expectEqualStrings("nodot", result3[0]);
    try std.testing.expectEqualStrings("nodot", result3[1]);
}

test "writeJsonString escapes special characters" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("test_escape.txt", .{ .read = true });
    defer file.close();

    var wbuf: [4096]u8 = undefined;
    var fw = file.writer(&wbuf);
    try writeJsonString(&fw.interface, "hello \"world\"\nline2");
    try fw.interface.flush();

    try file.seekTo(0);
    var read_buf: [256]u8 = undefined;
    const n = try file.readAll(&read_buf);
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\nline2\"", read_buf[0..n]);
}
