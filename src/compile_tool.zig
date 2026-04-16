//! Stage-1 build helper: compile a CIF `.dic` to a native `.mdict`.
//!
//! Invoked by build.zig to produce the embedded default dictionary. This is
//! a minimal CLI (`compile_tool INPUT.dic -o OUTPUT.mdict`) kept separate
//! from the main binary so the main build can @embedFile the generated
//! artifact without bootstrapping issues.
const std = @import("std");
const dic_loader = @import("dic_loader.zig");
const mdict_writer = @import("mdict_writer.zig");

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len != 4 or !std.mem.eql(u8, args[2], "-o")) {
        std.debug.print("usage: compile_tool <input.dic> -o <output.mdict>\n", .{});
        std.process.exit(2);
    }

    var bd = try dic_loader.loadFromDicFile(gpa, args[1]);
    defer bd.deinit();
    try mdict_writer.writeToFile(gpa, &bd, args[3]);
}
