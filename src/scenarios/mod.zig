//! Matching Engine Test Scenarios
//!
//! Pre-built test scenarios for validating the matching engine client.
//! This module provides the public API and dispatches to specialized
//! scenario modules.
//!
//! Structure:
//!   - config.zig:         Tunable parameters
//!   - types.zig:          ResponseStats and related types
//!   - helpers.zig:        Print utilities, message parsing
//!   - drain.zig:          Response drain functions
//!   - basic.zig:          Scenarios 1-3 (interactive)
//!   - stress.zig:         Scenarios 10-12 (unmatched stress)
//!   - matching.zig:       Scenarios 20-25 (single processor matching)
//!   - dual_processor.zig: Scenarios 30-32 (dual processor)

const std = @import("std");

// Re-export config for external access
pub const config = @import("config.zig");
pub const types = @import("types.zig");
pub const helpers = @import("helpers.zig");
pub const drain = @import("drain.zig");

// Scenario modules
const basic = @import("basic.zig");
const stress = @import("stress.zig");
const matching = @import("matching.zig");
const dual_processor = @import("dual_processor.zig");
const threaded = @import("threaded.zig");

const EngineClient = @import("../client/engine_client.zig").EngineClient;

// ============================================================
// Public API
// ============================================================

/// Set quiet mode (reduces output)
pub fn setQuiet(q: bool) void {
    config.setQuiet(q);
}

/// Run a scenario by ID
pub fn run(client: *EngineClient, scenario: u8, stderr: std.fs.File) !void {
    switch (scenario) {
        // Basic scenarios (interactive)
        1 => try basic.runScenario1(client, stderr),
        2 => try basic.runScenario2(client, stderr),
        3 => try basic.runScenario3(client, stderr),

        // Unmatched stress tests
        10 => try stress.runStressTest(client, stderr, 1_000),
        11 => try stress.runStressTest(client, stderr, 10_000),
        12 => try stress.runStressTest(client, stderr, 100_000),

        // Single-processor matching stress
        20 => try matching.runMatchingStress(client, stderr, 1_000),
        21 => try matching.runMatchingStress(client, stderr, 10_000),
        22 => try matching.runMatchingStress(client, stderr, 100_000),
        23 => try matching.runMatchingStress(client, stderr, 250_000),
        24 => try matching.runMatchingStress(client, stderr, 500_000),
        25 => try matching.runMatchingStress(client, stderr, 250_000_000),

        // Dual-processor matching stress
        30 => try dual_processor.runDualProcessorStress(client, stderr, 500_000),
        31 => try dual_processor.runDualProcessorStress(client, stderr, 1_000_000),
        32 => try dual_processor.runDualProcessorStress(client, stderr, 100_000_000),

        // THREADED scenarios (separate send/recv threads)
        40 => try threaded.runThreadedMatchingStress(client, stderr, 1_000),
        41 => try threaded.runThreadedMatchingStress(client, stderr, 10_000),
        42 => try threaded.runThreadedMatchingStress(client, stderr, 100_000),
        43 => try threaded.runThreadedMatchingStress(client, stderr, 250_000),
        44 => try threaded.runThreadedMatchingStress(client, stderr, 500_000),
        45 => try threaded.runThreadedMatchingStress(client, stderr, 1_000_000),

        else => {
            try printAvailableScenarios(stderr);
            return error.UnknownScenario;
        },
    }
}

/// Print list of available scenarios
pub fn printAvailableScenarios(stderr: std.fs.File) !void {
    try helpers.print(stderr, "Available scenarios:\n", .{});
    try helpers.print(stderr, "\nBasic (interactive):\n", .{});
    try helpers.print(stderr, "  1 - Simple orders (no matching)\n", .{});
    try helpers.print(stderr, "  2 - Matching trade\n", .{});
    try helpers.print(stderr, "  3 - Cancel order\n", .{});
    try helpers.print(stderr, "\nUnmatched stress:\n", .{});
    try helpers.print(stderr, "  10 - 1K orders\n", .{});
    try helpers.print(stderr, "  11 - 10K orders\n", .{});
    try helpers.print(stderr, "  12 - 100K orders\n", .{});
    try helpers.print(stderr, "\nMatching (single processor - IBM):\n", .{});
    try helpers.print(stderr, "  20 - 1K trades\n", .{});
    try helpers.print(stderr, "  21 - 10K trades\n", .{});
    try helpers.print(stderr, "  22 - 100K trades\n", .{});
    try helpers.print(stderr, "  23 - 250K trades\n", .{});
    try helpers.print(stderr, "  24 - 500K trades\n", .{});
    try helpers.print(stderr, "  25 - 250M trades ★★★ LEGENDARY ★★★\n", .{});
    try helpers.print(stderr, "\nDual-Processor (IBM + NVDA):\n", .{});
    try helpers.print(stderr, "  30 - 500K trades  (250K each)\n", .{});
    try helpers.print(stderr, "  31 - 1M trades    (500K each)\n", .{});
    try helpers.print(stderr, "  32 - 100M trades  (50M each)  ★★★ ULTIMATE ★★★\n", .{});
    try helpers.print(stderr, "\nTHREADED (separate send/recv threads):\n", .{});
    try helpers.print(stderr, "  40 - 1K trades   (threaded)\n", .{});
    try helpers.print(stderr, "  41 - 10K trades  (threaded)\n", .{});
    try helpers.print(stderr, "  42 - 100K trades (threaded)\n", .{});
    try helpers.print(stderr, "  43 - 250K trades (threaded)\n", .{});
    try helpers.print(stderr, "  44 - 500K trades (threaded)\n", .{});
    try helpers.print(stderr, "  45 - 1M trades   (threaded) ★★★ BEAST MODE ★★★\n", .{});
}

// ============================================================
// Tests
// ============================================================

test "ResponseStats add" {
    var a = types.ResponseStats{ .acks = 10, .trades = 5 };
    const b = types.ResponseStats{ .acks = 20, .trades = 10 };
    a.add(b);
    try std.testing.expectEqual(@as(u64, 30), a.acks);
    try std.testing.expectEqual(@as(u64, 15), a.trades);
}

test "ResponseStats total" {
    const stats = types.ResponseStats{ .acks = 100, .trades = 50, .top_of_book = 100 };
    try std.testing.expectEqual(@as(u64, 250), stats.total());
}
