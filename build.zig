const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string (git tag)") orelse "dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const flags_mod = b.createModule(.{
        .root_source_file = b.path("src/flags/flags.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addOptions("build_options", build_options);
    root_mod.addImport("flags", flags_mod);

    const exe = b.addExecutable(.{
        .name = "zlrd",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zlrd");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const flags_tests = b.addTest(.{
        .root_module = flags_mod,
    });
    test_step.dependOn(&b.addRunArtifact(flags_tests).step);

    const simd_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/reader/simd.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(simd_tests).step);

    inline for ([_][]const u8{
        "src/reader/gzip.zig",
        "src/reader/formats.zig",
        "src/reader/tail.zig",
        "src/reader/reader.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("flags", flags_mod);

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe.step);
}
