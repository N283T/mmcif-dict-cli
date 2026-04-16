const std = @import("std");
const dic_loader = @import("dic_loader.zig");
const mdict_writer = @import("mdict_writer.zig");
const Allocator = std.mem.Allocator;

pub const default_url = "https://mmcif.wwpdb.org/dictionaries/ascii/mmcif_pdbx_v50.dic";
pub const default_name = "pdbx";

const config_dir_name = "mmcif-dict";
const mdict_ext = ".mdict";
const max_name_len: usize = 64;

/// Cap on in-memory HTTP response size. Real dictionaries are 5–10 MB; 128 MB
/// is generous for legitimate content while preventing a runaway server from
/// exhausting host memory.
pub const max_download_bytes: usize = 128 * 1024 * 1024;

/// Helper: fetch an env var and treat empty-string the same as unset so that
/// `HOME=""` doesn't silently produce a root-relative path.
fn getEnvNonEmpty(allocator: Allocator, key: []const u8) !?[]const u8 {
    const value = std.process.getEnvVarOwned(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (value.len == 0) {
        allocator.free(value);
        return null;
    }
    return value;
}

/// Return the config directory: ~/.config/mmcif-dict/
fn getConfigDir(allocator: Allocator) ![]const u8 {
    const config_home_opt = try getEnvNonEmpty(allocator, "XDG_CONFIG_HOME");
    if (config_home_opt) |config_home| {
        defer allocator.free(config_home);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ config_home, config_dir_name });
    }
    const home = (try getEnvNonEmpty(allocator, "HOME")) orelse return error.HomeNotFound;
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/.config/{s}", .{ home, config_dir_name });
}

/// Validate a cache name. Cache names map directly to files under the config dir,
/// so they must be a single path segment containing only safe, printable ASCII.
/// Accepts `[A-Za-z0-9_-]+` with a length cap — conservative on purpose since
/// the name is untrusted input (URL basenames, --name flag values).
fn validateName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidName;
    if (name[0] == '-' or name[0] == '.') return error.InvalidName;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return error.InvalidName;
    }
}

/// Return the cache path for a named dictionary, e.g. ~/.config/mmcif-dict/pdbx.mdict
pub fn getConfigMdictPath(allocator: Allocator, name: []const u8) ![]const u8 {
    try validateName(name);
    const dir = try getConfigDir(allocator);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir, name, mdict_ext });
}

/// Derive a cache name from a dictionary URL's basename. Strips `.dic` / `.dic.gz`.
/// Returns `null` when the basename is empty or would fail `validateName`, so
/// callers can decide whether to fall back silently or warn the user.
pub fn nameFromUrl(url: []const u8) ?[]const u8 {
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
    if (stem.len == 0) return null;
    validateName(stem) catch return null;
    return stem;
}

/// Print a human-readable explanation of a fetch error. Broad catches that
/// conflate "network down" with "TLS broken" with "out of memory" mislead
/// users, so each error class gets specific guidance.
///
/// The Zig 0.15 TLS error set has many `TlsAlert*` variants (e.g.
/// `TlsAlertHandshakeFailure`, `TlsAlertBadCertificate`) and enumerating them
/// all is brittle; we pattern-match the error name prefix in the `else` arm.
fn printFetchError(ew: *std.io.Writer, err: anyerror) !void {
    switch (err) {
        error.OutOfMemory => {
            try ew.writeAll("Download failed: out of memory while reading response.\n");
            try ew.writeAll("The server may be streaming more data than expected.\n");
        },
        error.UnknownHostName, error.NameServerFailure, error.TemporaryNameServerFailure => {
            try ew.print("Download failed: {}. DNS resolution failed.\n", .{err});
        },
        error.ConnectionRefused, error.ConnectionResetByPeer, error.ConnectionTimedOut, error.NetworkUnreachable => {
            try ew.print("Download failed: {}. Check your network connection.\n", .{err});
        },
        error.TlsInitializationFailed, error.CertificateBundleLoadFailure => {
            try ew.print("Download failed: {}. TLS/certificate error.\n", .{err});
        },
        error.TooManyHttpRedirects, error.RedirectRequiresResend => {
            try ew.print("Download failed: {}. Redirect loop or unsupported redirect.\n", .{err});
        },
        error.UnsupportedUriScheme, error.UriMissingHost, error.UriHostTooLong => {
            try ew.print("Download failed: {}. The URL is malformed.\n", .{err});
        },
        else => {
            const name = @errorName(err);
            if (std.mem.startsWith(u8, name, "Tls")) {
                try ew.print("Download failed: {s}. TLS/certificate error.\n", .{name});
            } else {
                try ew.print("Download failed: {}.\n", .{err});
            }
        },
    }
}

/// Detect common non-CIF responses (HTML error pages, XML, JSON) so the user
/// gets an actionable message instead of "CIF parse error".
fn sniffNonCif(body: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == '\r' or body[i] == '\n')) : (i += 1) {}
    const head = body[i..];
    if (std.mem.startsWith(u8, head, "<!DOCTYPE") or
        std.mem.startsWith(u8, head, "<!doctype") or
        std.mem.startsWith(u8, head, "<html") or
        std.mem.startsWith(u8, head, "<HTML"))
    {
        return "HTML";
    }
    if (std.mem.startsWith(u8, head, "<?xml")) return "XML";
    if (head.len > 0 and (head[0] == '{' or head[0] == '[')) return "JSON";
    return null;
}

/// Download a CIF dictionary and compile it to the named `.mdict` cache.
/// The cache is written via write-to-temp + atomic rename. Response size is
/// capped at `max_download_bytes` to prevent runaway servers from exhausting
/// memory.
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
        try printFetchError(ew, err);
        try ew.flush();
        return error.FetchFailed;
    };
    // Post-hoc size guard. std.http.Client.fetch has no built-in cap in Zig
    // 0.15, so a pathological server could technically push past this into
    // OOM territory — but the check bounds the happy path and fails loudly
    // when a server misbehaves in recoverable ways.
    if (body_writer.written().len > max_download_bytes) {
        try ew.print(
            "Download failed: response exceeds {d} bytes, aborting.\n",
            .{max_download_bytes},
        );
        try ew.flush();
        return error.FetchFailed;
    }
    if (result.status != .ok) {
        const code = @intFromEnum(result.status);
        try ew.print("Download failed (HTTP {d}).\n", .{code});
        if (code >= 500) {
            try ew.writeAll("The server may be temporarily unavailable. Please try again later.\n");
        } else if (result.status == .not_found) {
            try ew.writeAll("The dictionary URL may have changed. Check for updates.\n");
        } else if (code == 401 or code == 403) {
            try ew.writeAll("The server requires authentication or the URL is not publicly accessible.\n");
        } else if (code == 429) {
            try ew.writeAll("Rate-limited; please wait and retry.\n");
        }
        try ew.flush();
        return error.FetchFailed;
    }

    const body_bytes = body_writer.written();
    if (body_bytes.len == 0) {
        try ew.writeAll("Download failed: server returned an empty body.\n");
        try ew.flush();
        return error.FetchFailed;
    }
    if (sniffNonCif(body_bytes)) |kind| {
        try ew.print("Download failed: server returned {s} content, not a CIF dictionary.\n", .{kind});
        try ew.writeAll("The URL may be wrong, require authentication, or be behind a captive portal.\n");
        try ew.flush();
        return error.FetchFailed;
    }

    try w.print("Compiling {d} bytes -> {s}\n", .{ body_bytes.len, dest_path });
    try w.flush();

    var bd = dic_loader.loadFromDicBytes(allocator, body_bytes) catch |err| {
        try ew.print("Compile failed: {}. The response did not parse as a CIF dictionary.\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    defer bd.deinit();

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest_path});
    defer allocator.free(tmp_path);

    // Cover the entire window from when writeToFile may have created the file
    // until rename succeeds. Set before the call so partial writes are cleaned up.
    var tmp_exists = true;
    defer if (tmp_exists) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
    };

    mdict_writer.writeToFile(allocator, &bd, tmp_path) catch |err| {
        try ew.print("Write failed: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };

    std.fs.cwd().rename(tmp_path, dest_path) catch |err| {
        try ew.print("Rename failed: {}\n", .{err});
        try ew.flush();
        return error.FetchFailed;
    };
    tmp_exists = false;

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
    // Tightened allowlist: reject anything outside [A-Za-z0-9_-]
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "foo bar"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "foo\x00bar"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "foo\nbar"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "foo."));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "-flag"));
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, "foo\xffbar"));
    // Length cap
    const too_long = "a" ** 65;
    try std.testing.expectError(error.InvalidName, getConfigMdictPath(allocator, too_long));
}

test "nameFromUrl extracts stem" {
    try std.testing.expectEqualStrings(
        "mmcif_pdbx_v50",
        nameFromUrl("https://mmcif.wwpdb.org/dictionaries/ascii/mmcif_pdbx_v50.dic").?,
    );
    try std.testing.expectEqualStrings(
        "mmcif_ihm",
        nameFromUrl("https://example.com/mmcif_ihm.dic.gz").?,
    );
    try std.testing.expect(nameFromUrl("https://example.com/") == null);
}

test "nameFromUrl strips query string and fragment" {
    try std.testing.expectEqualStrings(
        "mmcif_pdbx_v50",
        nameFromUrl("https://example.com/mmcif_pdbx_v50.dic?token=abc").?,
    );
    try std.testing.expectEqualStrings(
        "mmcif_pdbx_v50",
        nameFromUrl("https://example.com/mmcif_pdbx_v50.dic#section").?,
    );
}

test "nameFromUrl returns null on empty or hidden stems" {
    try std.testing.expect(nameFromUrl("https://example.com/.dic") == null);
    try std.testing.expect(nameFromUrl("https://example.com/.hidden.dic") == null);
    try std.testing.expect(nameFromUrl("https://example.com/foo bar.dic") == null);
}

test "sniffNonCif detects HTML" {
    try std.testing.expectEqualStrings("HTML", sniffNonCif("<!DOCTYPE html><html>").?);
    try std.testing.expectEqualStrings("HTML", sniffNonCif("<!doctype HTML>").?);
    try std.testing.expectEqualStrings("HTML", sniffNonCif("<html><body>").?);
    try std.testing.expectEqualStrings("HTML", sniffNonCif("<HTML>").?);
    try std.testing.expectEqualStrings("HTML", sniffNonCif("  \r\n<html>").?);
}

test "sniffNonCif detects XML and JSON" {
    try std.testing.expectEqualStrings("XML", sniffNonCif("<?xml version=\"1.0\"?>").?);
    try std.testing.expectEqualStrings("JSON", sniffNonCif("{\"error\":\"not found\"}").?);
    try std.testing.expectEqualStrings("JSON", sniffNonCif("[1, 2, 3]").?);
    try std.testing.expectEqualStrings("JSON", sniffNonCif("  \n{\"ok\": true}").?);
}

test "sniffNonCif returns null on valid CIF bodies" {
    try std.testing.expect(sniffNonCif("data_mmcif_pdbx\n") == null);
    try std.testing.expect(sniffNonCif("# comment\n_cat.foo bar\n") == null);
    try std.testing.expect(sniffNonCif("save_frame_x\n") == null);
    try std.testing.expect(sniffNonCif("loop_\n_atom.id\n") == null);
    try std.testing.expect(sniffNonCif("") == null);
    try std.testing.expect(sniffNonCif("   \n\t") == null);
}
