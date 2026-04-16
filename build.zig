const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Stage 1: compile_tool binary (host target, Debug) — converts .dic to .mdict.
    const compile_tool = b.addExecutable(.{
        .name = "mmcif-dict-compile-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_tool.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // Stage 2: run compile_tool against data/mmcif_pdbx.dic to produce the
    // default cache embedded into the main binary.
    const run_compile = b.addRunArtifact(compile_tool);
    run_compile.addFileArg(b.path("data/mmcif_pdbx.dic"));
    run_compile.addArg("-o");
    const embedded_mdict = run_compile.addOutputFileArg("mmcif_pdbx.mdict");

    // Stage 3: main executable. Imports the generated .mdict via @embedFile
    // so distributed binaries are self-contained.
    const exe = b.addExecutable(.{
        .name = "mmcif-dict",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addAnonymousImport("embedded_pdbx", .{
        .root_source_file = embedded_mdict,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run mmcif-dict");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
