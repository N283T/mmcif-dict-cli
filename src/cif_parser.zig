const std = @import("std");
const Allocator = std.mem.Allocator;

/// A CIF tag-value pair.
pub const Pair = struct {
    tag: []const u8,
    value: []const u8,
};

/// A CIF loop (table of tag-value columns).
pub const Loop = struct {
    tags: []const []const u8,
    values: []const []const u8,
    width: usize,

    pub fn rowCount(self: Loop) usize {
        if (self.width == 0) return 0;
        return self.values.len / self.width;
    }

    pub fn val(self: Loop, row: usize, col: usize) []const u8 {
        return self.values[row * self.width + col];
    }
};

/// An item in a CIF block or save frame.
pub const Item = union(enum) {
    pair: Pair,
    loop: Loop,
};

/// A CIF save frame.
pub const Frame = struct {
    name: []const u8,
    items: []const Item,
};

/// A CIF data block.
pub const Block = struct {
    name: []const u8,
    items: []const Item,
    frames: []const Frame,
};

/// A parsed CIF document.
pub const Document = struct {
    allocator: Allocator,
    blocks: []const Block,

    pub fn deinit(self: *Document) void {
        freeBlocks(self.allocator, self.blocks);
        self.allocator.free(self.blocks);
    }
};

fn freeItems(allocator: Allocator, items: []const Item) void {
    for (items) |item| {
        switch (item) {
            .loop => |loop| {
                allocator.free(loop.tags);
                allocator.free(loop.values);
            },
            .pair => {},
        }
    }
    allocator.free(items);
}

fn freeFrames(allocator: Allocator, frames: []const Frame) void {
    for (frames) |frame| freeItems(allocator, frame.items);
    allocator.free(frames);
}

fn freeBlocks(allocator: Allocator, blocks: []const Block) void {
    for (blocks) |block| {
        freeItems(allocator, block.items);
        freeFrames(allocator, block.frames);
    }
}

/// Parse CIF text into a Document.
pub fn parse(allocator: Allocator, input: []const u8) !Document {
    var parser = Parser.init(allocator, input);
    return parser.parseDocument();
}

const Parser = struct {
    allocator: Allocator,
    input: []const u8,
    pos: usize,

    fn init(allocator: Allocator, input: []const u8) Parser {
        return .{ .allocator = allocator, .input = input, .pos = 0 };
    }

    fn parseDocument(self: *Parser) !Document {
        var blocks: std.ArrayList(Block) = .empty;
        errdefer {
            freeBlocks(self.allocator, blocks.items);
            blocks.deinit(self.allocator);
        }

        self.skipWhitespaceAndComments();
        while (self.pos < self.input.len) {
            if (self.startsWithNoCase("data_")) {
                try blocks.append(self.allocator, try self.parseBlock());
            } else {
                self.pos += 1;
                self.skipWhitespaceAndComments();
            }
        }

        return .{
            .allocator = self.allocator,
            .blocks = try blocks.toOwnedSlice(self.allocator),
        };
    }

    fn parseBlock(self: *Parser) !Block {
        // Skip "data_"
        self.pos += 5;
        const name = self.readNonWhitespace();

        var items: std.ArrayList(Item) = .empty;
        errdefer {
            for (items.items) |item| switch (item) {
                .loop => |loop| {
                    self.allocator.free(loop.tags);
                    self.allocator.free(loop.values);
                },
                .pair => {},
            };
            items.deinit(self.allocator);
        }
        var frames: std.ArrayList(Frame) = .empty;
        errdefer {
            for (frames.items) |frame| freeItems(self.allocator, frame.items);
            frames.deinit(self.allocator);
        }

        self.skipWhitespaceAndComments();
        while (self.pos < self.input.len) {
            if (self.startsWithNoCase("data_")) break;
            if (self.startsWithNoCase("save_")) {
                if (self.isSaveEnd()) {
                    break;
                }
                try frames.append(self.allocator, try self.parseFrame());
            } else if (self.startsWithNoCase("loop_")) {
                try items.append(self.allocator, .{ .loop = try self.parseLoop() });
            } else if (self.pos < self.input.len and self.input[self.pos] == '_') {
                try items.append(self.allocator, .{ .pair = try self.parsePair() });
            } else {
                self.pos += 1;
                self.skipWhitespaceAndComments();
            }
        }

        return .{
            .name = name,
            .items = try items.toOwnedSlice(self.allocator),
            .frames = try frames.toOwnedSlice(self.allocator),
        };
    }

    fn parseFrame(self: *Parser) !Frame {
        // Skip "save_"
        self.pos += 5;
        const name = self.readNonWhitespace();

        var items: std.ArrayList(Item) = .empty;
        errdefer {
            for (items.items) |item| switch (item) {
                .loop => |loop| {
                    self.allocator.free(loop.tags);
                    self.allocator.free(loop.values);
                },
                .pair => {},
            };
            items.deinit(self.allocator);
        }

        self.skipWhitespaceAndComments();
        while (self.pos < self.input.len) {
            if (self.startsWithNoCase("save_") and self.isSaveEnd()) {
                // Consume "save_" end marker
                self.pos += 5;
                self.skipWhitespaceAndComments();
                break;
            } else if (self.startsWithNoCase("loop_")) {
                try items.append(self.allocator, .{ .loop = try self.parseLoop() });
            } else if (self.pos < self.input.len and self.input[self.pos] == '_') {
                try items.append(self.allocator, .{ .pair = try self.parsePair() });
            } else {
                self.pos += 1;
                self.skipWhitespaceAndComments();
            }
        }

        return .{
            .name = name,
            .items = try items.toOwnedSlice(self.allocator),
        };
    }

    fn isSaveEnd(self: *Parser) bool {
        // "save_" followed by whitespace/newline/EOF/comment = end marker
        // "save_<name>" = start of new frame
        if (self.pos + 5 > self.input.len) return false;
        if (!self.startsWithNoCase("save_")) return false;
        if (self.pos + 5 == self.input.len) return true;
        const ch = self.input[self.pos + 5];
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == '#';
    }

    fn parseLoop(self: *Parser) !Loop {
        // Skip "loop_"
        self.pos += 5;
        self.skipWhitespaceAndComments();

        var tags: std.ArrayList([]const u8) = .empty;
        errdefer tags.deinit(self.allocator);
        var values: std.ArrayList([]const u8) = .empty;
        errdefer values.deinit(self.allocator);

        // Read tags (start with _)
        while (self.pos < self.input.len and self.input[self.pos] == '_') {
            try tags.append(self.allocator, self.readNonWhitespace());
            self.skipWhitespaceAndComments();
        }

        const width = tags.items.len;

        // Read values until next keyword or tag
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '_') break;
            if (self.startsWithNoCase("loop_")) break;
            if (self.startsWithNoCase("save_")) break;
            if (self.startsWithNoCase("data_")) break;

            try values.append(self.allocator, self.readValue());
            self.skipWhitespaceAndComments();
        }

        // Truncate partial trailing row (malformed CIF)
        if (width > 0 and values.items.len % width != 0) {
            values.shrinkRetainingCapacity((values.items.len / width) * width);
        }

        return .{
            .tags = try tags.toOwnedSlice(self.allocator),
            .values = try values.toOwnedSlice(self.allocator),
            .width = width,
        };
    }

    fn parsePair(self: *Parser) !Pair {
        const tag = self.readNonWhitespace();
        self.skipWhitespaceAndComments();
        const value = self.readValue();
        self.skipWhitespaceAndComments();
        return .{ .tag = tag, .value = value };
    }

    fn readValue(self: *Parser) []const u8 {
        if (self.pos >= self.input.len) return "";

        const ch = self.input[self.pos];
        if (ch == '\'') return self.readQuoted('\'');
        if (ch == '"') return self.readQuoted('"');
        if (ch == ';' and (self.pos == 0 or self.input[self.pos - 1] == '\n' or self.input[self.pos - 1] == '\r')) {
            return self.readMultiLine();
        }
        return self.readNonWhitespace();
    }

    fn readQuoted(self: *Parser, quote: u8) []const u8 {
        self.pos += 1; // skip opening quote
        const start = self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == quote) {
                // Quote ends when followed by whitespace or EOF
                if (self.pos + 1 >= self.input.len or isWhitespace(self.input[self.pos + 1])) {
                    const result = self.input[start..self.pos];
                    self.pos += 1; // skip closing quote
                    return result;
                }
            }
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn readMultiLine(self: *Parser) []const u8 {
        self.pos += 1; // skip opening ;
        // CIF text fields include content on the same line as the opening ;
        // Skip only if the rest of the line is empty (whitespace-only).
        const line_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '\n') {
            self.pos += 1;
        }
        const line_has_content = for (self.input[line_start..self.pos]) |c| {
            if (c != ' ' and c != '\t' and c != '\r') break true;
        } else false;
        if (self.pos < self.input.len) self.pos += 1; // skip \n
        const start = if (line_has_content) line_start else self.pos;
        while (self.pos < self.input.len) {
            if (self.input[self.pos] == ';' and (self.pos == 0 or self.input[self.pos - 1] == '\n')) {
                // Strip trailing \n (and \r\n)
                var end = self.pos;
                if (end > start and self.input[end - 1] == '\n') end -= 1;
                if (end > start and self.input[end - 1] == '\r') end -= 1;
                const result_end = end;
                self.pos += 1; // skip closing ;
                return self.input[start..result_end];
            }
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn readNonWhitespace(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.pos < self.input.len and !isWhitespace(self.input[self.pos])) {
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn skipWhitespaceAndComments(self: *Parser) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '#') {
                // Skip to end of line
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else if (isWhitespace(ch)) {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn startsWithNoCase(self: *Parser, prefix: []const u8) bool {
        if (self.pos + prefix.len > self.input.len) return false;
        for (self.input[self.pos .. self.pos + prefix.len], prefix) |a, b| {
            if (std.ascii.toLower(a) != b) return false;
        }
        return true;
    }

    fn isWhitespace(ch: u8) bool {
        return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
    }
};

// --- Tests ---

test "parse simple tag-value pairs" {
    const allocator = std.testing.allocator;
    const input =
        \\data_test
        \\_tag1 value1
        \\_tag2 'quoted value'
    ;
    var doc = try parse(allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks.len);
    try std.testing.expectEqualStrings("test", doc.blocks[0].name);
    try std.testing.expectEqual(@as(usize, 2), doc.blocks[0].items.len);

    const p1 = doc.blocks[0].items[0].pair;
    try std.testing.expectEqualStrings("_tag1", p1.tag);
    try std.testing.expectEqualStrings("value1", p1.value);

    const p2 = doc.blocks[0].items[1].pair;
    try std.testing.expectEqualStrings("_tag2", p2.tag);
    try std.testing.expectEqualStrings("quoted value", p2.value);
}

test "parse loop" {
    const allocator = std.testing.allocator;
    const input =
        \\data_test
        \\loop_
        \\_col1
        \\_col2
        \\a b
        \\c d
    ;
    var doc = try parse(allocator, input);
    defer doc.deinit();

    const loop = doc.blocks[0].items[0].loop;
    try std.testing.expectEqual(@as(usize, 2), loop.tags.len);
    try std.testing.expectEqual(@as(usize, 2), loop.rowCount());
    try std.testing.expectEqualStrings("a", loop.val(0, 0));
    try std.testing.expectEqualStrings("d", loop.val(1, 1));
}

test "parse save frames" {
    const allocator = std.testing.allocator;
    const input =
        \\data_test.dic
        \\save_my_category
        \\  _category.id  my_category
        \\  _category.description 'A test'
        \\save_
        \\save__my_category.id
        \\  _item.name '_my_category.id'
        \\  _item.category_id my_category
        \\save_
    ;
    var doc = try parse(allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.blocks[0].frames.len);
    try std.testing.expectEqualStrings("my_category", doc.blocks[0].frames[0].name);
    try std.testing.expectEqualStrings("_my_category.id", doc.blocks[0].frames[1].name);

    const cat_id = doc.blocks[0].frames[0].items[0].pair;
    try std.testing.expectEqualStrings("_category.id", cat_id.tag);
    try std.testing.expectEqualStrings("my_category", cat_id.value);
}

test "parse multi-line string" {
    const allocator = std.testing.allocator;
    const input = "data_test\n_desc\n;\nLine 1\nLine 2\n;\n";
    var doc = try parse(allocator, input);
    defer doc.deinit();

    const pair = doc.blocks[0].items[0].pair;
    try std.testing.expectEqualStrings("Line 1\nLine 2", pair.value);
}

test "parse empty multi-line string" {
    const allocator = std.testing.allocator;
    const input = "data_test\n_desc\n;\n;\n";
    var doc = try parse(allocator, input);
    defer doc.deinit();

    const pair = doc.blocks[0].items[0].pair;
    try std.testing.expectEqualStrings("", pair.value);
}

test "parse comments" {
    const allocator = std.testing.allocator;
    const input =
        \\# This is a comment
        \\data_test
        \\# Another comment
        \\_tag1 value1
    ;
    var doc = try parse(allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.blocks[0].items.len);
    try std.testing.expectEqualStrings("value1", doc.blocks[0].items[0].pair.value);
}
