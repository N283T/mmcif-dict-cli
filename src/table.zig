const std = @import("std");

pub const Align = enum { left, right };

pub const Column = struct {
    header: []const u8,
    @"align": Align = .left,
};

pub const Style = enum { boxed, tsv };

pub const Options = struct {
    style: Style,
    /// Only used by .boxed. Must be > 0.
    terminal_width: usize = 80,
};

pub fn render(
    gpa: std.mem.Allocator,
    w: *std.io.Writer,
    cols: []const Column,
    rows: []const []const []const u8,
    opts: Options,
) !void {
    switch (opts.style) {
        .tsv => try renderTsv(w, cols, rows),
        .boxed => try renderBoxed(gpa, w, cols, rows, opts.terminal_width),
    }
}

fn renderTsv(
    w: *std.io.Writer,
    cols: []const Column,
    rows: []const []const []const u8,
) !void {
    for (cols, 0..) |c, i| {
        if (i > 0) try w.writeByte('\t');
        try w.writeAll(c.header);
    }
    try w.writeByte('\n');
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i > 0) try w.writeByte('\t');
            try w.writeAll(cell);
        }
        try w.writeByte('\n');
    }
}

fn renderBoxed(
    gpa: std.mem.Allocator,
    w: *std.io.Writer,
    cols: []const Column,
    rows: []const []const []const u8,
    terminal_width: usize,
) !void {
    // 1. Compute natural (untruncated) widths per column.
    const widths = try gpa.alloc(usize, cols.len);
    defer gpa.free(widths);
    for (cols, 0..) |c, i| widths[i] = c.header.len;
    for (rows) |row| {
        for (row, 0..) |cell, i| {
            if (i < widths.len and cell.len > widths[i]) widths[i] = cell.len;
        }
    }

    // 2. If total > terminal width, shrink proportionally (min 1 per col).
    // Chrome = 1 leading "│" + N * (1 pad + 1 trailing "│") + per-col (1 pad)
    //        = 1 + N*3; "│ cell │ cell │" layout.
    const chrome: usize = 1 + cols.len * 3;
    var total_content: usize = 0;
    for (widths) |x| total_content += x;
    const budget: usize = if (terminal_width > chrome) terminal_width - chrome else 0;
    if (budget > 0 and total_content > budget) {
        for (widths) |*x| {
            const scaled = (x.* * budget) / total_content;
            x.* = if (scaled == 0) 1 else scaled;
        }
    }

    // 3. Top border.
    try writeBorder(w, widths, .top);

    // 4. Header row (always left-aligned).
    try w.writeAll("│");
    for (widths, 0..) |wid, i| {
        if (i > 0) try w.writeAll("│");
        try w.writeByte(' ');
        try writeCell(w, cols[i].header, wid, .left);
        try w.writeByte(' ');
    }
    try w.writeAll("│\n");

    // 5. Header/body separator.
    try writeBorder(w, widths, .sep);

    // 6. Data rows.
    for (rows) |row| {
        try w.writeAll("│");
        for (widths, 0..) |wid, i| {
            if (i > 0) try w.writeAll("│");
            try w.writeByte(' ');
            const cell = if (i < row.len) row[i] else "";
            try writeCell(w, cell, wid, cols[i].@"align");
            try w.writeByte(' ');
        }
        try w.writeAll("│\n");
    }

    // 7. Bottom border.
    try writeBorder(w, widths, .bottom);
}

const BorderKind = enum { top, sep, bottom };

fn writeBorder(w: *std.io.Writer, widths: []const usize, kind: BorderKind) !void {
    const left: []const u8 = switch (kind) {
        .top => "┌",
        .sep => "├",
        .bottom => "└",
    };
    const mid: []const u8 = switch (kind) {
        .top => "┬",
        .sep => "┼",
        .bottom => "┴",
    };
    const right: []const u8 = switch (kind) {
        .top => "┐",
        .sep => "┤",
        .bottom => "┘",
    };
    try w.writeAll(left);
    for (widths, 0..) |wid, i| {
        if (i > 0) try w.writeAll(mid);
        // Each cell is rendered with 1 space of padding on each side.
        var j: usize = 0;
        while (j < wid + 2) : (j += 1) try w.writeAll("─");
    }
    try w.writeAll(right);
    try w.writeByte('\n');
}

fn writeCell(w: *std.io.Writer, cell: []const u8, wid: usize, alignment: Align) !void {
    if (cell.len <= wid) {
        const pad_n = wid - cell.len;
        switch (alignment) {
            .left => {
                try w.writeAll(cell);
                var k: usize = 0;
                while (k < pad_n) : (k += 1) try w.writeByte(' ');
            },
            .right => {
                var k: usize = 0;
                while (k < pad_n) : (k += 1) try w.writeByte(' ');
                try w.writeAll(cell);
            },
        }
    } else {
        // Truncate with "…" (3 bytes UTF-8).
        if (wid == 0) return;
        if (wid == 1) {
            try w.writeAll("…");
            return;
        }
        try w.writeAll(cell[0 .. wid - 1]);
        try w.writeAll("…");
    }
}

test "render tsv emits tab-separated rows with header" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("tsv.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const cols = [_]Column{
        .{ .header = "A" },
        .{ .header = "B" },
    };
    const row0 = [_][]const u8{ "x1", "y1" };
    const row1 = [_][]const u8{ "x2", "y2" };
    const rows = [_][]const []const u8{ &row0, &row1 };

    try render(allocator, w, &cols, &rows, .{ .style = .tsv });
    try w.flush();

    try file.seekTo(0);
    var out: [256]u8 = undefined;
    const n = try file.readAll(&out);
    try std.testing.expectEqualStrings("A\tB\nx1\ty1\nx2\ty2\n", out[0..n]);
}

test "render boxed emits Unicode borders and aligned columns" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("boxed.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const cols = [_]Column{
        .{ .header = "Name" },
        .{ .header = "Kind" },
    };
    const row0 = [_][]const u8{ "atom_site", "category" };
    const rows = [_][]const []const u8{&row0};

    try render(allocator, w, &cols, &rows, .{ .style = .boxed, .terminal_width = 80 });
    try w.flush();

    try file.seekTo(0);
    var out: [1024]u8 = undefined;
    const n = try file.readAll(&out);
    const result = out[0..n];
    try std.testing.expect(std.mem.indexOf(u8, result, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "─") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "atom_site") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "category") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Name") != null);
}

test "render boxed truncates cells that exceed terminal width" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("trunc.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const cols = [_]Column{
        .{ .header = "H" },
    };
    const long = [_][]const u8{"abcdefghijklmnopqrstuvwxyz"};
    const rows = [_][]const []const u8{&long};

    try render(allocator, w, &cols, &rows, .{ .style = .boxed, .terminal_width = 12 });
    try w.flush();

    try file.seekTo(0);
    var out: [512]u8 = undefined;
    const n = try file.readAll(&out);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "…") != null);
}
