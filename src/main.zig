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
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const stdout_file = std.fs.File.stdout();
    const stderr_file = std.fs.File.stderr();
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_w = stdout_file.writer(&stdout_buf);
    var stderr_w = stderr_file.writer(&stderr_buf);
    const w = &stdout_w.interface;
    const ew = &stderr_w.interface;

    var format: output.Format = .text;
    var dict_path: ?[]const u8 = null;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(gpa);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            format = .json;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try w.writeAll(usage);
            try w.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--dict")) {
            i += 1;
            if (i >= args.len) {
                try ew.writeAll("Error: --dict requires a path argument\n");
                try ew.flush();
                std.process.exit(1);
            }
            dict_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--dict=")) {
            dict_path = arg[7..];
        } else {
            try positional.append(gpa, arg);
        }
    }

    if (positional.items.len == 0) {
        try ew.writeAll(usage);
        try ew.flush();
        std.process.exit(1);
    }

    // Resolve dictionary path: --dict > $MMCIF_DICT_PATH > exe_dir/../data/mmcif_pdbx.json
    const path = dict_path orelse std.process.getEnvVarOwned(gpa, "MMCIF_DICT_PATH") catch blk: {
        const exe_dir = std.fs.selfExeDirPathAlloc(gpa) catch {
            try ew.writeAll("Error: cannot determine executable directory. Use --dict or set MMCIF_DICT_PATH.\n");
            try ew.flush();
            std.process.exit(1);
        };
        break :blk try std.fmt.allocPrint(gpa, "{s}/../data/mmcif_pdbx.json", .{exe_dir});
    };

    var dictionary = json_loader.loadFromFile(gpa, path) catch |err| {
        try ew.print("Error loading dictionary from {s}: {}\n", .{ path, err });
        try ew.flush();
        std.process.exit(1);
    };
    defer dictionary.deinit();

    const command = positional.items[0];
    const cmd_args = positional.items[1..];

    if (std.mem.eql(u8, command, "category")) {
        try runCategory(gpa, &dictionary, cmd_args, w, ew, format);
    } else if (std.mem.eql(u8, command, "item")) {
        try runItem(gpa, &dictionary, cmd_args, w, ew, format);
    } else if (std.mem.eql(u8, command, "relations")) {
        try runRelations(gpa, &dictionary, cmd_args, w, ew, format);
    } else if (std.mem.eql(u8, command, "search")) {
        try runSearch(gpa, &dictionary, cmd_args, w, ew, format);
    } else {
        try ew.print("Unknown command: {s}\n\n", .{command});
        try ew.writeAll(usage);
        try ew.flush();
        std.process.exit(1);
    }

    try w.flush();
}

fn runCategory(
    gpa: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        var cat_iter = dictionary.categories.keyIterator();
        while (cat_iter.next()) |key| {
            try names.append(gpa, key.*);
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        try output.printCategoryList(w, names.items, format);
    } else {
        const cat = dictionary.getCategory(cmd_args[0]) orelse {
            try ew.print("Category not found: {s}\n", .{cmd_args[0]});
            try ew.flush();
            std.process.exit(1);
        };
        try output.printCategory(w, cat, format);
    }
}

fn runItem(
    gpa: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try ew.writeAll("Usage: mmcif-dict item ITEM_NAME\n");
        try ew.flush();
        std.process.exit(1);
    }
    var name = cmd_args[0];
    if (name.len > 0 and name[0] != '_') {
        name = try std.fmt.allocPrint(gpa, "_{s}", .{name});
    }
    const item = dictionary.getItem(name) orelse {
        try ew.print("Item not found: {s}\n", .{name});
        try ew.flush();
        std.process.exit(1);
    };
    try output.printItem(w, item, format);
}

fn runRelations(
    gpa: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try ew.writeAll("Usage: mmcif-dict relations CATEGORY\n");
        try ew.flush();
        std.process.exit(1);
    }
    const rels = try dictionary.getRelationsForCategory(gpa, cmd_args[0]);
    defer gpa.free(rels);
    try output.printRelations(w, cmd_args[0], rels, format);
}

fn runSearch(
    gpa: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try ew.writeAll("Usage: mmcif-dict search QUERY\n");
        try ew.flush();
        std.process.exit(1);
    }
    const results = try dictionary.searchDescriptions(gpa, cmd_args[0]);
    defer gpa.free(results.categories);
    defer gpa.free(results.items);
    try output.printSearchResults(w, cmd_args[0], results, format);
}

test {
    _ = @import("dict.zig");
    _ = @import("json_loader.zig");
    _ = @import("output.zig");
}
