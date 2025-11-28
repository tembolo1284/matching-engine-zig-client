const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const me_client_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    me_client_mod.link_libc = true;

    const exe = b.addExecutable(.{
        .name = "me-client",
        .root_module = me_client_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the matching engine client");
    run_step.dependOn(&run_cmd.step);

    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_mod.link_libc = true;

    const unit_tests = b.addTest(.{
        .root_module = unit_test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const protocol_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/protocol_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    protocol_test_mod.link_libc = true;

    const protocol_tests = b.addTest(.{
        .root_module = protocol_test_mod,
    });

    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    const protocol_test_step = b.step("test-protocol", "Run protocol codec tests");
    protocol_test_step.dependOn(&run_protocol_tests.step);

    const examples = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "simple-order", .path = "examples/simple_order.zig" },
        .{ .name = "market-subscriber", .path = "examples/market_subscriber.zig" },
        .{ .name = "benchmark", .path = "examples/benchmark.zig" },
    };

    for (examples) |example| {
        const example_mod = b.createModule(.{
            .root_source_file = b.path(example.path),
            .target = target,
            .optimize = optimize,
        });
        example_mod.link_libc = true;
        example_mod.addImport("me_client", me_client_mod);

        const example_exe = b.addExecutable(.{
            .name = example.name,
            .root_module = example_mod,
        });

        const install_example = b.addInstallArtifact(example_exe, .{});
        b.getInstallStep().dependOn(&install_example.step);
    }

    const CrossTarget = struct {
        cpu_arch: std.Target.Cpu.Arch,
        os_tag: std.Target.Os.Tag,
        name: []const u8,
    };

    const cross_targets = [_]CrossTarget{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .name = "x86_64-linux" },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .name = "aarch64-linux" },
        .{ .cpu_arch = .x86_64, .os_tag = .macos, .name = "x86_64-macos" },
        .{ .cpu_arch = .aarch64, .os_tag = .macos, .name = "aarch64-macos" },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .name = "x86_64-windows" },
    };

    const cross_step = b.step("cross", "Build for all supported platforms");

    for (cross_targets) |t| {
        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = t.cpu_arch,
                .os_tag = t.os_tag,
            }),
            .optimize = .ReleaseFast,
        });
        cross_mod.link_libc = true;

        const cross_exe = b.addExecutable(.{
            .name = "me-client",
            .root_module = cross_mod,
        });

        const install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = t.name } },
        });
        cross_step.dependOn(&install.step);
    }

    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    release_mod.link_libc = true;

    const release_exe = b.addExecutable(.{
        .name = "me-client",
        .root_module = release_mod,
    });

    const release_step = b.step("release", "Build optimized release binary");
    release_step.dependOn(&b.addInstallArtifact(release_exe, .{}).step);
}
