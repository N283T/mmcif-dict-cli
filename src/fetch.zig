const std = @import("std");
const Allocator = std.mem.Allocator;

const dict_url = "https://data.pdbj.org/pdbjplus/dictionaries/mmcif_pdbx.json.gz";
const config_dir_name = "mmcif-dict";
const dict_filename = "mmcif_pdbx.json.gz";
const min_valid_size = 100 * 1024; // 100 KB — real .gz is ~540 KB

/// Return the default config path: ~/.config/mmcif-dict/mmcif_pdbx.json.gz
pub fn getConfigDictPath(allocator: Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.HomeNotFound,
        else => return err,
    };
    defer allocator.free(home);

    // Respect XDG_CONFIG_HOME if set
    const config_home = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try std.fmt.allocPrint(allocator, "{s}/.config", .{home}),
        else => return err,
    };
    defer allocator.free(config_home);

    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ config_home, config_dir_name, dict_filename });
}

/// Check if the config dictionary file exists.
pub fn configDictExists(allocator: Allocator) bool {
    const path = getConfigDictPath(allocator) catch return false;
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Fetch the dictionary from PDBj and save as .gz to ~/.config/mmcif-dict/.
/// Only requires curl (decompression is handled natively by Zig at load time).
pub fn fetchDictionary(allocator: Allocator, w: *std.io.Writer, ew: *std.io.Writer) !void {
    const dest_path = try getConfigDictPath(allocator);
    defer allocator.free(dest_path);

    // Create parent directory
    const dir_path = std.fs.path.dirname(dest_path) orelse return error.InvalidPath;
    std.fs.cwd().makePath(dir_path) catch |err| {
        try ew.print("Error creating directory {s}: {}\n", .{ dir_path, err });
        try ew.flush();
        return err;
    };

    // Write to temp file, rename on success (atomic write)
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest_path});
    defer allocator.free(tmp_path);
    var tmp_created = false;
    defer if (tmp_created) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
    };

    try w.print("Downloading {s}\n", .{dict_url});
    try w.print("Destination: {s}\n", .{dest_path});
    try w.flush();

    // Download with curl, save .gz directly (no decompression needed)
    var curl = std.process.Child.init(&.{ "curl", "-sfL", "-o", tmp_path, dict_url }, allocator);
    curl.stderr_behavior = .Inherit;
    curl.stdout_behavior = .Inherit;

    curl.spawn() catch |err| {
        try ew.print("Error: failed to run curl: {}. Ensure curl is installed.\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    tmp_created = true;

    const curl_term = curl.wait() catch |err| {
        try ew.print("Error waiting for curl: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };

    const curl_ok = curl_term == .Exited and curl_term.Exited == 0;
    if (!curl_ok) {
        switch (curl_term) {
            .Exited => |code| try ew.print("Download failed (curl exit code {d}). Check your network connection.\n", .{code}),
            .Signal => |sig| try ew.print("Download failed (curl killed by signal {d}).\n", .{sig}),
            else => try ew.writeAll("Download failed (curl terminated unexpectedly).\n"),
        }
        try ew.flush();
        return error.FetchFailed;
    }

    // Validate: open file, check size and gzip magic bytes
    const verify_file = std.fs.cwd().openFile(tmp_path, .{}) catch |err| {
        try ew.print("Error: cannot open downloaded file: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    defer verify_file.close();

    const stat = verify_file.stat() catch |err| {
        try ew.print("Error: cannot stat downloaded file: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    if (stat.size < min_valid_size) {
        try ew.print("Error: downloaded file too small ({d} bytes). Expected > 100 KB.\n", .{stat.size});
        try ew.flush();
        return error.FetchFailed;
    }

    var magic_buf: [2]u8 = undefined;
    const n = verify_file.read(&magic_buf) catch |err| {
        try ew.print("Error: cannot read downloaded file: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    if (n < 2 or magic_buf[0] != 0x1f or magic_buf[1] != 0x8b) {
        try ew.writeAll("Error: downloaded file is not a valid gzip file.\n");
        try ew.flush();
        return error.FetchFailed;
    }

    // Atomic rename
    std.fs.cwd().rename(tmp_path, dest_path) catch |err| {
        try ew.print("Error: cannot move file to final location: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    tmp_created = false; // Rename succeeded, don't delete

    const size_kb = @as(f64, @floatFromInt(stat.size)) / 1024.0;
    try w.print("Done. ({d:.0} KB)\n", .{size_kb});
    try w.flush();
}

test "getConfigDictPath returns valid path" {
    const allocator = std.testing.allocator;
    const path = try getConfigDictPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "mmcif-dict/mmcif_pdbx.json.gz"));
}
