const std = @import("std");
const Allocator = std.mem.Allocator;

const dict_url = "https://data.pdbj.org/pdbjplus/dictionaries/mmcif_pdbx.json.gz";
const config_dir_name = "mmcif-dict";
const dict_filename = "mmcif_pdbx.json";
const min_valid_size = 1024 * 1024; // 1 MB — real dictionary is ~4.5 MB

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
/// Uses system curl + gunzip as separate processes (no shell) to avoid Zig gzip
/// decompression bugs: https://github.com/ziglang/zig/issues/20292
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
    // Ensure temp file is cleaned up on any failure
    var tmp_created = false;
    defer if (tmp_created) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
    };

    try w.print("Downloading {s}\n", .{dict_url});
    try w.print("Destination: {s}\n", .{dest_path});
    try w.flush();

    // curl → pipe → gunzip → file (no shell, no injection risk)
    var curl = std.process.Child.init(&.{ "curl", "-sfL", dict_url }, allocator);
    curl.stdout_behavior = .Pipe;
    curl.stderr_behavior = .Inherit;

    curl.spawn() catch |err| {
        try ew.print("Error: failed to run curl: {}. Ensure curl is installed.\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };

    var gunzip = std.process.Child.init(&.{"gunzip"}, allocator);
    gunzip.stdin_behavior = .Pipe;
    gunzip.stdout_behavior = .Pipe;
    gunzip.stderr_behavior = .Inherit;

    gunzip.spawn() catch |err| {
        _ = curl.kill() catch {};
        _ = curl.wait() catch {};
        try ew.print("Error: failed to run gunzip: {}. Ensure gunzip is installed.\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };

    // Open output file
    const out_file = std.fs.cwd().createFile(tmp_path, .{}) catch |err| {
        _ = curl.kill() catch {};
        _ = curl.wait() catch {};
        _ = gunzip.kill() catch {};
        _ = gunzip.wait() catch {};
        try ew.print("Error creating file {s}: {}\n", .{ tmp_path, err });
        try ew.flush();
        return error.FetchFailed;
    };
    tmp_created = true;

    // Pipe data: curl.stdout → gunzip.stdin, gunzip.stdout → file
    // Use threads to avoid deadlocks on pipe buffers.
    // We must close pipe fds ourselves and set them to null before wait(),
    // because wait() calls cleanupStreams() which would double-close.
    const curl_stdout = curl.stdout.?;
    const gunzip_stdin = gunzip.stdin.?;
    const gunzip_stdout = gunzip.stdout.?;

    const pipe_thread = try std.Thread.spawn(.{}, pipeStream, .{ curl_stdout, gunzip_stdin });
    const write_thread = try std.Thread.spawn(.{}, writeToFile, .{ gunzip_stdout, out_file });

    pipe_thread.join();
    write_thread.join();

    out_file.close();

    // Prevent wait() from double-closing pipe fds we already closed in threads
    curl.stdout = null;
    gunzip.stdin = null;
    gunzip.stdout = null;

    const curl_term = curl.wait() catch |err| {
        try ew.print("Error waiting for curl: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    const gunzip_term = gunzip.wait() catch |err| {
        try ew.print("Error waiting for gunzip: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };

    const curl_ok = curl_term == .Exited and curl_term.Exited == 0;
    const gunzip_ok = gunzip_term == .Exited and gunzip_term.Exited == 0;

    if (!curl_ok) {
        try ew.writeAll("Download failed. Check your network connection.\n");
        try ew.flush();
        return error.FetchFailed;
    }
    if (!gunzip_ok) {
        try ew.writeAll("Decompression failed. The downloaded file may be corrupt.\n");
        try ew.flush();
        return error.FetchFailed;
    }

    // Validate: check file size (real dict is ~4.5 MB) and first byte
    const stat = std.fs.cwd().statFile(tmp_path) catch |err| {
        try ew.print("Error: cannot stat downloaded file: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };

    if (stat.size < min_valid_size) {
        try ew.print("Error: downloaded file too small ({d} bytes). Expected > 1 MB.\n", .{stat.size});
        try ew.flush();
        return error.FetchFailed;
    }

    const verify_file = try std.fs.cwd().openFile(tmp_path, .{});
    defer verify_file.close();
    var peek_buf: [1]u8 = undefined;
    const n = try verify_file.read(&peek_buf);
    if (n == 0 or peek_buf[0] != '{') {
        try ew.writeAll("Error: downloaded file does not appear to be valid JSON.\n");
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

    const size_mb = @as(f64, @floatFromInt(stat.size)) / (1024.0 * 1024.0);
    try w.print("Done. ({d:.1} MB)\n", .{size_mb});
    try w.flush();
}

fn pipeStream(src: std.fs.File, dst: std.fs.File) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch break;
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch break;
    }
    dst.close();
}

fn writeToFile(src: std.fs.File, dst: std.fs.File) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch break;
        if (n == 0) break;
        dst.writeAll(buf[0..n]) catch break;
    }
}

test "getConfigDictPath returns valid path" {
    const allocator = std.testing.allocator;
    const path = try getConfigDictPath(allocator);
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "mmcif-dict/mmcif_pdbx.json"));
}
