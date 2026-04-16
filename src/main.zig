const std = @import("std");
const dic_loader = @import("dic_loader.zig");
const dict = @import("dict.zig");
const fetch = @import("fetch.zig");
const mdict_writer = @import("mdict_writer.zig");
const output = @import("output.zig");

/// Default PDBx dictionary embedded at build time by build.zig's two-stage
/// compile. Serves as the fallback when no cache is available so that a
/// freshly-installed binary works offline without `fetch`.
const embedded_pdbx = @embedFile("embedded_pdbx");

const usage =
    \\Usage: mmcif-dict <command> [options] [arguments]
    \\
    \\Commands:
    \\  fetch [--url URL] [--name NAME]  Download dictionary and compile to cache
    \\  show NAME             Auto-detect category or item and show details
    \\  category [NAME]       List all categories or show details for NAME
    \\  item ITEM_NAME        Show item details (e.g., _atom_site.label_atom_id)
    \\  relations CATEGORY    Show parent-child relationships for CATEGORY
    \\  search QUERY          Search descriptions for QUERY
    \\  compile FILE [-o OUT] Compile CIF dictionary to .mdict
    \\
    \\Options:
    \\  --json                Output in JSON format
    \\  --dict PATH           Path to dictionary (.mdict)
    \\  --name NAME           Select named cache (default: pdbx)
    \\  --help                Show this help
    \\
    \\Environment:
    \\  MMCIF_DICT_PATH       Default path to dictionary file (.mdict)
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
    var dict_name: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--name")) {
            i += 1;
            if (i >= args.len) {
                try ew.writeAll("Error: --name requires an argument\n");
                try ew.flush();
                std.process.exit(1);
            }
            dict_name = args[i];
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            dict_name = arg[7..];
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
        try runFetch(gpa, positional.items[1..], dict_name, w, ew);
        return;
    }

    // Handle compile command before loading dictionary
    if (std.mem.eql(u8, command, "compile")) {
        runCompile(gpa, positional.items[1..], w, ew) catch |err| {
            if (err != error.CompileFailed) {
                try ew.print("Error: {}\n", .{err});
                try ew.flush();
            }
            std.process.exit(1);
        };
        return;
    }

    // Resolve dictionary source: --dict > $MMCIF_DICT_PATH > named cache > embedded default.
    // The embedded fallback only applies when the user hasn't asked for a
    // different name; otherwise we fail loudly so a missing `ihm` cache isn't
    // silently served from the pdbx dictionary.
    const Source = union(enum) {
        file: []const u8, // path; freed on exit when `path_owned` is true
        embedded,
    };

    var path_owned = false;
    const name = dict_name orelse fetch.default_name;
    const source: Source = if (dict_path) |p| Source{ .file = p } else blk: {
        if (std.process.getEnvVarOwned(gpa, "MMCIF_DICT_PATH")) |env_path| {
            path_owned = true;
            break :blk Source{ .file = env_path };
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => {},
            else => return err,
        }
        const config_path = fetch.getConfigMdictPath(gpa, name) catch |err| {
            try ew.print("Error: invalid dictionary name '{s}': {}\n", .{ name, err });
            try ew.flush();
            std.process.exit(1);
        };
        if (std.fs.cwd().access(config_path, .{})) |_| {
            path_owned = true;
            break :blk Source{ .file = config_path };
        } else |_| {
            gpa.free(config_path);
        }
        if (std.mem.eql(u8, name, fetch.default_name)) {
            break :blk Source.embedded;
        }
        try ew.print("Error: dictionary cache '{s}' not found. Run 'mmcif-dict fetch --name {s} --url <URL>' or use --dict PATH.\n", .{ name, name });
        try ew.flush();
        std.process.exit(1);
    };
    defer if (path_owned) switch (source) {
        .file => |p| gpa.free(p),
        .embedded => {},
    };

    var dictionary = switch (source) {
        .file => |p| dict.Dictionary.loadFromFile(gpa, p) catch |err| {
            if (err == error.InvalidMagic or err == error.UnsupportedVersion or err == error.WrongEndian or
                err == error.TruncatedHeader or err == error.SectionOutOfBounds)
            {
                try ew.print("Error: {s} is not a valid .mdict file: {}\n", .{ p, err });
                try ew.writeAll("Hint: run 'mmcif-dict compile DICT.dic -o DICT.mdict' to produce one.\n");
            } else if (err == error.FileNotFound) {
                try ew.print("Error: dictionary not found: {s}\n", .{p});
                try ew.writeAll("Hint: run 'mmcif-dict fetch' to download, or 'mmcif-dict compile DICT.dic' from a .dic file.\n");
            } else {
                try ew.print("Error loading dictionary from {s}: {}\n", .{ p, err });
            }
            try ew.flush();
            std.process.exit(1);
        },
        .embedded => dict.Dictionary.loadFromBuf(gpa, embedded_pdbx) catch |err| {
            try ew.print("Error: embedded dictionary is invalid: {}\n", .{err});
            try ew.flush();
            std.process.exit(1);
        },
    };
    defer dictionary.deinit();

    const cmd_args = positional.items[1..];

    if (std.mem.eql(u8, command, "show")) {
        try runShow(gpa, &dictionary, cmd_args, w, ew, format);
    } else if (std.mem.eql(u8, command, "category")) {
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

fn runShow(
    gpa: std.mem.Allocator,
    dictionary: *dict.Dictionary,
    cmd_args: []const []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
    format: output.Format,
) !void {
    if (cmd_args.len == 0) {
        try ew.writeAll("Usage: mmcif-dict show NAME\n");
        try ew.flush();
        std.process.exit(1);
    }
    const name = cmd_args[0];
    const stripped = if (name.len > 0 and name[0] == '_') name[1..] else name;
    // If it contains a dot, treat as item; otherwise as category
    if (std.mem.indexOfScalar(u8, stripped, '.') != null) {
        try runItem(gpa, dictionary, cmd_args, w, ew, format);
    } else {
        try runCategory(gpa, dictionary, cmd_args, w, ew, format);
    }
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
        const names = try dictionary.listCategoryNames(gpa);
        defer gpa.free(names);
        std.mem.sort([]const u8, names, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        try output.printCategoryList(w, names, format);
    } else {
        const raw_name = cmd_args[0];
        const cat_name = normalizeCategoryName(raw_name);
        if (cat_name.len == 0) {
            try ew.print("Invalid category name: {s}\n", .{raw_name});
            try ew.flush();
            std.process.exit(1);
        }
        const cat = (try dictionary.getCategory(cat_name)) orelse {
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
    const item = (try dictionary.getItem(name)) orelse {
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

fn runFetch(
    gpa: std.mem.Allocator,
    cmd_args: []const []const u8,
    dict_name: ?[]const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
) !void {
    var url: []const u8 = fetch.default_url;
    var url_set = false;
    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const a = cmd_args[i];
        if (std.mem.eql(u8, a, "--url")) {
            i += 1;
            if (i >= cmd_args.len) {
                try ew.writeAll("Error: --url requires a URL argument\n");
                try ew.flush();
                std.process.exit(1);
            }
            url = cmd_args[i];
            url_set = true;
        } else if (std.mem.startsWith(u8, a, "--url=")) {
            url = a[6..];
            url_set = true;
        } else if (std.mem.startsWith(u8, a, "-")) {
            try ew.print("Unknown flag: {s}\n", .{a});
            try ew.flush();
            std.process.exit(1);
        } else if (!url_set) {
            // Positional URL (legacy form: `fetch URL`)
            url = a;
            url_set = true;
        } else {
            try ew.print("Unexpected argument: {s}\n", .{a});
            try ew.flush();
            std.process.exit(1);
        }
    }
    // Name priority: --name flag (top-level) > derived from URL > default
    const name: []const u8 = dict_name orelse (if (url_set) fetch.nameFromUrl(url) else fetch.default_name);
    fetch.fetchAndCompile(gpa, url, name, w, ew) catch |err| {
        if (err != error.FetchFailed) {
            try ew.print("Error: {}\n", .{err});
            try ew.flush();
        }
        std.process.exit(1);
    };
}

fn runCompile(
    gpa: std.mem.Allocator,
    cmd_args: []const []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
) !void {
    if (cmd_args.len == 0) {
        try ew.writeAll("Usage: mmcif-dict compile FILE [-o OUT]\n");
        try ew.flush();
        return error.CompileFailed;
    }

    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < cmd_args.len) : (i += 1) {
        const a = cmd_args[i];
        if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= cmd_args.len) {
                try ew.writeAll("Error: -o requires a path\n");
                try ew.flush();
                return error.CompileFailed;
            }
            output_path = cmd_args[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            try ew.print("Unknown flag: {s}\n", .{a});
            try ew.flush();
            return error.CompileFailed;
        } else if (input_path == null) {
            input_path = a;
        } else {
            try ew.print("Unexpected argument: {s}\n", .{a});
            try ew.flush();
            return error.CompileFailed;
        }
    }

    const in = input_path orelse {
        try ew.writeAll("Error: input file required\n");
        try ew.flush();
        return error.CompileFailed;
    };

    var owned_out: ?[]u8 = null;
    defer if (owned_out) |p| gpa.free(p);
    const out = output_path orelse blk: {
        const stem = std.fs.path.stem(in);
        const p = try std.fmt.allocPrint(gpa, "{s}.mdict", .{stem});
        owned_out = p;
        break :blk p;
    };

    var bd = dic_loader.loadFromDicFile(gpa, in) catch |err| {
        try ew.print("Error loading {s}: {}\n", .{ in, err });
        try ew.flush();
        return error.CompileFailed;
    };
    defer bd.deinit();

    mdict_writer.writeToFile(gpa, &bd, out) catch |err| {
        try ew.print("Error writing {s}: {}\n", .{ out, err });
        try ew.flush();
        return error.CompileFailed;
    };

    try w.print("Compiled {s} -> {s}\n", .{ in, out });
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
    _ = @import("dic_loader.zig");
    _ = @import("dict.zig");
    _ = @import("fetch.zig");
    _ = @import("mdict_format.zig");
    _ = @import("mdict_reader.zig");
    _ = @import("mdict_writer.zig");
    _ = @import("output.zig");
}
