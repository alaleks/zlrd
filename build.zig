const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Version string (git tag)") orelse "dev";
    const with_ebpf = b.option(bool, "with-ebpf", "Enable eBPF kernel probes (Linux only)") orelse false;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    build_options.addOption(bool, "with_ebpf", with_ebpf);
    const build_options_mod = build_options.createModule();

    const flags_mod = b.createModule(.{
        .root_source_file = b.path("src/flags/flags.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared regex module so both `reader/` and `agent/` import the same code.
    const regex_mod = b.createModule(.{
        .root_source_file = b.path("src/reader/regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Shared simd helpers (level extraction in agent + parser in reader).
    const simd_mod = b.createModule(.{
        .root_source_file = b.path("src/reader/simd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/kernel/kernel.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel_mod.addImport("build_options", build_options_mod);

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("flags", flags_mod);
    agent_mod.addImport("regex", regex_mod);
    agent_mod.addImport("simd", simd_mod);
    agent_mod.addImport("kernel", kernel_mod);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("build_options", build_options_mod);
    root_mod.addImport("flags", flags_mod);
    root_mod.addImport("agent", agent_mod);
    root_mod.addImport("simd", simd_mod);
    root_mod.addImport("regex", regex_mod);

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

    const simd_tests = b.addTest(.{ .root_module = simd_mod });
    test_step.dependOn(&b.addRunArtifact(simd_tests).step);

    inline for ([_][]const u8{
        "src/reader/gzip.zig",
        "src/reader/formats.zig",
        "src/reader/tail.zig",
        "src/reader/reader.zig",
        "src/reader/regex.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("flags", flags_mod);
        mod.addImport("simd", simd_mod);
        mod.addImport("regex", regex_mod);

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    inline for ([_][]const u8{
        "src/agent/config.zig",
        "src/agent/signature.zig",
        "src/agent/metrics.zig",
        "src/agent/rules.zig",
        "src/agent/alert.zig",
        "src/agent/server.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("flags", flags_mod);
        mod.addImport("regex", regex_mod);
        mod.addImport("simd", simd_mod);
        mod.addImport("kernel", kernel_mod);

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    inline for ([_][]const u8{
        "src/kernel/kernel.zig",
        "src/kernel/kmsg.zig",
        "src/kernel/pstore.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("build_options", build_options_mod);

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe.step);
}
