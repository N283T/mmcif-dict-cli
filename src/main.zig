const std = @import("std");
const cif = @import("cif_parser.zig");
const dict = @import("dict.zig");
const dict2json = @import("dict2json.zig");
const fetch = @import("fetch.zig");
const json_loader = @import("json_loader.zig");
const output = @import("output.zig");

const usage =
    \\Usage: mmcif-dict <command> [options] [arguments]
    \\
    \\Commands:
    \\  fetch [URL]           Download dictionary to ~/.config/mmcif-dict/
    \\  category [NAME]       List all categories or show details for NAME
    \\  item ITEM_NAME        Show item details (e.g., _atom_site.label_atom_id)
    \\  relations CATEGORY    Show parent-child relationships for CATEGORY
    \\  search QUERY          Search descriptions for QUERY
    \\  dict2json FILE        Convert CIF dictionary to PDBj-compatible JSON
    \\
    \\Options:
    \\  --json                Output in JSON format
    \\  --dict PATH           Path to dictionary (.json or .json.gz)
    \\  --help                Show this help
    \\
    \\Environment:
    \\  MMCIF_DICT_PATH       Default path to dictionary file
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

    // Handle fetch command before loading dictionary
    const command = positional.items[0];
    if (std.mem.eql(u8, command, "fetch")) {
        if (positional.items.len > 2) {
            try ew.writeAll("Usage: mmcif-dict fetch [URL]\n");
            try ew.flush();
            std.process.exit(1);
        }
        const url = if (positional.items.len > 1) positional.items[1] else fetch.default_url;
        fetch.fetchDictionary(gpa, url, w, ew) catch |err| {
            if (err != error.FetchFailed) {
                try ew.print("Error: {}\n", .{err});
                try ew.flush();
            }
            std.process.exit(1);
        };
        return;
    }

    // Handle dict2json command before loading dictionary
    if (std.mem.eql(u8, command, "dict2json")) {
        if (positional.items.len != 2) {
            try ew.writeAll("Usage: mmcif-dict dict2json FILE\n");
            try ew.flush();
            std.process.exit(1);
        }
        runDict2Json(gpa, positional.items[1], w, ew) catch |err| {
            if (err != error.Dict2JsonFailed) {
                try ew.print("Error: {}\n", .{err});
                try ew.flush();
            }
            std.process.exit(1);
        };
        return;
    }

    // Resolve dictionary path: --dict > $MMCIF_DICT_PATH > ~/.config/mmcif-dict/ > exe_dir/../data/
    var path_owned = false;
    const path = dict_path orelse blk: {
        const env_path = std.process.getEnvVarOwned(gpa, "MMCIF_DICT_PATH") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                // Try ~/.config/mmcif-dict/mmcif_pdbx.json (single alloc, no TOCTOU)
                const config_path = fetch.getConfigDictPath(gpa) catch {
                    // Fall through to exe_dir fallback
                    const exe_dir = std.fs.selfExeDirPathAlloc(gpa) catch {
                        try ew.writeAll("Error: dictionary not found. Run 'mmcif-dict fetch' to download, or use --dict/MMCIF_DICT_PATH.\n");
                        try ew.flush();
                        std.process.exit(1);
                    };
                    defer gpa.free(exe_dir);
                    path_owned = true;
                    break :blk try std.fmt.allocPrint(gpa, "{s}/../data/mmcif_pdbx.json", .{exe_dir});
                };
                if (std.fs.cwd().access(config_path, .{})) |_| {
                    path_owned = true;
                    break :blk config_path;
                } else |_| {
                    gpa.free(config_path);
                }
                // Fall back to exe_dir/../data/mmcif_pdbx.json
                const exe_dir = std.fs.selfExeDirPathAlloc(gpa) catch {
                    try ew.writeAll("Error: dictionary not found. Run 'mmcif-dict fetch' to download, or use --dict/MMCIF_DICT_PATH.\n");
                    try ew.flush();
                    std.process.exit(1);
                };
                defer gpa.free(exe_dir);
                path_owned = true;
                break :blk try std.fmt.allocPrint(gpa, "{s}/../data/mmcif_pdbx.json", .{exe_dir});
            },
            else => return err,
        };
        path_owned = true;
        break :blk env_path;
    };
    defer if (path_owned) gpa.free(path);

    var dictionary = json_loader.loadFromFile(gpa, path) catch |err| {
        if (err == error.DictionaryCorrupt) {
            try ew.print("Error: dictionary file appears corrupt: {s}\n", .{path});
            try ew.writeAll("Hint: Run 'mmcif-dict fetch' to re-download the dictionary.\n");
        } else if (err == error.FileNotFound) {
            try ew.print("Error: dictionary not found: {s}\n", .{path});
            try ew.writeAll("Hint: Run 'mmcif-dict fetch' to download the dictionary.\n");
        } else {
            try ew.print("Error loading dictionary from {s}: {}\n", .{ path, err });
        }
        try ew.flush();
        std.process.exit(1);
    };
    defer dictionary.deinit();

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
        const raw_name = cmd_args[0];
        const cat_name = normalizeCategoryName(raw_name);
        if (cat_name.len == 0) {
            try ew.print("Invalid category name: {s}\n", .{raw_name});
            try ew.flush();
            std.process.exit(1);
        }
        const cat = dictionary.getCategory(cat_name) orelse {
            try ew.print("Category not found: {s}\n", .{raw_name});
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
    var name_owned = false;
    if (name.len > 0 and name[0] != '_') {
        name = try std.fmt.allocPrint(gpa, "_{s}", .{name});
        name_owned = true;
    }
    defer if (name_owned) gpa.free(name);
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
    const raw_name = cmd_args[0];
    const cat_name = normalizeCategoryName(raw_name);
    if (cat_name.len == 0) {
        try ew.print("Invalid category name: {s}\n", .{raw_name});
        try ew.flush();
        std.process.exit(1);
    }
    const rels = try dictionary.getRelationsForCategory(gpa, cat_name);
    defer gpa.free(rels);
    try output.printRelations(w, cat_name, rels, format);
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

fn runDict2Json(
    gpa: std.mem.Allocator,
    path: []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try ew.print("Error: cannot open {s}: {}\n", .{ path, err });
        try ew.flush();
        return error.Dict2JsonFailed;
    };
    defer file.close();

    const stat = file.stat() catch |err| {
        try ew.print("Error: cannot stat {s}: {}\n", .{ path, err });
        try ew.flush();
        return error.Dict2JsonFailed;
    };
    const input = gpa.alloc(u8, stat.size) catch {
        try ew.print("Error: out of memory reading {s}\n", .{path});
        try ew.flush();
        return error.Dict2JsonFailed;
    };
    defer gpa.free(input);

    const n = file.readAll(input) catch |err| {
        try ew.print("Error reading {s}: {}\n", .{ path, err });
        try ew.flush();
        return error.Dict2JsonFailed;
    };

    var doc = cif.parse(gpa, input[0..n]) catch |err| {
        try ew.print("Error parsing CIF {s}: {}\n", .{ path, err });
        try ew.flush();
        return error.Dict2JsonFailed;
    };
    defer doc.deinit();

    if (doc.blocks.len > 1) {
        try ew.print("Warning: {d} data blocks found, converting only the first\n", .{doc.blocks.len});
        try ew.flush();
    }

    dict2json.convert(gpa, doc, w) catch |err| {
        try ew.print("Error converting to JSON: {}\n", .{err});
        try ew.flush();
        return error.Dict2JsonFailed;
    };

    try w.flush();
}

/// Normalize category name: strip leading '_' and trailing '.xxx'
/// e.g. "_atom_site" -> "atom_site", "_atom_site.entity_id" -> "atom_site"
fn normalizeCategoryName(raw: []const u8) []const u8 {
    const stripped = if (raw.len > 0 and raw[0] == '_') raw[1..] else raw;
    return if (std.mem.indexOfScalar(u8, stripped, '.')) |dot| stripped[0..dot] else stripped;
}

test {
    _ = @import("cif_parser.zig");
    _ = @import("dict.zig");
    _ = @import("dict2json.zig");
    _ = @import("fetch.zig");
    _ = @import("json_loader.zig");
    _ = @import("output.zig");
}
