const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version from git tag, e.g. zig build -Dversion="$(git describe --tags --always)"
    const version = b.option([]const u8, "version", "Version string (git tag)") orelse "dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addOptions("build_options", build_options);

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

    // ── Tests ────────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run unit tests");

    const flags_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flags/flags.zig"),
            .target = target,
            .optimize = optimize,
        }),
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

    const flags_mod = b.createModule(.{
        .root_source_file = b.path("src/flags/flags.zig"),
        .target = target,
        .optimize = optimize,
    });

    const formats_test_mod = b.createModule(.{
        .root_source_file = b.path("src/reader/formats.zig"),
        .target = target,
        .optimize = optimize,
    });
    formats_test_mod.addImport("../flags/flags.zig", flags_mod);
    const formats_tests = b.addTest(.{ .root_module = formats_test_mod });
    test_step.dependOn(&b.addRunArtifact(formats_tests).step);

    const tail_test_mod = b.createModule(.{
        .root_source_file = b.path("src/reader/tail.zig"),
        .target = target,
        .optimize = optimize,
    });
    tail_test_mod.addImport("../flags/flags.zig", flags_mod);
    const tail_tests = b.addTest(.{ .root_module = tail_test_mod });
    test_step.dependOn(&b.addRunArtifact(tail_tests).step);

    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe.step);
}
