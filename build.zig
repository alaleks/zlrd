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

    // A second options module with the eBPF backend forced on, used for one
    // extra compile of `ebpf.zig` under `zig build test`.
    //
    // This only bites on a Linux host: the backend's functions open with a
    // comptime `if (os.tag != .linux) return`, after which Zig stops
    // analysing the body, so a macOS test run cannot see inside it either
    // way. The guarantee for everyone else is the cross-compile step in CI —
    // `-Dtarget=…-linux -Dwith-ebpf=true` is what actually catches a break
    // here, and the backend went un-compiled long enough to accumulate one
    // against the 0.16 `perf_event_attr` layout.
    const ebpf_on_options = b.addOptions();
    ebpf_on_options.addOption([]const u8, "version", version);
    ebpf_on_options.addOption(bool, "with_ebpf", true);
    const ebpf_on_options_mod = ebpf_on_options.createModule();

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

    const sidecar_mod = b.createModule(.{
        .root_source_file = b.path("src/sidecar/sidecar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const journal_mod = b.createModule(.{
        .root_source_file = b.path("src/journal/journal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const agent_mod = b.createModule(.{
        .root_source_file = b.path("src/agent/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_mod.addImport("flags", flags_mod);
    agent_mod.addImport("regex", regex_mod);
    agent_mod.addImport("simd", simd_mod);
    agent_mod.addImport("kernel", kernel_mod);
    agent_mod.addImport("sidecar", sidecar_mod);
    agent_mod.addImport("journal", journal_mod);

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

    // Reader-only executable (`zlrd-lite`). Shares the flags / simd / regex /
    // reader source with the full binary but does not link agent, journal,
    // kernel, or sidecar code — smaller footprint for users who only need
    // filtering + tailing.
    const lite_root_mod = b.createModule(.{
        .root_source_file = b.path("src/main_lite.zig"),
        .target = target,
        .optimize = optimize,
    });
    lite_root_mod.addImport("build_options", build_options_mod);
    lite_root_mod.addImport("flags", flags_mod);
    lite_root_mod.addImport("simd", simd_mod);
    lite_root_mod.addImport("regex", regex_mod);

    const exe_lite = b.addExecutable(.{
        .name = "zlrd-lite",
        .root_module = lite_root_mod,
    });
    b.installArtifact(exe_lite);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zlrd");
    run_step.dependOn(&run_cmd.step);

    const run_lite_cmd = b.addRunArtifact(exe_lite);
    run_lite_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_lite_cmd.addArgs(args);
    }
    const run_lite_step = b.step("run-lite", "Run zlrd-lite");
    run_lite_step.dependOn(&run_lite_cmd.step);

    const test_step = b.step("test", "Run unit tests");

    const flags_tests = b.addTest(.{
        .root_module = flags_mod,
    });
    test_step.dependOn(&b.addRunArtifact(flags_tests).step);

    const simd_tests = b.addTest(.{ .root_module = simd_mod });
    test_step.dependOn(&b.addRunArtifact(simd_tests).step);

    inline for ([_][]const u8{
        "src/reader/gzip.zig",
        "src/reader/tail.zig",
        "src/reader/reader.zig",
        "src/reader/regex.zig",
        "src/reader/theme.zig",
        "src/reader/jsonx.zig",
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
        "src/agent/service.zig",
        "src/agent/journal.zig",
        "src/agent/exporter.zig",
        "src/agent/webhook.zig",
        "src/agent/watcher.zig",
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
        mod.addImport("sidecar", sidecar_mod);
        mod.addImport("journal", journal_mod);

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    inline for ([_][]const u8{
        "src/journal/format.zig",
        "src/journal/lz4.zig",
        "src/journal/reader.zig",
        "src/journal/tail.zig",
        "src/journal/source.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    inline for ([_][]const u8{
        "src/kernel/kernel.zig",
        "src/kernel/kmsg.zig",
        "src/kernel/pstore.zig",
        "src/kernel/ebpf.zig",
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

    inline for ([_][]const u8{
        "src/sidecar/protobuf.zig",
        "src/sidecar/otlp.zig",
        "src/sidecar/transport.zig",
    }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    {
        const tests = b.addTest(.{ .root_module = sidecar_mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // Compile-only check of the eBPF backend with the feature enabled. See
    // `ebpf_on_options`: meaningful on a Linux host, a no-op elsewhere.
    {
        const mod = b.createModule(.{
            .root_source_file = b.path("src/kernel/ebpf.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("build_options", ebpf_on_options_mod);
        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    // The two entry points carry no tests of their own, but registering them
    // means `zig build test` type-checks them in a test build too.
    inline for ([_][]const u8{ "src/main.zig", "src/main_lite.zig" }) |path| {
        const mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("build_options", build_options_mod);
        mod.addImport("flags", flags_mod);
        mod.addImport("simd", simd_mod);
        mod.addImport("regex", regex_mod);
        if (comptime std.mem.eql(u8, path, "src/main.zig")) mod.addImport("agent", agent_mod);

        const tests = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe.step);
    check.dependOn(&exe_lite.step);
}
