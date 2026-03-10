const std = @import("std");
const Allocator = std.mem.Allocator;

const dict_url = "https://data.pdbj.org/pdbjplus/dictionaries/mmcif_pdbx.json.gz";
const config_dir_name = "mmcif-dict";
const dict_filename = "mmcif_pdbx.json";

/// Return the default config path: ~/.config/mmcif-dict/mmcif_pdbx.json
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

/// Fetch the dictionary from PDBj and save to ~/.config/mmcif-dict/mmcif_pdbx.json.
/// Uses system curl + gunzip to avoid Zig gzip decompression bugs.
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

    try w.print("Downloading {s}\n", .{dict_url});
    try w.print("Destination: {s}\n", .{dest_path});
    try w.flush();

    // Use shell pipeline: curl -sL URL | gunzip > dest
    const shell_cmd = try std.fmt.allocPrint(
        allocator,
        "curl -sfL '{s}' | gunzip > '{s}'",
        .{ dict_url, dest_path },
    );
    defer allocator.free(shell_cmd);

    var child = std.process.Child.init(&.{ "/bin/sh", "-c", shell_cmd }, allocator);
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try ew.print("Download failed (exit code {d}). Check your network connection.\n", .{code});
                try ew.flush();
                std.fs.cwd().deleteFile(dest_path) catch {};
                return error.FetchFailed;
            }
        },
        else => {
            try ew.writeAll("Download process terminated abnormally.\n");
            try ew.flush();
            std.fs.cwd().deleteFile(dest_path) catch {};
            return error.FetchFailed;
        },
    }

    // Verify the file exists and is valid JSON (check first byte)
    const file = std.fs.cwd().openFile(dest_path, .{}) catch |err| {
        try ew.print("Error: downloaded file not found: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    defer file.close();

    var peek_buf: [1]u8 = undefined;
    const n = try file.read(&peek_buf);
    if (n == 0 or peek_buf[0] != '{') {
        try ew.writeAll("Error: downloaded file does not appear to be valid JSON.\n");
        try ew.flush();
        std.fs.cwd().deleteFile(dest_path) catch {};
        return error.FetchFailed;
    }

    const stat = try file.stat();
    const size_mb = @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0);
    try w.print("Done. ({d:.1} MB)\n", .{size_mb});
    try w.flush();
}

test "getConfigDictPath returns valid path" {
    const allocator = std.testing.allocator;
    const path = try getConfigDictPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "mmcif-dict/mmcif_pdbx.json"));
}
