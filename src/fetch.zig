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
/// Uses std.http.Client — no external dependencies required.
/// The .gz is decompressed at load time (see json_loader.zig).
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

    // Stream response body directly to temp file to avoid buffering in memory
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    {
        const tmp_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
            try ew.print("Error creating temp file {s}: {}\n", .{ tmp_path, err });
            try ew.flush();
            return error.FetchFailed;
        };
        defer tmp_file.close();
        tmp_created = true;

        var write_buf: [65536]u8 = undefined;
        var file_writer = tmp_file.writer(&write_buf);

        // fetch() streams the response body regardless of HTTP status,
        // so we check status before flushing to avoid persisting error pages.
        const result = client.fetch(.{
            .location = .{ .url = dict_url },
            .response_writer = &file_writer.interface,
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

        file_writer.interface.flush() catch |err| {
            try ew.print("Error writing downloaded data: {}\n", .{err});
            try ew.flush();
            return error.FetchFailed;
        };
    }

    // Guard against truncated downloads or HTML error pages served as 200 OK
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
