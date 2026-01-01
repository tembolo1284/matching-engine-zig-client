//! Matching Engine Test Scenarios
//!
//! Pre-built test scenarios for validating the matching engine client.
//! Supports both interactive testing and automated stress tests.
//!
//! HIGH-PERFORMANCE MODE: Uses non-blocking I/O with aggressive batching.
const std = @import("std");
const EngineClient = @import("client/engine_client.zig").EngineClient;
const Protocol = @import("client/engine_client.zig").Protocol;
const types = @import("protocol/types.zig");
const binary = @import("protocol/binary.zig");
const csv = @import("protocol/csv.zig");
const timestamp = @import("util/timestamp.zig");

const NS_PER_MS: u64 = 1_000_000;
const NS_PER_SEC: u64 = 1_000_000_000;

// ============================================================
// Global Configuration
// ============================================================

pub const ScenarioConfig = struct {
    quiet: bool = false,
};

var global_config = ScenarioConfig{};

pub fn setQuiet(q: bool) void {
    global_config.quiet = q;
}

// ============================================================
// Response Statistics
// ============================================================

const ResponseStats = struct {
    acks: u64 = 0,
    cancel_acks: u64 = 0,
    trades: u64 = 0,
    top_of_book: u64 = 0,
    rejects: u64 = 0,
    parse_errors: u64 = 0,
    packets_received: u64 = 0,

    pub fn total(self: ResponseStats) u64 {
        return self.acks + self.cancel_acks + self.trades + self.top_of_book + self.rejects;
    }

    pub fn add(self: *ResponseStats, other: ResponseStats) void {
        self.acks += other.acks;
        self.cancel_acks += other.cancel_acks;
        self.trades += other.trades;
        self.top_of_book += other.top_of_book;
        self.rejects += other.rejects;
        self.parse_errors += other.parse_errors;
        self.packets_received += other.packets_received;
    }

    pub fn printStats(self: ResponseStats, stderr: std.fs.File) !void {
        try print(stderr, "\n=== Server Response Summary ===\n", .{});
        try print(stderr, "ACKs:            {d}\n", .{self.acks});
        if (self.cancel_acks > 0) try print(stderr, "Cancel ACKs:     {d}\n", .{self.cancel_acks});
        if (self.trades > 0) try print(stderr, "Trades:          {d}\n", .{self.trades});
        try print(stderr, "Top of Book:     {d}\n", .{self.top_of_book});
        if (self.rejects > 0) try print(stderr, "Rejects:         {d}\n", .{self.rejects});
        if (self.parse_errors > 0) try print(stderr, "Parse errors:    {d}\n", .{self.parse_errors});
        try print(stderr, "Total messages:  {d}\n", .{self.total()});
    }

    pub fn printValidation(self: ResponseStats, expected_acks: u64, expected_trades: u64, stderr: std.fs.File) !void {
        try self.printStats(stderr);
        try print(stderr, "\n=== Validation ===\n", .{});

        if (self.acks >= expected_acks) {
            try print(stderr, "ACKs:            {d}/{d} ✓ PASS\n", .{ self.acks, expected_acks });
        } else {
            const pct = if (expected_acks > 0) (self.acks * 100) / expected_acks else 0;
            try print(stderr, "ACKs:            {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                self.acks, expected_acks, pct, expected_acks - self.acks,
            });
        }

        if (expected_trades > 0) {
            if (self.trades >= expected_trades) {
                try print(stderr, "Trades:          {d}/{d} ✓ PASS\n", .{ self.trades, expected_trades });
            } else {
                const pct = if (expected_trades > 0) (self.trades * 100) / expected_trades else 0;
                try print(stderr, "Trades:          {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                    self.trades, expected_trades, pct, expected_trades - self.trades,
                });
            }
        }

        const passed = (self.acks >= expected_acks) and (self.trades >= expected_trades or expected_trades == 0);
        if (passed and self.rejects == 0) {
            try print(stderr, "\n*** TEST PASSED ***\n", .{});
        } else if (self.rejects > 0) {
            try print(stderr, "\n*** TEST FAILED - {d} REJECTS ***\n", .{self.rejects});
        } else {
            try print(stderr, "\n*** TEST FAILED - MISSING RESPONSES ***\n", .{});
        }
    }
};

// ============================================================
// Public API
// ============================================================

pub fn run(client: *EngineClient, scenario: u8, stderr: std.fs.File) !void {
    switch (scenario) {
        1 => try runScenario1(client, stderr),
        2 => try runScenario2(client, stderr),
        3 => try runScenario3(client, stderr),
        10 => try runStressTest(client, stderr, 1_000),
        11 => try runStressTest(client, stderr, 10_000),
        12 => try runStressTest(client, stderr, 100_000),
        20 => try runMatchingStressFast(client, stderr, 1_000),
        21 => try runMatchingStressFast(client, stderr, 10_000),
        22 => try runMatchingStressFast(client, stderr, 100_000),
        23 => try runMatchingStressFast(client, stderr, 250_000),
        24 => try runMatchingStressFast(client, stderr, 500_000),
        25 => try runMatchingStressFast(client, stderr, 250_000_000),
        30 => try runDualProcessorStressFast(client, stderr, 500_000),
        31 => try runDualProcessorStressFast(client, stderr, 1_000_000),
        32 => try runDualProcessorStressFast(client, stderr, 100_000_000),
        else => {
            try printAvailableScenarios(stderr);
            return error.UnknownScenario;
        },
    }
}

pub fn printAvailableScenarios(stderr: std.fs.File) !void {
    try print(stderr, "Available scenarios:\n", .{});
    try print(stderr, "\nBasic: 1 (orders), 2 (trade), 3 (cancel)\n", .{});
    try print(stderr, "\nUnmatched: 10 (1K), 11 (10K), 12 (100K)\n", .{});
    try print(stderr, "\nMatching (single processor - IBM):\n", .{});
    try print(stderr, "  20 - 1K trades\n", .{});
    try print(stderr, "  21 - 10K trades\n", .{});
    try print(stderr, "  22 - 100K trades\n", .{});
    try print(stderr, "  23 - 250K trades\n", .{});
    try print(stderr, "  24 - 500K trades\n", .{});
    try print(stderr, "  25 - 250M trades ★★★ LEGENDARY ★★★\n", .{});
    try print(stderr, "\nDual-Processor (IBM + NVDA):\n", .{});
    try print(stderr, "  30 - 500K trades  (250K each)\n", .{});
    try print(stderr, "  31 - 1M trades    (500K each)\n", .{});
    try print(stderr, "  32 - 100M trades  (50M each)  ★★★ ULTIMATE ★★★\n", .{});
}

// ============================================================
// Basic Scenarios (Interactive, with send/recv logging)
// ============================================================

fn runScenario1(client: *EngineClient, stderr: std.fs.File) !void {
    try print(stderr, "=== Scenario 1: Simple Orders ===\n\n", .{});
    const start_time = timestamp.now();

    // Order 1: Buy
    try print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    // Order 2: Sell (different price, won't match)
    try print(stderr, "[SEND] N, IBM, 1, 2, 105, 50, S (New Order: SELL 50 IBM @ 105)\n", .{});
    try client.sendNewOrder(1, "IBM", 105, 50, .sell, 2);
    try recvAndPrintResponsesFast(client, stderr, 5);

    // Flush
    try print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try recvAndPrintResponsesFast(client, stderr, 10);

    const elapsed = timestamp.now() - start_time;
    try print(stderr, "\n", .{});
    try printTime(stderr, "Total time: ", elapsed);
}

fn runScenario2(client: *EngineClient, stderr: std.fs.File) !void {
    try print(stderr, "=== Scenario 2: Matching Trade ===\n\n", .{});
    const start_time = timestamp.now();

    // Order 1: Buy
    try print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    // Order 2: Sell at same price - should match!
    try print(stderr, "[SEND] N, IBM, 1, 2, 100, 50, S (New Order: SELL 50 IBM @ 100 - SHOULD MATCH)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .sell, 2);
    try recvAndPrintResponsesFast(client, stderr, 5);

    // Flush
    try print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try recvAndPrintResponsesFast(client, stderr, 10);

    const elapsed = timestamp.now() - start_time;
    try print(stderr, "\n", .{});
    try printTime(stderr, "Total time: ", elapsed);
}

fn runScenario3(client: *EngineClient, stderr: std.fs.File) !void {
    try print(stderr, "=== Scenario 3: Cancel Order ===\n\n", .{});
    const start_time = timestamp.now();

    // Order 1: Buy
    try print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    // Cancel order 1
    try print(stderr, "[SEND] C, IBM, 1, 1 (Cancel order 1)\n", .{});
    try client.sendCancel(1, "IBM", 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    // Flush
    try print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try recvAndPrintResponsesFast(client, stderr, 10);

    const elapsed = timestamp.now() - start_time;
    try print(stderr, "\n", .{});
    try printTime(stderr, "Total time: ", elapsed);
}

// ============================================================
// Unmatched Stress Test (single-threaded, simpler)
// ============================================================

fn runStressTest(client: *EngineClient, stderr: std.fs.File, count: u32) !void {
    const quiet = global_config.quiet;
    try print(stderr, "=== Unmatched Stress: {d} Orders ===\n\n", .{count});

    try client.sendFlush();
    std.Thread.sleep(200 * NS_PER_MS);
    _ = try drainResponsesFast(client, 500);

    const progress_interval = count / 10;
    var running_stats = ResponseStats{};

    const start_time = timestamp.now();

    for (0..count) |i| {
        const price: u32 = 100 + @as(u32, @intCast(i % 100));
        const order_id: u32 = @intCast(i + 1);
        try client.sendNewOrder(1, "IBM", price, 10, .buy, order_id);

        if (!quiet and progress_interval > 0 and i > 0 and i % progress_interval == 0) {
            const batch_stats = try drainBatchFast(client, 10);
            running_stats.add(batch_stats);
            const pct = (i * 100) / count;
            try print(stderr, "  {d}% ({d} orders sent, {d} responses)\n", .{ pct, i, running_stats.total() });
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;

    try print(stderr, "\n=== Send Complete ===\n", .{});
    try print(stderr, "Orders sent:     {d}\n", .{count});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const throughput: u64 = @as(u64, count) * NS_PER_SEC / total_time;
        try printThroughput(stderr, "Throughput:  ", throughput);
    }

    try print(stderr, "\nDraining responses...\n", .{});
    std.Thread.sleep(500 * NS_PER_MS);
    const final_stats = try drainResponsesFast(client, 30_000);
    running_stats.add(final_stats);

    try running_stats.printValidation(count, 0, stderr);

    try print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * NS_PER_MS);
}

// ============================================================
// High-Performance Matching Stress Test
// Uses balanced send/recv to prevent buffer overflow
// ============================================================

fn runMatchingStressFast(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const quiet = global_config.quiet;
    const orders = trades * 2;

    if (trades >= 100_000_000) {
        try stderr.writeAll("\n");
        try stderr.writeAll("╔══════════════════════════════════════════════════════════╗\n");
        try stderr.writeAll("║  ★★★ LEGENDARY MATCHING STRESS TEST ★★★                  ║\n");
        try print(stderr, "║  {d}M TRADES ({d}M ORDERS)                              ║\n", .{ trades / 1_000_000, orders / 1_000_000 });
        try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
        try stderr.writeAll("\n");
    } else {
        try print(stderr, "=== High-Performance Matching Stress: {d} Trades ===\n\n", .{trades});
    }

    if (trades >= 1_000_000) {
        try print(stderr, "Target: {d}M trades ({d}M orders)\n", .{ trades / 1_000_000, orders / 1_000_000 });
    } else if (trades >= 1_000) {
        try print(stderr, "Target: {d}K trades ({d}K orders)\n", .{ trades / 1_000, orders / 1_000 });
    } else {
        try print(stderr, "Target: {d} trades ({d} orders)\n", .{ trades, orders });
    }

    try client.sendFlush();
    std.Thread.sleep(200 * NS_PER_MS);
    _ = try drainResponsesFast(client, 500);

    // BALANCED MODE:
    // - Moderate batch size to prevent overwhelming server
    // - After sending batch, drain ALL expected responses before continuing
    // - Each pair generates: 2 ACKs + 1 Trade + 2 TOB = 5 messages
    const batch_size: u64 = 100; // Smaller batch for better flow control
    const responses_per_pair: u64 = 5;

    try print(stderr, "Balanced mode: {d} pairs/batch, drain before next batch\n", .{batch_size});

    const progress_pct: u64 = if (trades >= 1_000_000) 5 else 10;
    const progress_interval = trades / (100 / progress_pct);

    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;
    var running_stats = ResponseStats{};
    var last_progress: u64 = 0;

    const start_time = timestamp.now();

    const tcp_ptr = &(client.tcp_client orelse return error.NotConnected);
    const proto = client.getProtocol();

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

        // After each batch, drain responses with proper waiting
        if (pairs_sent % batch_size == 0) {
            const expected_responses = batch_size * responses_per_pair;
            var received: u64 = 0;
            var consecutive_empty: u32 = 0;
            const max_consecutive_empty: u32 = 20; // Allow some empty polls

            // Keep draining until we have all expected responses or give up
            while (received < expected_responses and consecutive_empty < max_consecutive_empty) {
                // Use small timeout (5ms) to wait for data
                const maybe_data = tcp_ptr.tryRecv(5) catch |err| {
                    if (err == error.WouldBlock or err == error.Timeout) {
                        consecutive_empty += 1;
                        continue;
                    }
                    break;
                };

                if (maybe_data) |raw_data| {
                    if (parseMessage(raw_data, proto)) |m| {
                        countMessage(&running_stats, m);
                        received += 1;
                        consecutive_empty = 0; // Reset on success
                    }
                } else {
                    consecutive_empty += 1;
                }
            }
        }

        // Progress reporting
        if (!quiet and progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / trades;
            const elapsed = (timestamp.now() - start_time) / 1_000_000;
            const rate: u64 = if (elapsed > 0) pairs_sent * 1000 / elapsed else 0;
            try print(stderr, "  {d}% | {d} pairs | {d} ms | {d} trades/sec | recv'd: {d} | errs: {d}\n", .{
                pct, pairs_sent, elapsed, rate, running_stats.total(), send_errors,
            });
        }
    }

    // Handle any remaining pairs (not a full batch)
    const remaining_pairs = pairs_sent % batch_size;
    if (remaining_pairs > 0) {
        const expected_responses = remaining_pairs * responses_per_pair;
        var received: u64 = 0;
        var consecutive_empty: u32 = 0;
        const max_consecutive_empty: u32 = 50;

        while (received < expected_responses and consecutive_empty < max_consecutive_empty) {
            const maybe_data = tcp_ptr.tryRecv(5) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                if (parseMessage(raw_data, proto)) |m| {
                    countMessage(&running_stats, m);
                    received += 1;
                    consecutive_empty = 0;
                }
            } else {
                consecutive_empty += 1;
            }
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;
    const orders_sent = pairs_sent * 2;

    try print(stderr, "\n=== Complete ===\n", .{});
    try print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    try print(stderr, "Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const trade_rate: u64 = pairs_sent * NS_PER_SEC / total_time;
        try print(stderr, "\n=== Throughput ===\n", .{});
        try printThroughput(stderr, "Trades/sec:  ", trade_rate);
    }

    // Final drain for any stragglers
    const expected_total = orders_sent + pairs_sent + orders_sent; // ACKs + Trades + TOB

    if (running_stats.total() < expected_total) {
        try print(stderr, "\nFinal drain (have {d}/{d})...\n", .{ running_stats.total(), expected_total });

        var consecutive_empty: u32 = 0;
        const max_consecutive_empty: u32 = 100;

        while (running_stats.total() < expected_total and consecutive_empty < max_consecutive_empty) {
            const maybe_data = tcp_ptr.tryRecv(10) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                if (parseMessage(raw_data, proto)) |m| {
                    countMessage(&running_stats, m);
                    consecutive_empty = 0;
                }
            } else {
                consecutive_empty += 1;
            }
        }
    }

    try running_stats.printValidation(orders_sent, pairs_sent, stderr);

    if (trades >= 100_000_000 and running_stats.trades >= pairs_sent) {
        try stderr.writeAll("\n╔══════════════════════════════════════════════════════════╗\n");
        try stderr.writeAll("║  ★★★ LEGENDARY ACHIEVEMENT UNLOCKED ★★★                  ║\n");
        try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
    }

    try print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * NS_PER_MS);
}

// ============================================================
// High-Performance Dual-Processor Stress Test
// ============================================================

fn runDualProcessorStressFast(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const quiet = global_config.quiet;
    const orders = trades * 2;
    const trades_per_proc = trades / 2;

    if (trades >= 10_000_000) {
        try stderr.writeAll("\n");
        try stderr.writeAll("╔══════════════════════════════════════════════════════════╗\n");
        try stderr.writeAll("║  ★★★ DUAL-PROCESSOR STRESS TEST ★★★                      ║\n");
        try print(stderr, "║  {d}M TRADES ({d}M ORDERS)                              ║\n", .{ trades / 1_000_000, orders / 1_000_000 });
        try print(stderr, "║  Processor 0 (A-M): IBM  - {d}M trades                   ║\n", .{trades_per_proc / 1_000_000});
        try print(stderr, "║  Processor 1 (N-Z): NVDA - {d}M trades                   ║\n", .{trades_per_proc / 1_000_000});
        try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
        try stderr.writeAll("\n");
    } else {
        try print(stderr, "=== High-Performance Dual-Processor Stress: {d} Trades ===\n\n", .{trades});
    }

    if (trades >= 1_000_000) {
        try print(stderr, "Target: {d}M trades ({d}M orders)\n", .{ trades / 1_000_000, orders / 1_000_000 });
    } else if (trades >= 1_000) {
        try print(stderr, "Target: {d}K trades ({d}K orders)\n", .{ trades / 1_000, orders / 1_000 });
    }
    try print(stderr, "  Processor 0 (A-M): IBM  - {d} trades\n", .{trades_per_proc});
    try print(stderr, "  Processor 1 (N-Z): NVDA - {d} trades\n", .{trades_per_proc});

    try client.sendFlush();
    std.Thread.sleep(200 * NS_PER_MS);
    _ = try drainResponsesFast(client, 500);

    // BALANCED MODE
    const batch_size: u64 = 100;
    const responses_per_pair: u64 = 5;

    try print(stderr, "Balanced mode: {d} pairs/batch, drain before next batch\n", .{batch_size});

    const progress_pct: u64 = if (trades >= 1_000_000) 5 else 10;
    const progress_interval = trades / (100 / progress_pct);

    const symbols = [_][]const u8{ "IBM", "NVDA" };

    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;
    var running_stats = ResponseStats{};
    var last_progress: u64 = 0;

    const start_time = timestamp.now();

    const tcp_ptr = &(client.tcp_client orelse return error.NotConnected);
    const proto = client.getProtocol();

    var i: u64 = 0;
    while (i < trades) : (i += 1) {
        const symbol = symbols[i % 2];
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
        const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

        client.sendNewOrder(1, symbol, price, 10, .buy, buy_oid) catch {
            send_errors += 1;
            continue;
        };
        client.sendNewOrder(1, symbol, price, 10, .sell, sell_oid) catch {
            send_errors += 1;
            continue;
        };
        pairs_sent += 1;

        // After each batch, drain responses with proper waiting
        if (pairs_sent % batch_size == 0) {
            const expected_responses = batch_size * responses_per_pair;
            var received: u64 = 0;
            var consecutive_empty: u32 = 0;
            const max_consecutive_empty: u32 = 20;

            while (received < expected_responses and consecutive_empty < max_consecutive_empty) {
                const maybe_data = tcp_ptr.tryRecv(5) catch |err| {
                    if (err == error.WouldBlock or err == error.Timeout) {
                        consecutive_empty += 1;
                        continue;
                    }
                    break;
                };

                if (maybe_data) |raw_data| {
                    if (parseMessage(raw_data, proto)) |m| {
                        countMessage(&running_stats, m);
                        received += 1;
                        consecutive_empty = 0;
                    }
                } else {
                    consecutive_empty += 1;
                }
            }
        }

        if (!quiet and progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / trades;
            const elapsed = (timestamp.now() - start_time) / 1_000_000;
            const rate: u64 = if (elapsed > 0) pairs_sent * 1000 / elapsed else 0;
            try print(stderr, "  {d}% | {d} pairs | {d} ms | {d} trades/sec | recv'd: {d} | errs: {d}\n", .{
                pct, pairs_sent, elapsed, rate, running_stats.total(), send_errors,
            });
        }
    }

    // Handle remaining pairs
    const remaining_pairs = pairs_sent % batch_size;
    if (remaining_pairs > 0) {
        const expected_responses = remaining_pairs * responses_per_pair;
        var received: u64 = 0;
        var consecutive_empty: u32 = 0;
        const max_consecutive_empty: u32 = 50;

        while (received < expected_responses and consecutive_empty < max_consecutive_empty) {
            const maybe_data = tcp_ptr.tryRecv(5) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                if (parseMessage(raw_data, proto)) |m| {
                    countMessage(&running_stats, m);
                    received += 1;
                    consecutive_empty = 0;
                }
            } else {
                consecutive_empty += 1;
            }
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;
    const orders_sent = pairs_sent * 2;

    try print(stderr, "\n=== Complete ===\n", .{});
    try print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    try print(stderr, "Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const trade_rate: u64 = pairs_sent * NS_PER_SEC / total_time;
        try print(stderr, "\n=== Throughput ===\n", .{});
        try printThroughput(stderr, "Trades/sec:  ", trade_rate);
    }

    // Final drain for stragglers
    const expected_total = orders_sent + pairs_sent + orders_sent;

    if (running_stats.total() < expected_total) {
        try print(stderr, "\nFinal drain (have {d}/{d})...\n", .{ running_stats.total(), expected_total });

        var consecutive_empty: u32 = 0;
        const max_consecutive_empty: u32 = 100;

        while (running_stats.total() < expected_total and consecutive_empty < max_consecutive_empty) {
            const maybe_data = tcp_ptr.tryRecv(10) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                if (parseMessage(raw_data, proto)) |m| {
                    countMessage(&running_stats, m);
                    consecutive_empty = 0;
                }
            } else {
                consecutive_empty += 1;
            }
        }
    }

    try running_stats.printValidation(orders_sent, pairs_sent, stderr);

    if (trades >= 10_000_000 and running_stats.trades >= pairs_sent) {
        try stderr.writeAll("\n╔══════════════════════════════════════════════════════════╗\n");
        try stderr.writeAll("║  ★★★ ULTIMATE DUAL-PROCESSOR ACHIEVEMENT ★★★             ║\n");
        try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
    }

    try print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * NS_PER_MS);
}

// ============================================================
// Helper Functions
// ============================================================

fn print(file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt, args);
    try file.writeAll(msg);
}

fn printTime(file: std.fs.File, prefix: []const u8, nanos: u64) !void {
    if (nanos >= NS_PER_SEC * 60) {
        const mins = nanos / (NS_PER_SEC * 60);
        const secs = (nanos % (NS_PER_SEC * 60)) / NS_PER_SEC;
        try print(file, "{s}{d}m {d}s\n", .{ prefix, mins, secs });
    } else if (nanos >= NS_PER_SEC) {
        const secs = nanos / NS_PER_SEC;
        const ms = (nanos % NS_PER_SEC) / NS_PER_MS;
        try print(file, "{s}{d}.{d:0>3} sec\n", .{ prefix, secs, ms });
    } else {
        const ms = nanos / NS_PER_MS;
        try print(file, "{s}{d} ms\n", .{ prefix, ms });
    }
}

fn printThroughput(file: std.fs.File, prefix: []const u8, per_sec: u64) !void {
    if (per_sec >= 1_000_000) {
        const millions = per_sec / 1_000_000;
        const thousands = (per_sec % 1_000_000) / 1_000;
        try print(file, "{s}{d}.{d:0>1}M/sec\n", .{ prefix, millions, thousands / 100 });
    } else if (per_sec >= 1_000) {
        const thousands = per_sec / 1_000;
        const hundreds = (per_sec % 1_000) / 100;
        try print(file, "{s}{d}.{d}K/sec\n", .{ prefix, thousands, hundreds });
    } else {
        try print(file, "{s}{d}/sec\n", .{ prefix, per_sec });
    }
}

// ============================================================
// Response Handling - Fast Non-Blocking Versions
// ============================================================

fn parseMessage(raw_data: []const u8, proto: Protocol) ?types.OutputMessage {
    if (proto == .binary) {
        return binary.decodeOutput(raw_data) catch null;
    } else {
        return csv.parseOutput(raw_data) catch null;
    }
}

fn countMessage(stats: *ResponseStats, msg: types.OutputMessage) void {
    switch (msg.msg_type) {
        .ack => stats.acks += 1,
        .cancel_ack => stats.cancel_acks += 1,
        .trade => stats.trades += 1,
        .top_of_book => stats.top_of_book += 1,
        .reject => stats.rejects += 1,
    }
}

/// Fast non-blocking batch drain with small timeout
fn drainBatchFast(client: *EngineClient, timeout_ms: u32) !ResponseStats {
    var stats = ResponseStats{};
    const proto = client.getProtocol();

    const tcp_ptr = &(client.tcp_client orelse return stats);

    const start_time = timestamp.now();
    const timeout_ns: u64 = @as(u64, timeout_ms) * NS_PER_MS;
    var consecutive_empty: u32 = 0;
    const max_consecutive_empty: u32 = 10;

    while (timestamp.now() - start_time < timeout_ns and consecutive_empty < max_consecutive_empty) {
        const maybe_data = tcp_ptr.tryRecv(2) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                consecutive_empty += 1;
                continue;
            }
            break;
        };

        if (maybe_data) |raw_data| {
            if (parseMessage(raw_data, proto)) |m| {
                countMessage(&stats, m);
                consecutive_empty = 0;
            }
        } else {
            consecutive_empty += 1;
        }
    }

    return stats;
}

/// Fast non-blocking response drain
fn drainResponsesFast(client: *EngineClient, timeout_ms: u32) !ResponseStats {
    var stats = ResponseStats{};

    std.Thread.sleep(20 * NS_PER_MS); // Brief pause to let responses arrive

    const start_time = timestamp.now();
    const timeout_ns: u64 = @as(u64, timeout_ms) * NS_PER_MS;
    var consecutive_empty: u32 = 0;
    const max_consecutive_empty: u32 = 20;

    while (timestamp.now() - start_time < timeout_ns and consecutive_empty < max_consecutive_empty) {
        if (client.tcp_client) |*tcp_client| {
            const maybe_data = tcp_client.tryRecv(5) catch |err| {
                if (err == error.Timeout or err == error.WouldBlock) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                consecutive_empty = 0;
                if (parseMessage(raw_data, client.getProtocol())) |m| {
                    countMessage(&stats, m);
                }
            } else {
                consecutive_empty += 1;
            }
        } else {
            break;
        }
    }

    return stats;
}

/// Fast recv and print for interactive scenarios
/// Uses short timeouts and stops after consecutive empty polls
fn recvAndPrintResponsesFast(client: *EngineClient, stderr: std.fs.File, max_responses: u32) !void {
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        var consecutive_empty: u32 = 0;
        const max_consecutive_empty: u32 = 5; // Stop after 5 empty polls (~25ms)

        while (response_count < max_responses and consecutive_empty < max_consecutive_empty) {
            const maybe_data = tcp_client.tryRecv(5) catch |err| {
                if (err == error.Timeout or err == error.WouldBlock) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                consecutive_empty = 0;
                try printRawResponse(raw_data, proto, stderr);
                response_count += 1;
            } else {
                consecutive_empty += 1;
            }
        }
    }
}

fn printRawResponse(raw_data: []const u8, proto: Protocol, stderr: std.fs.File) !void {
    if (proto == .binary) {
        if (binary.isBinaryProtocol(raw_data)) {
            const msg = binary.decodeOutput(raw_data) catch |err| {
                try print(stderr, "[Parse error: {s}]\n", .{@errorName(err)});
                return;
            };
            try printResponse(msg, stderr);
        } else {
            try print(stderr, "[RECV] {s}\n", .{raw_data});
        }
    } else {
        const msg = csv.parseOutput(raw_data) catch {
            try print(stderr, "[RECV] {s}", .{raw_data});
            if (raw_data.len > 0 and raw_data[raw_data.len - 1] != '\n') {
                try stderr.writeAll("\n");
            }
            return;
        };
        try printResponse(msg, stderr);
    }
}

fn printResponse(msg: types.OutputMessage, stderr: std.fs.File) !void {
    const symbol = msg.symbol[0..msg.symbol_len];

    switch (msg.msg_type) {
        .ack => try print(stderr, "[RECV] A, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id }),
        .cancel_ack => try print(stderr, "[RECV] C, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id }),
        .trade => try print(stderr, "[RECV] T, {s}, {d}, {d}, {d}, {d}, {d}.{d:0>2}, {d}\n", .{
            symbol, msg.buy_user_id, msg.buy_order_id, msg.sell_user_id, msg.sell_order_id,
            msg.price / 100, msg.price % 100, msg.quantity,
        }),
        .reject => try print(stderr, "[RECV] R, {s}, {d}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id, msg.reject_reason }),
        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| @intFromEnum(s) else '-';
            if (msg.price == 0 and msg.quantity == 0) {
                try print(stderr, "[RECV] B, {s}, {c}, -, -\n", .{ symbol, side_char });
            } else {
                try print(stderr, "[RECV] B, {s}, {c}, {d}, {d}\n", .{ symbol, side_char, msg.price, msg.quantity });
            }
        },
    }
}

// ============================================================
// Tests
// ============================================================

test "ResponseStats add" {
    var a = ResponseStats{ .acks = 10, .trades = 5 };
    const b = ResponseStats{ .acks = 20, .trades = 10 };
    a.add(b);
    try std.testing.expectEqual(@as(u64, 30), a.acks);
    try std.testing.expectEqual(@as(u64, 15), a.trades);
}

test "ResponseStats total" {
    const stats = ResponseStats{ .acks = 100, .trades = 50, .top_of_book = 100 };
    try std.testing.expectEqual(@as(u64, 250), stats.total());
}
