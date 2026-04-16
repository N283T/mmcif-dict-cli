const std = @import("std");
const dic_loader = @import("dic_loader.zig");
const mdict_writer = @import("mdict_writer.zig");
const Allocator = std.mem.Allocator;

pub const default_url = "https://mmcif.wwpdb.org/dictionaries/ascii/mmcif_pdbx_v50.dic";
pub const default_name = "pdbx";

const config_dir_name = "mmcif-dict";
const mdict_ext = ".mdict";

/// Return the config directory: ~/.config/mmcif-dict/
fn getConfigDir(allocator: Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.HomeNotFound,
        else => return err,
    };
    defer allocator.free(home);

    const config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try std.fmt.allocPrint(allocator, "{s}/.config", .{home}),
        else => return err,
    };
    defer allocator.free(config_home);

    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_home, config_dir_name });
}

/// Validate a cache name. Cache names map directly to files under the config dir,
/// so they must be a single path segment with no traversal tokens.
fn validateName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0) return error.InvalidName;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    // Reject hidden files and any embedded traversal token.
    if (name[0] == '.') return error.InvalidName;
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidName;
}

/// Return the cache path for a named dictionary, e.g. ~/.config/mmcif-dict/pdbx.mdict
pub fn getConfigMdictPath(allocator: Allocator, name: []const u8) ![]const u8 {
    try validateName(name);
    const dir = try getConfigDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir, name, mdict_ext });
}

/// Derive a cache name from a dictionary URL's basename. Strips `.dic` / `.dic.gz`.
/// Falls back to `default_name` when the basename is empty or would fail validation.
pub fn nameFromUrl(url: []const u8) []const u8 {
    const clean = blk: {
        if (std.mem.indexOfScalar(u8, url, '?')) |q| break :blk url[0..q];
        if (std.mem.indexOfScalar(u8, url, '#')) |h| break :blk url[0..h];
        break :blk url;
    };
    const last = if (std.mem.lastIndexOfScalar(u8, clean, '/')) |s| clean[s + 1 ..] else clean;
    const stem = if (std.mem.endsWith(u8, last, ".dic.gz"))
        last[0 .. last.len - 7]
    else if (std.mem.endsWith(u8, last, ".dic"))
        last[0 .. last.len - 4]
    else
        last;
    if (stem.len == 0) return default_name;
    validateName(stem) catch return default_name;
    return stem;
}

/// Download a CIF dictionary and compile it to the named `.mdict` cache.
/// The cache is written via write-to-temp + atomic rename.
pub fn fetchAndCompile(
    allocator: Allocator,
    url: []const u8,
    name: []const u8,
    w: *std.io.Writer,
    ew: *std.io.Writer,
) !void {
    const dest_path = try getConfigMdictPath(allocator, name);
    defer allocator.free(dest_path);

    const dir_path = std.fs.path.dirname(dest_path) orelse return error.InvalidPath;
    std.fs.cwd().makePath(dir_path) catch |err| {
        try ew.print("Error creating directory {s}: {}\n", .{ dir_path, err });
        try ew.flush();
        return error.FetchFailed;
    };

    try w.print("Downloading {s}\n", .{url});
    try w.flush();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var body_writer: std.io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body_writer.writer,
    }) catch |err| {
        try ew.print("Download failed: {}. Check your network connection.\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    if (result.status != .ok) {
        const code = @intFromEnum(result.status);
        try ew.print("Download failed (HTTP {d}).\n", .{code});
        if (code >= 500) {
            try ew.writeAll("The server may be temporarily unavailable. Please try again later.\n");
        } else if (result.status == .not_found) {
            try ew.writeAll("The dictionary URL may have changed. Check for updates.\n");
        }
        try ew.flush();
        return error.FetchFailed;
    }

    const body_bytes = body_writer.written();
    try w.print("Compiling {d} bytes -> {s}\n", .{ body_bytes.len, dest_path });
    try w.flush();

    var bd = dic_loader.loadFromDicBytes(allocator, body_bytes) catch |err| {
        try ew.print("Compile failed: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    defer bd.deinit();

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest_path});
    defer allocator.free(tmp_path);

    var tmp_created = false;
    defer if (tmp_created) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
    };

    mdict_writer.writeToFile(allocator, &bd, tmp_path) catch |err| {
        try ew.print("Write failed: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    tmp_created = true;

    std.fs.cwd().rename(tmp_path, dest_path) catch |err| {
        try ew.print("Rename failed: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    tmp_created = false;

    try w.print("Done. ({s})\n", .{dest_path});
    try w.flush();
}

test "getConfigMdictPath returns valid path" {
    const allocator = std.testing.allocator;
    const path = try getConfigMdictPath(allocator, "pdbx");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "mmcif-dict/pdbx.mdict"));
}

test "getConfigMdictPath accepts alternate names" {
    const allocator = std.testing.allocator;
    const path = try getConfigMdictPath(allocator, "mmcif_ihm_ext");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "mmcif-dict/mmcif_ihm_ext.mdict"));
}

test "getConfigMdictPath rejects traversal and invalid names" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, ""));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "."));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, ".."));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "../etc"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "a/b"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "a\\b"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, ".hidden"));
}

test "nameFromUrl extracts stem" {
    try std.testing.expectEqualStrings(
        "mmcif_pdbx_v50",
        nameFromUrl("https://mmcif.wwpdb.org/dictionaries/ascii/mmcif_pdbx_v50.dic"),
    );
    try std.testing.expectEqualStrings(
        "mmcif_ihm",
        nameFromUrl("https://example.com/mmcif_ihm.dic.gz"),
    );
    try std.testing.expectEqualStrings(
        "pdbx",
        nameFromUrl("https://example.com/"),
    );
}

test "nameFromUrl strips query string and fragment" {
    try std.testing.expectEqualStrings(
        "mmcif_pdbx_v50",
        nameFromUrl("https://example.com/mmcif_pdbx_v50.dic?token=abc"),
    );
    try std.testing.expectEqualStrings(
        "mmcif_pdbx_v50",
        nameFromUrl("https://example.com/mmcif_pdbx_v50.dic#section"),
    );
}

test "nameFromUrl falls back to default on empty or hidden stems" {
    // Empty stem after stripping .dic extension
    try std.testing.expectEqualStrings("pdbx", nameFromUrl("https://example.com/.dic"));
    // Hidden stem (leading dot) is rejected by validateName
    try std.testing.expectEqualStrings("pdbx", nameFromUrl("https://example.com/.hidden.dic"));
}
