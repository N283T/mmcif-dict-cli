const std = @import("std");

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);
    try w.interface.print("mmcif-dict v0.1.0\n", .{});
    try w.interface.flush();
}
