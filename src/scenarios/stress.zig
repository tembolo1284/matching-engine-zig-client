//! Unmatched Stress Scenarios (10, 11, 12)
//!
//! Send orders at different prices that won't match.
//! Good for testing raw throughput without matching overhead.

const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const helpers = @import("helpers.zig");
const drain = @import("drain.zig");

const EngineClient = @import("../client/engine_client.zig").EngineClient;
const timestamp = @import("../util/timestamp.zig");

// ============================================================
// Unmatched Stress Test
// ============================================================

pub fn runStressTest(client: *EngineClient, stderr: std.fs.File, count: u32) !void {
    try helpers.print(stderr, "=== Unmatched Stress: {d} Orders ===\n\n", .{count});

    // Initial flush
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);
    _ = try drain.drainAllAvailable(client);

    var running_stats = types.ResponseStats{};
    const progress_interval = count / 4; // Report at 25%, 50%, 75%

    const start_time = timestamp.now();

    // Send phase
    for (0..count) |i| {
        const price: u32 = 100 + @as(u32, @intCast(i % 100));
        const order_id: u32 = @intCast(i + 1);
        try client.sendNewOrder(1, "IBM", price, 10, .buy, order_id);

        // Periodic drain to prevent buffer overflow
        if (i > 0 and i % config.UNMATCHED_DRAIN_INTERVAL == 0) {
            const batch_stats = try drain.drainAllAvailable(client);
            running_stats.add(batch_stats);
        }

        // Progress reporting
        if (!config.quiet and progress_interval > 0 and i > 0 and i % progress_interval == 0) {
            const pct = (i * 100) / count;
            const elapsed_ms = (timestamp.now() - start_time) / config.NS_PER_MS;
            try helpers.print(stderr, "  {d}% | {d} sent | {d} recv'd | {d} ms\n", .{
                pct, i, running_stats.total(), elapsed_ms,
            });
        }
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;

    // Report send phase
    try helpers.print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try helpers.print(stderr, "Orders sent:     {d}\n", .{count});
    try helpers.printTime(stderr, "Send time:       ", send_time);
    if (send_time > 0) {
        const send_rate: u64 = @as(u64, count) * config.NS_PER_SEC / send_time;
        try helpers.printThroughput(stderr, "Send rate:       ", send_rate);
    }

    // Final drain
    try helpers.print(stderr, "\nDraining responses...\n", .{});
    const expected = @as(u64, count) * config.MSGS_PER_UNMATCHED_ORDER;
    const final_stats = try drain.drainWithPatience(client, expected - running_stats.total(), config.DEFAULT_DRAIN_TIMEOUT_MS);
    running_stats.add(final_stats);

    const total_time = timestamp.now() - start_time;
    try helpers.print(stderr, "\n=== Total Time ===\n", .{});
    try helpers.printTime(stderr, "Total:           ", total_time);

    try running_stats.printValidation(count, 0, stderr);

    // Cleanup
    try helpers.print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * config.NS_PER_MS);
}
