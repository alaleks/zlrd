const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allow users to choose what target to build for.
    // Common usage: zig build -Dtarget=x86_64-linux
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow users to select between Debug,
    // ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // Create the root module for the executable.
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build the main executable.
    const exe = b.addExecutable(.{
        .name = "zlrd",
        .root_module = root_mod,
    });

    // Install the executable to the output directory.
    b.installArtifact(exe);

    // Create a run step for the executable.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Forward any command-line arguments to the executable.
    // Usage: zig build run -- -f log.txt -l Error
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zlrd");
    run_step.dependOn(&run_cmd.step);

    // Add unit tests for the flags module.
    const flags_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/flags/flags.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_flags_tests = b.addRunArtifact(flags_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_flags_tests.step);

    // Add a check step to verify the code compiles without building.
    // This is useful for CI/CD pipelines.
    const check = b.step("check", "Check if code compiles");
    check.dependOn(&exe.step);
}
