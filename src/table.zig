//! Simple table renderer for the mmCIF CLI.
//!
//! Width accounting uses byte lengths (`cell.len`) throughout. This is
//! correct only for ASCII content — all mmCIF identifiers and category
//! names are ASCII, which is the module's intended input. Non-ASCII cells
//! will produce misaligned columns and may be truncated at arbitrary
//! UTF-8 byte boundaries in boxed mode. The only multi-byte character
//! emitted by this module is the "…" ellipsis appended by truncation.
//!
//! The proportional shrink in `renderBoxed` clamps each column to a
//! minimum of 1 character. When a very narrow budget combines with many
//! columns, the final table can exceed `terminal_width`. This is
//! acceptable for mmCIF output (2–3 columns of moderate width) but
//! would need a second-pass correction for wider use.

const std = @import("std");

pub const Align = enum { left, right };

pub const Column = struct {
    header: []const u8,
    @"align": Align = .left,
};

pub const Style = enum { boxed, tsv };

pub const Options = struct {
    style: Style,
    /// Only used by .boxed. A value of 0 disables width-based shrinking
    /// (columns render at their natural width).
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
    // TSV is unpadded: column alignment is ignored by design.
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

/// Render a single-column list in one of two shapes:
///   - .boxed: pack items into a column grid that fits terminal_width
///   - .tsv:   one item per line with a 2-space indent (legacy format)
pub fn renderGrid(
    gpa: std.mem.Allocator,
    w: *std.io.Writer,
    items: []const []const u8,
    opts: Options,
) !void {
    switch (opts.style) {
        .tsv => {
            for (items) |it| {
                try w.print("  {s}\n", .{it});
            }
        },
        .boxed => {
            if (items.len == 0) return;

            // Longest item drives column width. Add 2 for inter-column gap.
            var max_len: usize = 0;
            for (items) |it| {
                if (it.len > max_len) max_len = it.len;
            }
            const col_w = max_len + 2;
            const usable = if (opts.terminal_width >= 2) opts.terminal_width - 2 else 1;
            var ncols: usize = if (col_w == 0) 1 else usable / col_w;
            if (ncols == 0) ncols = 1;
            _ = gpa; // not needed in this simple packer

            // Row-major layout: item k -> (k / ncols, k % ncols).
            var idx: usize = 0;
            while (idx < items.len) {
                try w.writeAll("  "); // 2-space outer indent
                var col: usize = 0;
                while (col < ncols and idx < items.len) : ({ col += 1; idx += 1; }) {
                    const it = items[idx];
                    try w.writeAll(it);
                    // Pad to column width unless this is the last item on the row.
                    const is_last_on_row = (col + 1 == ncols) or (idx + 1 == items.len);
                    if (!is_last_on_row) {
                        var pad: usize = col_w - it.len;
                        while (pad > 0) : (pad -= 1) try w.writeByte(' ');
                    }
                }
                try w.writeByte('\n');
            }
        },
    }
}

test "renderGrid tsv emits one item per line with 2-space indent" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("grid_tsv.txt", .{ .read = true });
    defer file.close();

    var buf: [1024]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const items = [_][]const u8{ "_x.a", "_x.b", "_x.c" };
    try renderGrid(allocator, w, &items, .{ .style = .tsv });
    try w.flush();

    try file.seekTo(0);
    var out: [256]u8 = undefined;
    const n = try file.readAll(&out);
    try std.testing.expectEqualStrings("  _x.a\n  _x.b\n  _x.c\n", out[0..n]);
}

test "renderGrid boxed packs multiple items per line" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("grid_boxed.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    // 6 short items, terminal width 30 -> should fit 3 or more per row.
    const items = [_][]const u8{ "aa", "bb", "cc", "dd", "ee", "ff" };
    try renderGrid(allocator, w, &items, .{ .style = .boxed, .terminal_width = 30 });
    try w.flush();

    try file.seekTo(0);
    var out: [512]u8 = undefined;
    const n = try file.readAll(&out);
    const result = out[0..n];
    for (items) |it| {
        try std.testing.expect(std.mem.indexOf(u8, result, it) != null);
    }
    var lines: usize = 0;
    for (result) |c| if (c == '\n') {
        lines += 1;
    };
    try std.testing.expect(lines < items.len);
}
