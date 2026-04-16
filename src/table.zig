//! Simple table renderer for the mmCIF CLI.
//!
//! Width accounting uses byte lengths (`cell.len`) throughout. This is
//! correct only for ASCII content — all mmCIF identifiers and category
//! names are ASCII, which is the module's intended input. Non-ASCII cells
//! will produce misaligned columns and may be truncated at arbitrary
//! UTF-8 byte boundaries in boxed mode. The only multi-byte character
//! emitted by this module is the "…" ellipsis appended by truncation.
//!
//! The `renderBoxed` shrink is greedy: when the natural widths exceed
//! `terminal_width`, the currently-widest column is trimmed by 1 char
//! repeatedly until the total fits. Columns never go below 1 char.
//! Per-column `max_width` caps are applied before shrink, so narrow
//! columns like `Kind` (≤ 10 chars) stay full-width even when paired
//! with a very long description column.

const std = @import("std");

pub const Align = enum { left, right };

pub const Column = struct {
    header: []const u8,
    @"align": Align = .left,
    /// Maximum column width in characters. 0 means no cap.
    max_width: usize = 0,
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
    // Apply per-column caps before the shrink.
    for (cols, 0..) |c, i| {
        if (c.max_width > 0 and widths[i] > c.max_width) widths[i] = c.max_width;
    }

    // 2. If total > terminal width, shrink greedily (largest column first, min 1 per col).
    // Chrome = 1 leading "│" + N * (1 pad + 1 trailing "│") + per-col (1 pad)
    //        = 1 + N*3; "│ cell │ cell │" layout.
    const chrome: usize = 1 + cols.len * 3;
    var total_content: usize = 0;
    for (widths) |x| total_content += x;
    const budget: usize = if (terminal_width > chrome) terminal_width - chrome else 0;
    // Greedy shrink: repeatedly trim 1 char from the currently-widest column
    // until the total fits within the budget. Always leave >= 1 char per col.
    if (budget > 0 and total_content > budget) {
        while (total_content > budget) {
            var max_idx: usize = 0;
            for (widths, 0..) |wid, i| {
                if (wid > widths[max_idx]) max_idx = i;
            }
            if (widths[max_idx] <= 1) break; // can't shrink any further
            widths[max_idx] -= 1;
            total_content -= 1;
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
        // Truncate. "…" is 3 UTF-8 bytes; reserve 3 bytes of the slot for
        // it when the slot is wide enough (wid >= 4). For narrower slots,
        // use a 1-byte ASCII ">" fallback so the rendered byte count
        // matches the column width and the table stays aligned.
        if (wid == 0) return;
        if (wid >= 4) {
            try w.writeAll(cell[0 .. wid - 3]);
            try w.writeAll("…");
        } else {
            // wid in {1, 2, 3}: 1-byte marker.
            try w.writeAll(cell[0 .. wid - 1]);
            try w.writeByte('>');
        }
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

test "render boxed narrow column uses ASCII fallback" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("narrow.txt", .{ .read = true });
    defer file.close();

    var buf: [1024]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const cols = [_]Column{
        .{ .header = "H" },
    };
    // Terminal width small enough that the column shrinks below 4 chars.
    // chrome = 1 + 1*3 = 4, budget = 5-4 = 1. Natural width = 10. Scaled = 0 → clamped to 1.
    const long = [_][]const u8{"abcdefghij"};
    const rows = [_][]const []const u8{&long};

    try render(allocator, w, &cols, &rows, .{ .style = .boxed, .terminal_width = 5 });
    try w.flush();

    try file.seekTo(0);
    var out: [512]u8 = undefined;
    const n = try file.readAll(&out);
    const result = out[0..n];
    // ASCII ">" appears; "…" does NOT (would overflow).
    try std.testing.expect(std.mem.indexOf(u8, result, ">") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "…") == null);
}

test "render boxed respects Column.max_width cap" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("maxw.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const cols = [_]Column{
        .{ .header = "K", .max_width = 4 },
        .{ .header = "V" },
    };
    const row = [_][]const u8{ "longcell", "other" };
    const rows = [_][]const []const u8{&row};

    try render(allocator, w, &cols, &rows, .{ .style = .boxed, .terminal_width = 80 });
    try w.flush();

    try file.seekTo(0);
    var out: [512]u8 = undefined;
    const n = try file.readAll(&out);
    // "longcell" (8 chars) should be truncated to fit 4-wide column.
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "longcell") == null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "…") != null);
}

test "render boxed greedy shrink preserves narrow columns" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("greedy.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const cols = [_]Column{
        .{ .header = "A" }, // Short header.
        .{ .header = "B" },
    };
    // Column A is short content; column B is long content. Terminal too narrow.
    const row = [_][]const u8{ "ok", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" };
    const rows = [_][]const []const u8{&row};

    try render(allocator, w, &cols, &rows, .{ .style = .boxed, .terminal_width = 20 });
    try w.flush();

    try file.seekTo(0);
    var out: [512]u8 = undefined;
    const n = try file.readAll(&out);
    // Column A's content "ok" should be fully rendered (not truncated).
    // Column B should be truncated.
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..n], "…") != null);
}

/// Render a single-column list in one of two shapes:
///   - .boxed: pack items into a column grid that fits terminal_width
///   - .tsv:   one item per line with a 2-space indent (legacy format)
pub fn renderGrid(
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
            // col_w >= 2 guaranteed (max_len: usize, +2), so division is safe.
            var ncols: usize = usable / col_w;
            if (ncols == 0) ncols = 1;

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
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("grid_tsv.txt", .{ .read = true });
    defer file.close();

    var buf: [1024]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    const items = [_][]const u8{ "_x.a", "_x.b", "_x.c" };
    try renderGrid(w, &items, .{ .style = .tsv });
    try w.flush();

    try file.seekTo(0);
    var out: [256]u8 = undefined;
    const n = try file.readAll(&out);
    try std.testing.expectEqualStrings("  _x.a\n  _x.b\n  _x.c\n", out[0..n]);
}

test "renderGrid boxed packs multiple items per line" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("grid_boxed.txt", .{ .read = true });
    defer file.close();

    var buf: [4096]u8 = undefined;
    var fw = file.writer(&buf);
    const w = &fw.interface;

    // 6 short items, terminal width 30 -> should fit 3 or more per row.
    const items = [_][]const u8{ "aa", "bb", "cc", "dd", "ee", "ff" };
    try renderGrid(w, &items, .{ .style = .boxed, .terminal_width = 30 });
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
