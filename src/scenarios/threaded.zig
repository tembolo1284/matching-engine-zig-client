//! Threaded Matching Scenarios with Buffered Interleaved I/O
//!
//! Uses BUFFERED sends with INTERLEAVED drain to prevent server overflow.
//! This is the optimal approach for high-throughput without overwhelming the server.
//!
//! Strategy:
//!   1. Send batch of N order pairs (buffered → single syscall)
//!   2. Drain responses until we've received ~80% of expected
//!   3. Repeat

const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const helpers = @import("helpers.zig");
const drain = @import("drain.zig");

const EngineClient = @import("../client/engine_client.zig").EngineClient;
const Protocol = @import("../client/engine_client.zig").Protocol;
const TcpClient = @import("../transport/tcp.zig").TcpClient;
const timestamp = @import("../util/timestamp.zig");
const binary = @import("../protocol/binary.zig");
const proto_types = @import("../protocol/types.zig");

// ============================================================
// Configuration - Tune these for performance
// ============================================================

/// Number of order pairs per batch before draining
const BATCH_SIZE: u64 = 50;

/// Target drain percentage before sending next batch
const DRAIN_TARGET_PCT: f64 = 0.8;

/// Maximum empty polls before giving up on drain
const DRAIN_MAX_EMPTY: u32 = 100;

/// Poll timeout per drain attempt (ms)
const DRAIN_POLL_MS: i32 = 5;

// ============================================================
// Main Entry Point - Buffered Interleaved
// ============================================================

pub fn runThreadedMatchingStress(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const orders = trades * 2;
    const expected_msgs_per_pair: u64 = 5; // 2 ACK + 1 Trade + 2 TOB
    const total_expected_msgs = trades * expected_msgs_per_pair;

    // Header
    try helpers.print(stderr, "=== BUFFERED INTERLEAVED Matching Stress: {d} Trades ===\n\n", .{trades});
    try printTarget(stderr, trades, orders);
    try helpers.print(stderr, "Mode: Buffered send + interleaved drain\n", .{});
    try helpers.print(stderr, "Batch size: {d} pairs\n", .{BATCH_SIZE});
    try helpers.print(stderr, "Drain target: {d}%\n\n", .{@as(u64, @intFromFloat(DRAIN_TARGET_PCT * 100))});

    // Initial flush to clear server state
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);

    // Drain any stale data
    _ = drain.drainAllAvailable(client) catch {};

    // Get TCP client and protocol for direct drain calls
    const tcp_ptr = &(client.tcp_client orelse return error.NotConnected);
    const proto = client.getProtocol();

    // Stats tracking
    var stats = types.ResponseStats{};
    var pairs_sent: u64 = 0;
    var batches_sent: u64 = 0;

    const start_time = timestamp.now();
    const progress_interval = @max(trades / 20, 1); // Report every 5%
    var last_progress: u64 = 0;

    // Main loop: send batch, drain, repeat
    while (pairs_sent < trades) {
        // Calculate this batch size (may be smaller for last batch)
        const remaining = trades - pairs_sent;
        const this_batch = @min(BATCH_SIZE, remaining);

        // === SEND PHASE: Buffered batch ===
        for (0..this_batch) |j| {
            const i = pairs_sent + j;
            const price: u32 = 100 + @as(u32, @intCast(i % 50));
            const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
            const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

            // Queue buy order (no syscall)
            client.sendNewOrderBuffered(1, "IBM", price, 10, .buy, buy_oid) catch continue;

            // Queue sell order (no syscall)
            client.sendNewOrderBuffered(1, "IBM", price, 10, .sell, sell_oid) catch continue;
        }

        // Flush the batch (single syscall for all orders)
        client.flush() catch {
            try helpers.print(stderr, "ERROR: Flush failed at batch {d}\n", .{batches_sent});
            return error.FlushFailed;
        };

        pairs_sent += this_batch;
        batches_sent += 1;

        // === DRAIN PHASE: Wait for responses ===
        const expected_so_far = pairs_sent * expected_msgs_per_pair;
        const drain_target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(expected_so_far)) * DRAIN_TARGET_PCT));
        const need_to_drain = if (drain_target > stats.total()) drain_target - stats.total() else 0;

        if (need_to_drain > 0) {
            const batch_stats = drain.drainBatch(
                tcp_ptr,
                proto,
                need_to_drain,
                DRAIN_MAX_EMPTY,
                DRAIN_POLL_MS,
            ) catch types.ResponseStats{};
            stats.add(batch_stats);
        }

        // Progress reporting
        if (pairs_sent >= last_progress + progress_interval) {
            const elapsed_ms = (timestamp.now() - start_time) / config.NS_PER_MS;
            const rate = if (elapsed_ms > 0) pairs_sent * 1000 / elapsed_ms else 0;
            const pct = (pairs_sent * 100) / trades;
            const recv_pct = (stats.total() * 100) / total_expected_msgs;

            try helpers.print(stderr, "  {d}% sent | {d}% recv | {d} trades/sec\n", .{
                pct, recv_pct, rate,
            });
            last_progress = pairs_sent;
        }
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;

    // Report send phase
    try helpers.print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try helpers.print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try helpers.print(stderr, "Orders sent:     {d}\n", .{pairs_sent * 2});
    try helpers.print(stderr, "Batches:         {d}\n", .{batches_sent});
    try helpers.print(stderr, "Avg batch size:  {d:.1}\n", .{
        @as(f64, @floatFromInt(pairs_sent)) / @as(f64, @floatFromInt(batches_sent)),
    });
    try helpers.printTime(stderr, "Send time:       ", send_time);
    if (send_time > 0) {
        const send_rate = pairs_sent * config.NS_PER_SEC / send_time;
        try helpers.printThroughput(stderr, "Send rate:       ", send_rate);
    }

    // Final drain - get any remaining responses
    try helpers.print(stderr, "\n=== Final Drain ===\n", .{});
    try helpers.print(stderr, "Already recv'd:  {d}\n", .{stats.total()});
    try helpers.print(stderr, "Expected total:  {d}\n", .{total_expected_msgs});

    const final_drain_start = timestamp.now();
    const remaining_expected = if (total_expected_msgs > stats.total()) 
        total_expected_msgs - stats.total() 
    else 
        0;
    
    const final_stats = drain.drainWithPatience(
        client,
        remaining_expected,
        10000, // 10 second timeout for final drain
    ) catch types.ResponseStats{};
    stats.add(final_stats);

    const final_drain_time = timestamp.now() - final_drain_start;
    try helpers.print(stderr, "Drain recv'd:    {d}\n", .{final_stats.total()});
    try helpers.printTime(stderr, "Drain time:      ", final_drain_time);

    const total_time = timestamp.now() - start_time;

    // Final results
    try helpers.print(stderr, "\n=== Final Results ===\n", .{});
    try helpers.printTime(stderr, "Total time:      ", total_time);
    if (total_time > 0) {
        const trade_rate = pairs_sent * config.NS_PER_SEC / total_time;
        try helpers.printThroughput(stderr, "Trades/sec:      ", trade_rate);
    }

    try helpers.print(stderr, "\n=== Server Response Summary ===\n", .{});
    try helpers.print(stderr, "ACKs:            {d}\n", .{stats.acks});
    try helpers.print(stderr, "Trades:          {d}\n", .{stats.trades});
    try helpers.print(stderr, "Top of Book:     {d}\n", .{stats.top_of_book});
    try helpers.print(stderr, "Total messages:  {d}\n", .{stats.total()});

    try stats.printValidation(pairs_sent * 2, pairs_sent, stderr);

    // Cleanup
    try helpers.print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * config.NS_PER_MS);

    // Drain any late arrivals
    const late = drain.drainAllAvailable(client) catch types.ResponseStats{};
    if (late.total() > 0) {
        try helpers.print(stderr, "Late arrivals:   {d}\n", .{late.total()});
    }
}

// ============================================================
// Dual-Processor Version
// ============================================================

pub fn runThreadedDualProcessorStress(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const orders = trades * 2;
    const expected_msgs_per_pair: u64 = 5;
    const total_expected_msgs = trades * expected_msgs_per_pair;

    try helpers.print(stderr, "=== DUAL-PROCESSOR BUFFERED INTERLEAVED: {d} Trades ===\n\n", .{trades});
    try printTarget(stderr, trades, orders);
    try helpers.print(stderr, "Mode: Dual-processor (IBM + TSLA) + buffered interleaved\n", .{});
    try helpers.print(stderr, "Batch size: {d} pairs\n\n", .{BATCH_SIZE});

    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);
    _ = drain.drainAllAvailable(client) catch {};

    const tcp_ptr = &(client.tcp_client orelse return error.NotConnected);
    const proto = client.getProtocol();

    var stats = types.ResponseStats{};
    var pairs_sent: u64 = 0;
    var batches_sent: u64 = 0;

    const symbols = [_][]const u8{ "IBM", "TSLA" };
    const start_time = timestamp.now();
    const progress_interval = @max(trades / 20, 1);
    var last_progress: u64 = 0;

    while (pairs_sent < trades) {
        const remaining = trades - pairs_sent;
        const this_batch = @min(BATCH_SIZE, remaining);

        // Send batch (alternating symbols)
        for (0..this_batch) |j| {
            const i = pairs_sent + j;
            const symbol = symbols[i % 2];
            const price: u32 = 100 + @as(u32, @intCast(i % 50));
            const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
            const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

            client.sendNewOrderBuffered(1, symbol, price, 10, .buy, buy_oid) catch continue;
            client.sendNewOrderBuffered(1, symbol, price, 10, .sell, sell_oid) catch continue;
        }

        client.flush() catch return error.FlushFailed;
        pairs_sent += this_batch;
        batches_sent += 1;

        // Drain phase
        const expected_so_far = pairs_sent * expected_msgs_per_pair;
        const drain_target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(expected_so_far)) * DRAIN_TARGET_PCT));
        const need_to_drain = if (drain_target > stats.total()) drain_target - stats.total() else 0;

        if (need_to_drain > 0) {
            const batch_stats = drain.drainBatch(tcp_ptr, proto, need_to_drain, DRAIN_MAX_EMPTY, DRAIN_POLL_MS) catch types.ResponseStats{};
            stats.add(batch_stats);
        }

        // Progress
        if (pairs_sent >= last_progress + progress_interval) {
            const elapsed_ms = (timestamp.now() - start_time) / config.NS_PER_MS;
            const rate = if (elapsed_ms > 0) pairs_sent * 1000 / elapsed_ms else 0;
            const pct = (pairs_sent * 100) / trades;
            try helpers.print(stderr, "  {d}% | {d} trades/sec\n", .{ pct, rate });
            last_progress = pairs_sent;
        }
    }

    const send_time = timestamp.now() - start_time;

    try helpers.print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try helpers.print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try helpers.print(stderr, "Batches:         {d}\n", .{batches_sent});
    try helpers.printTime(stderr, "Send time:       ", send_time);

    // Final drain
    try helpers.print(stderr, "\n=== Final Drain ===\n", .{});
    const remaining_expected = if (total_expected_msgs > stats.total()) total_expected_msgs - stats.total() else 0;
    const final_stats = drain.drainWithPatience(client, remaining_expected, 10000) catch types.ResponseStats{};
    stats.add(final_stats);

    const total_time = timestamp.now() - start_time;

    try helpers.print(stderr, "\n=== Final Results ===\n", .{});
    try helpers.printTime(stderr, "Total time:      ", total_time);
    if (total_time > 0) {
        const trade_rate = pairs_sent * config.NS_PER_SEC / total_time;
        try helpers.printThroughput(stderr, "Trades/sec:      ", trade_rate);
    }

    try stats.printValidation(pairs_sent * 2, pairs_sent, stderr);

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
