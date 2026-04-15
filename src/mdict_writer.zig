const std = @import("std");
const fmt = @import("mdict_format.zig");
const dic = @import("dic_loader.zig");
const Allocator = std.mem.Allocator;

pub const WriteError = error{ OutOfMemory, WriteFailed };

const StringInterner = struct {
    aa: Allocator,
    map: std.StringHashMap(fmt.StrRef),
    pool: std.ArrayList(u8),

    fn init(aa: Allocator) StringInterner {
        return .{ .aa = aa, .map = .init(aa), .pool = .empty };
    }

    fn intern(self: *StringInterner, s: []const u8) !fmt.StrRef {
        if (s.len == 0) return .{ .offset = 0, .len = 0 };
        if (self.map.get(s)) |ref| return ref;
        const off: u32 = @intCast(self.pool.items.len);
        try self.pool.appendSlice(self.aa, s);
        const ref: fmt.StrRef = .{ .offset = off, .len = @intCast(s.len) };
        try self.map.put(s, ref);
        return ref;
    }
};

test "StringInterner dedups identical strings" {
    const allocator = std.testing.allocator;
    var interner = StringInterner.init(allocator);
    defer {
        interner.map.deinit();
        interner.pool.deinit(allocator);
    }

    const a = try interner.intern("hello");
    const b = try interner.intern("hello");
    const c = try interner.intern("world");

    try std.testing.expectEqual(a.offset, b.offset);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(a.offset != c.offset);
    try std.testing.expectEqual(@as(usize, 10), interner.pool.items.len); // "helloworld"
}

test "StringInterner empty string returns null ref" {
    const allocator = std.testing.allocator;
    var interner = StringInterner.init(allocator);
    defer {
        interner.map.deinit();
        interner.pool.deinit(allocator);
    }
    const r = try interner.intern("");
    try std.testing.expectEqual(@as(u32, 0), r.offset);
    try std.testing.expectEqual(@as(u32, 0), r.len);
}
