const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ============================================================
    // Main client executable
    // ============================================================
    const exe = b.addExecutable(.{
        .name = "me-client",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libc for cross-platform socket APIs
    exe.linkLibC();

    b.installArtifact(exe);

    // Run command: zig build run -- [args]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the matching engine client");
    run_step.dependOn(&run_cmd.step);

    // ============================================================
    // Unit tests
    // ============================================================
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Protocol-specific tests
    const protocol_tests = b.addTest(.{
        .root_source_file = b.path("tests/protocol_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_tests.linkLibC();

    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const protocol_test_step = b.step("test-protocol", "Run protocol codec tests");
    protocol_test_step.dependOn(&run_protocol_tests.step);

    // ============================================================
    // Examples
    // ============================================================
    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "simple-order", .path = "examples/simple_order.zig" },
        .{ .name = "market-subscriber", .path = "examples/market_subscriber.zig" },
        .{ .name = "benchmark", .path = "examples/benchmark.zig" },
    };

    for (examples) |example| {
        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });
        example_exe.linkLibC();

        // Add src as module root for imports
        example_exe.root_module.addImport("me_client", b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
        }));

        const install_example = b.addInstallArtifact(example_exe, .{});
        b.getInstallStep().dependOn(&install_example.step);
    }

    // ============================================================
    // Cross-compilation targets
    // ============================================================
    const cross_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
    };

    const cross_step = b.step("cross", "Build for all supported platforms");

    for (cross_targets) |t| {
        const cross_exe = b.addExecutable(.{
            .name = "me-client",
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(t),
            .optimize = .ReleaseFast,
        });
        cross_exe.linkLibC();

        const target_name = std.fmt.comptimePrint("{s}-{s}", .{
            @tagName(t.cpu_arch.?),
            @tagName(t.os_tag.?),
        });

        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = target_name } },
        });
        cross_step.dependOn(&install.step);
    }

    // ============================================================
    // Release build with full optimizations
    // ============================================================
    const release_exe = b.addExecutable(.{
        .name = "me-client",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    release_exe.linkLibC();

    const release_step = b.step("release", "Build optimized release binary");
    release_step.dependOn(&b.addInstallArtifact(release_exe, .{}).step);
}
