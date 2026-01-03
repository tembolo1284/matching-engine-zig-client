//! Matching Stress Scenarios (20-25)
//!
//! Send buy/sell pairs at the same price to generate trades.
//! Single processor (IBM symbol routes to processor 0).

const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const helpers = @import("helpers.zig");
const drain = @import("drain.zig");

const EngineClient = @import("../client/engine_client.zig").EngineClient;
const timestamp = @import("../util/timestamp.zig");

// ============================================================
// Matching Stress Test (Single Processor)
// ============================================================

pub fn runMatchingStress(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const orders = trades * 2;

    // Header
    if (trades >= 100_000_000) {
        try printLegendaryHeader(stderr, trades, orders);
    } else {
        try helpers.print(stderr, "=== Matching Stress: {d} Trades ===\n\n", .{trades});
    }

    // Target info
    try printTarget(stderr, trades, orders);

    // Initial flush
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);
    _ = try drain.drainAllAvailable(client);

    const batch_size = config.MATCHING_BATCH_SIZE;
    try helpers.print(stderr, "Batch mode: {d} pairs/batch, balanced drain\n\n", .{batch_size});

    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;
    var running_stats = types.ResponseStats{};

    const progress_points = [_]u64{ 25, 50, 75 };
    var next_progress_idx: usize = 0;

    const start_time = timestamp.now();

    const tcp_ptr = &(client.tcp_client orelse return error.NotConnected);
    const proto = client.getProtocol();

    // Send phase with interleaved drain
    var i: u64 = 0;
    while (i < trades) : (i += 1) {
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
        const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

        client.sendNewOrder(1, "IBM", price, 10, .buy, buy_oid) catch {
            send_errors += 1;
            continue;
        };
        client.sendNewOrder(1, "IBM", price, 10, .sell, sell_oid) catch {
            send_errors += 1;
            continue;
        };
        pairs_sent += 1;

        // Drain after each batch
        if (pairs_sent % batch_size == 0) {
            const expected = batch_size * config.MSGS_PER_MATCHING_PAIR;
            const batch_stats = try drain.drainBatch(tcp_ptr, proto, expected, 50, 10);
            running_stats.add(batch_stats);
        }

        // Progress at 25%, 50%, 75%
        if (!config.quiet and next_progress_idx < progress_points.len) {
            const target_pct = progress_points[next_progress_idx];
            const current_pct = (i * 100) / trades;
            if (current_pct >= target_pct) {
                const elapsed_ms = (timestamp.now() - start_time) / config.NS_PER_MS;
                const rate: u64 = if (elapsed_ms > 0) pairs_sent * 1000 / elapsed_ms else 0;
                try helpers.print(stderr, "  {d}% | {d} pairs | {d} recv'd | {d} trades/sec\n", .{
                    target_pct, pairs_sent, running_stats.total(), rate,
                });
                next_progress_idx += 1;
            }
        }
    }

    // Handle remaining pairs
    const remaining = pairs_sent % batch_size;
    if (remaining > 0) {
        const expected = remaining * config.MSGS_PER_MATCHING_PAIR;
        const batch_stats = try drain.drainBatch(tcp_ptr, proto, expected, 100, 10);
        running_stats.add(batch_stats);
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;
    const orders_sent = pairs_sent * 2;

    // Report send phase
    try helpers.print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try helpers.print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try helpers.print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    try helpers.print(stderr, "Send errors:     {d}\n", .{send_errors});
    try helpers.printTime(stderr, "Send time:       ", send_time);
    if (send_time > 0) {
        const send_rate: u64 = pairs_sent * config.NS_PER_SEC / send_time;
        try helpers.printThroughput(stderr, "Send rate:       ", send_rate);
    }

    // Final drain
    const expected_total = orders_sent + pairs_sent + orders_sent; // ACKs + Trades + TOB
    const already_received = running_stats.total();

    if (already_received < expected_total) {
        try helpers.print(stderr, "\n=== Drain Phase ===\n", .{});
        try helpers.print(stderr, "Already recv'd:  {d}\n", .{already_received});
        try helpers.print(stderr, "Expected total:  {d}\n", .{expected_total});

        std.Thread.sleep(100 * config.NS_PER_MS);

        const drain_start = timestamp.now();
        const final_stats = try drain.drainWithPatience(client, expected_total - already_received, config.DEFAULT_DRAIN_TIMEOUT_MS);
        running_stats.add(final_stats);
        const drain_time = timestamp.now() - drain_start;

        try helpers.print(stderr, "Drain recv'd:    {d}\n", .{final_stats.total()});
        try helpers.printTime(stderr, "Drain time:      ", drain_time);
    }

    // Final results
    const total_time = timestamp.now() - start_time;

    try helpers.print(stderr, "\n=== Final Results ===\n", .{});
    try helpers.printTime(stderr, "Total time:      ", total_time);
    if (total_time > 0) {
        const trade_rate: u64 = pairs_sent * config.NS_PER_SEC / total_time;
        try helpers.printThroughput(stderr, "Trades/sec:      ", trade_rate);
    }

    try running_stats.printValidation(orders_sent, pairs_sent, stderr);

    // Achievement
    if (trades >= 100_000_000 and running_stats.trades >= pairs_sent) {
        try printLegendaryAchievement(stderr);
    }

    // Cleanup
    try helpers.print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * config.NS_PER_MS);
}

// ============================================================
// Display Helpers
// ============================================================

fn printTarget(stderr: std.fs.File, trades: u64, orders: u64) !void {
    if (trades >= 1_000_000) {
        try helpers.print(stderr, "Target: {d}M trades ({d}M orders)\n", .{ trades / 1_000_000, orders / 1_000_000 });
    } else if (trades >= 1_000) {
        try helpers.print(stderr, "Target: {d}K trades ({d}K orders)\n", .{ trades / 1_000, orders / 1_000 });
    } else {
        try helpers.print(stderr, "Target: {d} trades ({d} orders)\n", .{ trades, orders });
    }
}

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
