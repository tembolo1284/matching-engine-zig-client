//! Matching Stress Scenarios (20-25)
//!
//! Send buy/sell pairs at the same price to generate trades.
//! Uses adaptive pacing to prevent TCP buffer overflow.
const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const helpers = @import("helpers.zig");
const drain = @import("drain.zig");
const EngineClient = @import("../client/engine_client.zig").EngineClient;
const timestamp = @import("../util/timestamp.zig");

// ============================================================
// Adaptive Pacing Parameters (match C client)
// ============================================================

/// Maximum trades we can fall behind before pausing to catch up
const MAX_DEFICIT: u64 = 5000;

/// Drain until only this far behind before resuming sends
const CATCHUP_TARGET: u64 = 1000;

/// Final drain stall timeout (60 seconds - be very patient)
const FINAL_DRAIN_STALL_MS: u64 = 60000;

// ============================================================
// Matching Stress Test (Single Processor) - ADAPTIVE PACING
// ============================================================

pub fn runMatchingStress(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const orders = trades * 2;

    // Header
    if (trades >= 100_000_000) {
        try printLegendaryHeader(stderr, trades, orders);
    } else {
        try helpers.print(stderr, "=== Matching Stress Test: {d} Trade Pairs ===\n\n", .{trades});
    }

    try helpers.print(stderr, "Sending {d} buy/sell pairs (should generate {d} trades)...\n\n", .{ trades, trades });

    // Initial flush
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);

    // Clear any stale data
    if (client.tcp_client) |*tcp| {
        var cleared: u32 = 0;
        while (cleared < 1000) : (cleared += 1) {
            const d = tcp.tryRecv(1) catch break;
            if (d == null) break;
        }
    }

    var running_stats = types.ResponseStats{};
    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;

    // Progress tracking
    const progress_interval: u64 = if (trades >= 20) trades / 20 else 1;
    var last_progress: u64 = 0;

    const start_time = timestamp.now();

    // Send phase with adaptive pacing
    var i: u64 = 0;
    while (i < trades) : (i += 1) {
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
        const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

        // Send buy
        client.sendNewOrder(1, "IBM", price, 10, .buy, buy_oid) catch {
            send_errors += 1;
            continue;
        };

        // Quick non-blocking receive
        const quick1 = drain.drainAllAvailable(client) catch types.ResponseStats{};
        running_stats.add(quick1);

        // Send matching sell
        client.sendNewOrder(1, "IBM", price, 10, .sell, sell_oid) catch {
            send_errors += 1;
            continue;
        };

        // Quick non-blocking receive
        const quick2 = drain.drainAllAvailable(client) catch types.ResponseStats{};
        running_stats.add(quick2);

        pairs_sent += 1;

        // ADAPTIVE PACING: If falling too far behind on trades, pause and drain
        const expected_trades = pairs_sent; // 1 trade per pair
        if (expected_trades > running_stats.trades + MAX_DEFICIT) {
            // We're too far behind - drain until caught up
            const target = expected_trades - CATCHUP_TARGET;
            try drain.drainUntilTrades(client, &running_stats, target, 5000); // 5 sec max stall
        }

        // Progress indicator (every 5%)
        if (i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct: u64 = (i * 100) / trades;
            const elapsed_ns = timestamp.now() - start_time;
            const elapsed_ms = elapsed_ns / config.NS_PER_MS;
            const orders_sent_so_far = i * 2;
            const rate: u64 = if (elapsed_ms > 0) orders_sent_so_far * 1000 / elapsed_ms else 0;
            const deficit = pairs_sent - running_stats.trades;

            try helpers.print(stderr, "  {d}% | {d} pairs | {d}ms | {d}/s | {d} trades | deficit {d}\n", .{
                pct,
                i,
                elapsed_ms,
                rate,
                running_stats.trades,
                deficit,
            });
        }
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;
    const orders_sent = pairs_sent * 2;

    // Report send phase
    try helpers.print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try helpers.print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try helpers.print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    if (send_errors > 0) {
        try helpers.print(stderr, "Send errors:     {d}\n", .{send_errors});
    }
    try helpers.printTime(stderr, "Send time:       ", send_time);
    if (send_time > 0) {
        const send_rate: u64 = orders_sent * config.NS_PER_SEC / send_time;
        try helpers.printThroughput(stderr, "Send rate:       ", send_rate);
    }
    try helpers.print(stderr, "Trades so far:   {d}\n", .{running_stats.trades});

    // Final drain - keep going until all trades received or stalled
    try helpers.print(stderr, "\nDraining remaining responses...\n", .{});
    const remaining = pairs_sent - running_stats.trades;
    try helpers.print(stderr, "  [sent {d} pairs, have {d} trades, need {d} more]\n", .{
        pairs_sent,
        running_stats.trades,
        remaining,
    });

    // Use the stall-based drain - wait up to 60 seconds of no progress
    try drain.drainUntilTrades(client, &running_stats, pairs_sent, FINAL_DRAIN_STALL_MS);

    // Report final status if still short
    if (running_stats.trades < pairs_sent) {
        try helpers.print(stderr, "  [final: {d}/{d} trades]\n", .{ running_stats.trades, pairs_sent });
    }

    // Final results
    const total_time = timestamp.now() - start_time;
    try helpers.print(stderr, "\n=== Scenario Results ===\n\n", .{});

    try helpers.print(stderr, "Orders:\n", .{});
    try helpers.print(stderr, "  Sent:              {d}\n", .{orders_sent});
    try helpers.print(stderr, "  Failed:            {d}\n", .{send_errors});
    try helpers.print(stderr, "  Responses:         {d}\n", .{running_stats.total()});
    try helpers.print(stderr, "  Trades:            {d}\n", .{running_stats.trades});
    try helpers.print(stderr, "\n", .{});

    try helpers.printTime(stderr, "Time:                ", total_time);
    try helpers.print(stderr, "\n", .{});

    try helpers.print(stderr, "Throughput:\n", .{});
    if (total_time > 0) {
        const orders_per_sec: u64 = orders_sent * config.NS_PER_SEC / total_time;
        try helpers.printThroughput(stderr, "  Orders/sec:        ", orders_per_sec);
    }

    // Validation
    try helpers.print(stderr, "\n", .{});
    if (running_stats.trades != pairs_sent) {
        try helpers.print(stderr, "⚠ WARNING: Expected {d} trades, got {d} ({d}.{d}%)\n\n", .{
            pairs_sent,
            running_stats.trades,
            (running_stats.trades * 100) / pairs_sent,
            ((running_stats.trades * 1000) / pairs_sent) % 10,
        });
    } else {
        try helpers.print(stderr, "✓ All {d} trades executed successfully!\n\n", .{pairs_sent});
    }

    // Achievement
    if (trades >= 100_000_000 and running_stats.trades >= pairs_sent) {
        try printLegendaryAchievement(stderr);
    }
}

// ============================================================
// Display Helpers
// ============================================================

fn printLegendaryHeader(stderr: std.fs.File, trades: u64, orders: u64) !void {
    try stderr.writeAll("\n");
    try stderr.writeAll("╔══════════════════════════════════════════════════════════╗\n");
    try stderr.writeAll("║  ★★★ LEGENDARY MATCHING STRESS TEST ★★★                  ║\n");
    try helpers.print(stderr, "║  {d}M TRADES ({d}M ORDERS)                              ║\n", .{ trades / 1_000_000, orders / 1_000_000 });
    try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
    try stderr.writeAll("\n");
}

fn printLegendaryAchievement(stderr: std.fs.File) !void {
    try stderr.writeAll("\n╔══════════════════════════════════════════════════════════╗\n");
    try stderr.writeAll("║  ★★★ LEGENDARY ACHIEVEMENT UNLOCKED ★★★                  ║\n");
    try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
}
