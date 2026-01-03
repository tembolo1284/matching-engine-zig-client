//! Matching Engine Test Scenarios
//!
//! Pre-built test scenarios for validating the matching engine client.
//! Supports both interactive testing and automated stress tests.
//!
//! HIGH-PERFORMANCE MODE: Uses aggressive pipelining for maximum throughput.
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
        20 => try runMatchingStressPipelined(client, stderr, 1_000),
        21 => try runMatchingStressPipelined(client, stderr, 10_000),
        22 => try runMatchingStressPipelined(client, stderr, 100_000),
        23 => try runMatchingStressPipelined(client, stderr, 250_000),
        24 => try runMatchingStressPipelined(client, stderr, 500_000),
        25 => try runMatchingStressPipelined(client, stderr, 250_000_000),
        30 => try runDualProcessorStressPipelined(client, stderr, 500_000),
        31 => try runDualProcessorStressPipelined(client, stderr, 1_000_000),
        32 => try runDualProcessorStressPipelined(client, stderr, 100_000_000),
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

    try print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    try print(stderr, "[SEND] N, IBM, 1, 2, 105, 50, S (New Order: SELL 50 IBM @ 105)\n", .{});
    try client.sendNewOrder(1, "IBM", 105, 50, .sell, 2);
    try recvAndPrintResponsesFast(client, stderr, 5);

    try print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try recvAndPrintResponsesFast(client, stderr, 20);

    const elapsed = timestamp.now() - start_time;
    try print(stderr, "\n", .{});
    try printTime(stderr, "Total time: ", elapsed);
}

fn runScenario2(client: *EngineClient, stderr: std.fs.File) !void {
    try print(stderr, "=== Scenario 2: Matching Trade ===\n\n", .{});
    const start_time = timestamp.now();

    try print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    try print(stderr, "[SEND] N, IBM, 1, 2, 100, 50, S (New Order: SELL 50 IBM @ 100 - SHOULD MATCH)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .sell, 2);
    try recvAndPrintResponsesFast(client, stderr, 5);

    try print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try recvAndPrintResponsesFast(client, stderr, 20);

    const elapsed = timestamp.now() - start_time;
    try print(stderr, "\n", .{});
    try printTime(stderr, "Total time: ", elapsed);
}

fn runScenario3(client: *EngineClient, stderr: std.fs.File) !void {
    try print(stderr, "=== Scenario 3: Cancel Order ===\n\n", .{});
    const start_time = timestamp.now();

    try print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    try print(stderr, "[SEND] C, IBM, 1, 1 (Cancel order 1)\n", .{});
    try client.sendCancel(1, "IBM", 1);
    try recvAndPrintResponsesFast(client, stderr, 5);

    try print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try recvAndPrintResponsesFast(client, stderr, 20);

    const elapsed = timestamp.now() - start_time;
    try print(stderr, "\n", .{});
    try printTime(stderr, "Total time: ", elapsed);
}

// ============================================================
// Unmatched Stress Test
// ============================================================

fn runStressTest(client: *EngineClient, stderr: std.fs.File, count: u32) !void {
    const quiet = global_config.quiet;
    try print(stderr, "=== Unmatched Stress: {d} Orders ===\n\n", .{count});

    try client.sendFlush();
    std.Thread.sleep(200 * NS_PER_MS);
    _ = try drainAllAvailable(client);

    var running_stats = ResponseStats{};
    const progress_interval = count / 4; // Only 25%, 50%, 75%, 100%

    const start_time = timestamp.now();

    for (0..count) |i| {
        const price: u32 = 100 + @as(u32, @intCast(i % 100));
        const order_id: u32 = @intCast(i + 1);
        try client.sendNewOrder(1, "IBM", price, 10, .buy, order_id);

        // Quick drain every 1000 orders (don't wait, just grab what's ready)
        if (i > 0 and i % 1000 == 0) {
            const batch_stats = try drainAllAvailable(client);
            running_stats.add(batch_stats);
        }

        // Progress at 25%, 50%, 75%
        if (!quiet and progress_interval > 0 and i > 0 and i % progress_interval == 0) {
            const pct = (i * 100) / count;
            const elapsed_ms = (timestamp.now() - start_time) / NS_PER_MS;
            try print(stderr, "  {d}% | {d} sent | {d} recv'd | {d} ms\n", .{
                pct, i, running_stats.total(), elapsed_ms,
            });
        }
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;

    try print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try print(stderr, "Orders sent:     {d}\n", .{count});
    try printTime(stderr, "Send time:       ", send_time);
    if (send_time > 0) {
        const send_rate: u64 = @as(u64, count) * NS_PER_SEC / send_time;
        try printThroughput(stderr, "Send rate:       ", send_rate);
    }

    // Final drain - be patient
    try print(stderr, "\nDraining responses...\n", .{});
    const final_stats = try drainWithPatience(client, count * 2, 5000); // Expect ~2 msgs per order
    running_stats.add(final_stats);

    const total_time = timestamp.now() - start_time;
    try print(stderr, "\n=== Total Time ===\n", .{});
    try printTime(stderr, "Total:           ", total_time);

    try running_stats.printValidation(count, 0, stderr);

    try print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * NS_PER_MS);
}

// ============================================================
// PIPELINED Matching Stress Test
// Send as fast as possible, drain opportunistically, final drain at end
// ============================================================

fn runMatchingStressPipelined(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const orders = trades * 2;

    if (trades >= 100_000_000) {
        try stderr.writeAll("\n");
        try stderr.writeAll("╔══════════════════════════════════════════════════════════╗\n");
        try stderr.writeAll("║  ★★★ LEGENDARY MATCHING STRESS TEST ★★★                  ║\n");
        try print(stderr, "║  {d}M TRADES ({d}M ORDERS)                              ║\n", .{ trades / 1_000_000, orders / 1_000_000 });
        try stderr.writeAll("╚══════════════════════════════════════════════════════════╝\n");
        try stderr.writeAll("\n");
    } else {
        try print(stderr, "=== Pipelined Matching Stress: {d} Trades ===\n\n", .{trades});
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
    _ = try drainAllAvailable(client);

    // PIPELINED MODE:
    // - Send in large batches (1000 pairs)
    // - After each batch, do ONE quick non-blocking drain (don't wait!)
    // - At the end, do patient drain to collect all responses
    const batch_size: u64 = 1000;

    try print(stderr, "Pipelined mode: {d} pairs/batch, non-blocking drain\n\n", .{batch_size});

    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;
    var running_stats = ResponseStats{};

    const progress_points = [_]u64{ 25, 50, 75 };
    var next_progress_idx: usize = 0;

    const start_time = timestamp.now();

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

        // After each batch, do ONE quick drain (non-blocking)
        if (pairs_sent % batch_size == 0) {
            const batch_stats = try drainAllAvailable(client);
            running_stats.add(batch_stats);
        }

        // Progress at 25%, 50%, 75%
        if (next_progress_idx < progress_points.len) {
            const target_pct = progress_points[next_progress_idx];
            const current_pct = (i * 100) / trades;
            if (current_pct >= target_pct) {
                const elapsed_ms = (timestamp.now() - start_time) / NS_PER_MS;
                const rate: u64 = if (elapsed_ms > 0) pairs_sent * 1000 / elapsed_ms else 0;
                try print(stderr, "  {d}% | {d} pairs sent | {d} recv'd | {d} trades/sec\n", .{
                    target_pct, pairs_sent, running_stats.total(), rate,
                });
                next_progress_idx += 1;
            }
        }
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;
    const orders_sent = pairs_sent * 2;

    try print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    try print(stderr, "Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Send time:       ", send_time);

    if (send_time > 0) {
        const send_rate: u64 = pairs_sent * NS_PER_SEC / send_time;
        try printThroughput(stderr, "Send rate:       ", send_rate);
    }

    // Final drain - be VERY patient
    const expected_total = orders_sent + pairs_sent + orders_sent; // ACKs + Trades + TOB
    const already_received = running_stats.total();

    try print(stderr, "\n=== Drain Phase ===\n", .{});
    try print(stderr, "Already recv'd:  {d}\n", .{already_received});
    try print(stderr, "Expected total:  {d}\n", .{expected_total});
    try print(stderr, "Remaining:       {d}\n", .{expected_total - already_received});

    const drain_start = timestamp.now();
    const final_stats = try drainWithPatience(client, expected_total - already_received, 10000);
    running_stats.add(final_stats);
    const drain_time = timestamp.now() - drain_start;

    try print(stderr, "Drain recv'd:    {d}\n", .{final_stats.total()});
    try printTime(stderr, "Drain time:      ", drain_time);

    const total_time = timestamp.now() - start_time;

    try print(stderr, "\n=== Final Results ===\n", .{});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const trade_rate: u64 = pairs_sent * NS_PER_SEC / total_time;
        try printThroughput(stderr, "Trades/sec:      ", trade_rate);
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
// PIPELINED Dual-Processor Stress Test
// ============================================================

fn runDualProcessorStressPipelined(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
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
        try print(stderr, "=== Pipelined Dual-Processor Stress: {d} Trades ===\n\n", .{trades});
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
    _ = try drainAllAvailable(client);

    const batch_size: u64 = 1000;
    const symbols = [_][]const u8{ "IBM", "NVDA" };

    try print(stderr, "Pipelined mode: {d} pairs/batch, non-blocking drain\n\n", .{batch_size});

    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;
    var running_stats = ResponseStats{};

    const progress_points = [_]u64{ 25, 50, 75 };
    var next_progress_idx: usize = 0;

    const start_time = timestamp.now();

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

        if (pairs_sent % batch_size == 0) {
            const batch_stats = try drainAllAvailable(client);
            running_stats.add(batch_stats);
        }

        if (next_progress_idx < progress_points.len) {
            const target_pct = progress_points[next_progress_idx];
            const current_pct = (i * 100) / trades;
            if (current_pct >= target_pct) {
                const elapsed_ms = (timestamp.now() - start_time) / NS_PER_MS;
                const rate: u64 = if (elapsed_ms > 0) pairs_sent * 1000 / elapsed_ms else 0;
                try print(stderr, "  {d}% | {d} pairs sent | {d} recv'd | {d} trades/sec\n", .{
                    target_pct, pairs_sent, running_stats.total(), rate,
                });
                next_progress_idx += 1;
            }
        }
    }

    const send_end_time = timestamp.now();
    const send_time = send_end_time - start_time;
    const orders_sent = pairs_sent * 2;

    try print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    try print(stderr, "Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Send time:       ", send_time);

    if (send_time > 0) {
        const send_rate: u64 = pairs_sent * NS_PER_SEC / send_time;
        try printThroughput(stderr, "Send rate:       ", send_rate);
    }

    const expected_total = orders_sent + pairs_sent + orders_sent;
    const already_received = running_stats.total();

    try print(stderr, "\n=== Drain Phase ===\n", .{});
    try print(stderr, "Already recv'd:  {d}\n", .{already_received});
    try print(stderr, "Expected total:  {d}\n", .{expected_total});
    try print(stderr, "Remaining:       {d}\n", .{expected_total - already_received});

    const drain_start = timestamp.now();
    const final_stats = try drainWithPatience(client, expected_total - already_received, 10000);
    running_stats.add(final_stats);
    const drain_time = timestamp.now() - drain_start;

    try print(stderr, "Drain recv'd:    {d}\n", .{final_stats.total()});
    try printTime(stderr, "Drain time:      ", drain_time);

    const total_time = timestamp.now() - start_time;

    try print(stderr, "\n=== Final Results ===\n", .{});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const trade_rate: u64 = pairs_sent * NS_PER_SEC / total_time;
        try printThroughput(stderr, "Trades/sec:      ", trade_rate);
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
// Response Handling
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

/// Drain ALL immediately available responses (non-blocking)
/// Returns as soon as there's nothing ready - doesn't wait
fn drainAllAvailable(client: *EngineClient) !ResponseStats {
    var stats = ResponseStats{};
    const proto = client.getProtocol();

    const tcp_ptr = &(client.tcp_client orelse return stats);

    // Keep draining until we get nothing back
    var drain_count: u32 = 0;
    const max_drain: u32 = 10000; // Safety limit

    while (drain_count < max_drain) : (drain_count += 1) {
        // poll(0) = immediate return if no data
        const maybe_data = tcp_ptr.tryRecv(0) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                break; // No data available, we're done
            }
            return err;
        };

        if (maybe_data) |raw_data| {
            if (parseMessage(raw_data, proto)) |m| {
                countMessage(&stats, m);
            }
        } else {
            break; // No data available
        }
    }

    return stats;
}

/// Drain with patience - wait for expected_count messages or timeout
fn drainWithPatience(client: *EngineClient, expected_count: u64, timeout_ms: u64) !ResponseStats {
    var stats = ResponseStats{};
    const proto = client.getProtocol();

    const tcp_ptr = &(client.tcp_client orelse return stats);

    const start_time = timestamp.now();
    const timeout_ns = timeout_ms * NS_PER_MS;

    var consecutive_empty: u32 = 0;
    const max_consecutive_empty: u32 = 500; // Very patient

    while (stats.total() < expected_count) {
        // Check timeout
        if (timestamp.now() - start_time > timeout_ns) {
            break;
        }

        // Check consecutive empties
        if (consecutive_empty >= max_consecutive_empty) {
            break;
        }

        // Use 10ms timeout to balance responsiveness vs CPU
        const maybe_data = tcp_ptr.tryRecv(10) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                consecutive_empty += 1;
                continue;
            }
            return err;
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

/// Fast recv and print for interactive scenarios
fn recvAndPrintResponsesFast(client: *EngineClient, stderr: std.fs.File, max_responses: u32) !void {
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        var consecutive_empty: u32 = 0;
        const max_consecutive_empty: u32 = 10;

        while (response_count < max_responses and consecutive_empty < max_consecutive_empty) {
            const maybe_data = tcp_client.tryRecv(10) catch |err| {
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
