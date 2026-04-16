const std = @import("std");

/// Returns true if the given file handle refers to a terminal.
/// Treats errors (e.g. unsupported platform) as "not a tty" so callers
/// fall back to pipe-friendly output.
pub fn isTty(file: std.fs.File) bool {
    return std.posix.isatty(file.handle);
}

/// Returns the terminal width in columns.
/// Reads `$COLUMNS` (set by most interactive shells) and falls back to 80.
/// We intentionally skip `ioctl(TIOCGWINSZ)` to avoid linking libc; $COLUMNS
/// covers the common interactive case, and the 80-column default is the
/// historical baseline.
pub fn width() usize {
    const default_width: usize = 80;
    if (std.posix.getenv("COLUMNS")) |val| {
        return widthFromEnv(val, default_width);
    }
    return default_width;
}

/// Pure helper split out for testability (no env access).
pub fn widthFromEnv(raw: []const u8, default_width: usize) usize {
    const n = std.fmt.parseInt(u16, raw, 10) catch return default_width;
    if (n == 0) return default_width;
    return n;
}

test "widthFromEnv parses COLUMNS value" {
    try std.testing.expectEqual(@as(usize, 120), widthFromEnv("120", 80));
    try std.testing.expectEqual(@as(usize, 80), widthFromEnv("", 80));
    try std.testing.expectEqual(@as(usize, 80), widthFromEnv("abc", 80));
    try std.testing.expectEqual(@as(usize, 80), widthFromEnv("0", 80));
    try std.testing.expectEqual(@as(usize, 200), widthFromEnv("200", 80));
}
