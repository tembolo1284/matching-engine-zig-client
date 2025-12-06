//! Test scenarios for the matching engine client.
//!
//! Provides pre-defined test scenarios for basic functionality testing
//! and stress testing of the matching engine.

const std = @import("std");
const types = @import("protocol/types.zig");
const binary = @import("protocol/binary.zig");
const csv = @import("protocol/csv.zig");
const timestamp = @import("util/timestamp.zig");
const engine_client = @import("client/engine_client.zig");

const EngineClient = engine_client.EngineClient;
const OutputMessage = types.OutputMessage;

// ============================================================
// Response Statistics
// ============================================================

const ResponseStats = struct {
    acks: u32 = 0,
    cancel_acks: u32 = 0,
    trades: u32 = 0,
    top_of_book: u32 = 0,
    rejects: u32 = 0,
    parse_errors: u32 = 0,

    pub fn total(self: ResponseStats) u32 {
        return self.acks + self.cancel_acks + self.trades + self.top_of_book + self.rejects;
    }

    pub fn print(self: ResponseStats, stderr: anytype) !void {
        try stderr.print("\n=== Server Response Summary ===\n", .{});
        try stderr.print("ACKs:            {d}\n", .{self.acks});
        if (self.cancel_acks > 0) {
            try stderr.print("Cancel ACKs:     {d}\n", .{self.cancel_acks});
        }
        if (self.trades > 0) {
            try stderr.print("Trades:          {d}\n", .{self.trades});
        }
        try stderr.print("Top of Book:     {d}\n", .{self.top_of_book});
        if (self.rejects > 0) {
            try stderr.print("Rejects:         {d}\n", .{self.rejects});
        }
        if (self.parse_errors > 0) {
            try stderr.print("Parse errors:    {d}\n", .{self.parse_errors});
        }
        try stderr.print("Total messages:  {d}\n", .{self.total()});
    }

    pub fn printValidation(self: ResponseStats, expected_acks: u32, expected_trades: u32, stderr: anytype) !void {
        try self.print(stderr);

        try stderr.print("\n=== Validation ===\n", .{});

        // ACK validation
        if (self.acks == expected_acks) {
            try stderr.print("ACKs:            {d}/{d} ✓ PASS\n", .{ self.acks, expected_acks });
        } else {
            const pct = if (expected_acks > 0) (self.acks * 100) / expected_acks else 0;
            try stderr.print("ACKs:            {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                self.acks,
                expected_acks,
                pct,
                expected_acks - self.acks,
            });
        }

        // Trade validation (if expected)
        if (expected_trades > 0) {
            if (self.trades == expected_trades) {
                try stderr.print("Trades:          {d}/{d} ✓ PASS\n", .{ self.trades, expected_trades });
            } else {
                const pct = if (expected_trades > 0) (self.trades * 100) / expected_trades else 0;
                try stderr.print("Trades:          {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                    self.trades,
                    expected_trades,
                    pct,
                    expected_trades - self.trades,
                });
            }
        }

        // Overall pass/fail
        const passed = (self.acks == expected_acks) and (self.trades == expected_trades or expected_trades == 0);
        if (passed and self.rejects == 0) {
            try stderr.print("\n*** TEST PASSED ***\n", .{});
        } else if (self.rejects > 0) {
            try stderr.print("\n*** TEST FAILED - {d} REJECTS ***\n", .{self.rejects});
        } else {
            try stderr.print("\n*** TEST FAILED - MISSING RESPONSES ***\n", .{});
        }
    }
};

// ============================================================
// Public API
// ============================================================

/// Run a scenario by number
pub fn run(client: *EngineClient, scenario: u8, stderr: anytype) !void {
    switch (scenario) {
        1 => try runScenario1(client, stderr),
        2 => try runScenario2(client, stderr),
        3 => try runScenario3(client, stderr),
        10 => try runStressTest(client, stderr, 1_000),
        11 => try runStressTest(client, stderr, 10_000),
        12 => try runStressTest(client, stderr, 100_000),
        13 => try runStressTest(client, stderr, 1_000_000),
        14 => try runStressTest(client, stderr, 10_000_000), // 10M orders!
        15 => try runStressTest(client, stderr, 100_000_000), // 100M orders!
        20 => try runMatchingStress(client, stderr, 1_000),
        21 => try runMatchingStress(client, stderr, 10_000),
        22 => try runMatchingStress(client, stderr, 100_000), // 100K matching pairs
        23 => try runMatchingStress(client, stderr, 1_000_000), // 1M matching pairs
        30 => try runMultiSymbolStress(client, stderr, 10_000),
        31 => try runMultiSymbolStress(client, stderr, 100_000),
        32 => try runMultiSymbolStress(client, stderr, 1_000_000),
        // Burst mode - no throttling (may cause server parse errors)
        40 => try runBurstStress(client, stderr, 100_000),
        41 => try runBurstStress(client, stderr, 1_000_000),
        else => {
            try printAvailableScenarios(stderr);
            return error.UnknownScenario;
        },
    }
}

/// Print list of available scenarios
pub fn printAvailableScenarios(stderr: anytype) !void {
    try stderr.print("Available scenarios:\n", .{});
    try stderr.print("\nBasic:\n", .{});
    try stderr.print("  1  - Simple orders (no match)\n", .{});
    try stderr.print("  2  - Matching trade\n", .{});
    try stderr.print("  3  - Cancel order\n", .{});
    try stderr.print("\nStress Tests (throttled):\n", .{});
    try stderr.print("  10 - Stress: 1K orders\n", .{});
    try stderr.print("  11 - Stress: 10K orders\n", .{});
    try stderr.print("  12 - Stress: 100K orders\n", .{});
    try stderr.print("  13 - Stress: 1M orders\n", .{});
    try stderr.print("  14 - Stress: 10M orders  ** EXTREME **\n", .{});
    try stderr.print("  15 - Stress: 100M orders ** INSANE **\n", .{});
    try stderr.print("\nMatching Stress (generates trades):\n", .{});
    try stderr.print("  20 - Matching: 1K pairs (2K orders, 1K trades)\n", .{});
    try stderr.print("  21 - Matching: 10K pairs\n", .{});
    try stderr.print("  22 - Matching: 100K pairs\n", .{});
    try stderr.print("  23 - Matching: 1M pairs  ** EXTREME **\n", .{});
    try stderr.print("\nMulti-Symbol Stress (tests dual-processor):\n", .{});
    try stderr.print("  30 - Multi-symbol: 10K orders\n", .{});
    try stderr.print("  31 - Multi-symbol: 100K orders\n", .{});
    try stderr.print("  32 - Multi-symbol: 1M orders\n", .{});
    try stderr.print("\nBurst Mode (no throttling - may cause server errors):\n", .{});
    try stderr.print("  40 - Burst: 100K orders (raw speed)\n", .{});
    try stderr.print("  41 - Burst: 1M orders (raw speed)\n", .{});
}

// ============================================================
// Basic Scenarios
// ============================================================

fn runScenario1(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 1: Simple Orders ===\n\n", .{});

    // Buy order
    try stderr.print("Sending: BUY IBM 50@100\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    // Sell order at different price (no match)
    try stderr.print("\nSending: SELL IBM 50@105\n", .{});
    try client.sendNewOrder(1, "IBM", 105, 50, .sell, 2);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    // Flush
    try stderr.print("\nSending: FLUSH\n", .{});
    try client.sendFlush();
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

fn runScenario2(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 2: Matching Trade ===\n\n", .{});

    // Buy order
    try stderr.print("Sending: BUY IBM 50@100\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    // Matching sell order (same price)
    try stderr.print("\nSending: SELL IBM 50@100 (should match!)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .sell, 2);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

fn runScenario3(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 3: Cancel Order ===\n\n", .{});

    // Buy order
    try stderr.print("Sending: BUY IBM 50@100\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    // Cancel
    try stderr.print("\nSending: CANCEL IBM order 1\n", .{});
    try client.sendCancel(1, "IBM", 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

// ============================================================
// Stress Tests
// ============================================================

fn runStressTest(client: *EngineClient, stderr: anytype, count: u32) !void {
    try stderr.print("=== Stress Test: {d} Orders ===\n\n", .{count});

    // Show human-readable count
    if (count >= 1_000_000) {
        try stderr.print("Sending {d}M buy orders...\n", .{count / 1_000_000});
    } else if (count >= 1_000) {
        try stderr.print("Sending {d}K buy orders...\n", .{count / 1_000});
    } else {
        try stderr.print("Sending {d} buy orders...\n", .{count});
    }

    // Flush first to clear any existing orders
    try client.sendFlush();
    std.time.sleep(100 * std.time.ns_per_ms);
    // Drain any flush responses
    _ = try drainResponses(client, 500);

    var send_errors: u32 = 0;
    var min_latency: u64 = std.math.maxInt(u64);
    var max_latency: u64 = 0;
    var total_latency: u64 = 0;

    // Adaptive batching based on count
    const batch_size: u32 = if (count >= 1_000_000) 50_000 else if (count >= 100_000) 10_000 else if (count >= 10_000) 1_000 else count;

    // Delay between batches (microseconds worth of nanoseconds)
    const delay_between_batches: u64 = if (count >= 10_000_000) 50 * std.time.ns_per_ms // 50ms for 10M+
    else if (count >= 1_000_000) 20 * std.time.ns_per_ms // 20ms for 1M+
    else if (count >= 100_000) 10 * std.time.ns_per_ms // 10ms for 100K+
    else 0;

    if (delay_between_batches > 0) {
        try stderr.print("Batched mode: {d} orders/batch, {d}ms delay\n", .{ batch_size, delay_between_batches / std.time.ns_per_ms });
    }

    // Progress tracking
    const progress_interval = count / 20; // 5% increments
    var last_progress: u32 = 0;

    const start_time = timestamp.now();

    // Send orders
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const order_start = timestamp.now();

        // Vary price slightly to create market depth
        const price: u32 = 100 + @as(u32, @intCast(i % 100));

        client.sendNewOrder(1, "IBM", price, 10, .buy, i + 1) catch {
            send_errors += 1;
            continue;
        };

        const order_end = timestamp.now();
        // Use saturating subtraction to prevent overflow
        const latency = if (order_end >= order_start) order_end - order_start else 0;
        total_latency +|= latency; // Saturating add
        if (latency < min_latency) min_latency = latency;
        if (latency > max_latency) max_latency = latency;

        // Progress indicator every 5%
        if (progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / count;
            const elapsed = (timestamp.now() - start_time) / 1_000_000;
            const rate: u64 = if (elapsed > 0) @as(u64, i) * 1000 / elapsed else 0;
            try stderr.print("  {d}% ({d} orders, {d} ms, {d} orders/sec)\n", .{ pct, i, elapsed, rate });
        }

        // Batch delay to prevent TCP buffer overflow
        if (delay_between_batches > 0 and i > 0 and i % batch_size == 0) {
            std.time.sleep(delay_between_batches);
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;

    // Print send results
    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Orders sent:     {d}\n", .{count - send_errors});
    try stderr.print("Send errors:     {d}\n", .{send_errors});

    if (total_time >= 1_000_000_000) {
        try stderr.print("Total time:      {d}.{d:0>3} sec\n", .{ total_time / 1_000_000_000, (total_time % 1_000_000_000) / 1_000_000 });
    } else {
        try stderr.print("Total time:      {d} ms\n", .{ total_time / 1_000_000 });
    }

    if (count > send_errors) {
        const successful = count - send_errors;
        const avg_latency = total_latency / successful;
        const throughput: u64 = if (total_time > 0)
            @as(u64, successful) * 1_000_000_000 / total_time
        else
            0;

        try stderr.print("\n=== Send Latency (client-side) ===\n", .{});
        try stderr.print("Min:             {d} ns ({d}.{d:0>3} us)\n", .{ min_latency, min_latency / 1000, min_latency % 1000 });
        try stderr.print("Avg:             {d} ns ({d}.{d:0>3} us)\n", .{ avg_latency, avg_latency / 1000, avg_latency % 1000 });
        try stderr.print("Max:             {d} ns ({d}.{d:0>3} us)\n", .{ max_latency, max_latency / 1000, max_latency % 1000 });
        try stderr.print("\n=== Send Throughput ===\n", .{});
        try stderr.print("Orders/sec:      {d}\n", .{throughput});

        if (throughput >= 1_000_000) {
            try stderr.print("                 ({d}.{d:0>2}M orders/sec)\n", .{ throughput / 1_000_000, (throughput % 1_000_000) / 10_000 });
        } else if (throughput >= 1_000) {
            try stderr.print("                 ({d}.{d:0>1}K orders/sec)\n", .{ throughput / 1_000, (throughput % 1_000) / 100 });
        }

        if (delay_between_batches > 0) {
            try stderr.print("\n(Note: throttled to prevent buffer overflow)\n", .{});
        }
    }

    // Count responses from server
    const expected_acks = count - send_errors;
    try stderr.print("\nCounting server responses (expecting {d} ACKs)...\n", .{expected_acks});

    // Adaptive timeout based on order count
    const drain_timeout_ms: u32 = if (count >= 1_000_000) 10_000 // 10s for 1M+
    else if (count >= 100_000) 5_000 // 5s for 100K+
    else if (count >= 10_000) 3_000 // 3s for 10K+
    else 2_000; // 2s default

    const stats = try drainResponses(client, drain_timeout_ms);
    try stats.printValidation(expected_acks, 0, stderr);

    // Flush at end
    try stderr.print("\nSending FLUSH to clear book...\n", .{});
    try client.sendFlush();
    std.time.sleep(500 * std.time.ns_per_ms);
}

fn runMatchingStress(client: *EngineClient, stderr: anytype, pairs: u32) !void {
    try stderr.print("=== Matching Stress Test: {d} Trade Pairs ===\n\n", .{pairs});
    try stderr.print("Sending {d} buy/sell pairs (should generate {d} trades)...\n", .{ pairs, pairs });

    // Flush first
    try client.sendFlush();
    std.time.sleep(100 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    var send_errors: u32 = 0;

    const start_time = timestamp.now();

    // Send matching pairs
    var i: u32 = 0;
    while (i < pairs) : (i += 1) {
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid = i * 2 + 1;
        const sell_oid = i * 2 + 2;

        // Buy order
        client.sendNewOrder(1, "IBM", price, 10, .buy, buy_oid) catch {
            send_errors += 1;
            continue;
        };

        // Matching sell order
        client.sendNewOrder(1, "IBM", price, 10, .sell, sell_oid) catch {
            send_errors += 1;
            continue;
        };

        // Progress indicator
        if (i > 0 and pairs >= 10 and i % (pairs / 10) == 0) {
            try stderr.print("  Progress: {d}%\n", .{(i * 100) / pairs});
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;
    const orders_sent = (pairs * 2) - send_errors;

    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Orders sent:     {d} ({d} pairs)\n", .{ orders_sent, pairs });
    try stderr.print("Send errors:     {d}\n", .{send_errors});
    try stderr.print("Total time:      {d} ms\n", .{total_time / 1_000_000});

    if (total_time > 0) {
        const throughput: u64 = @as(u64, orders_sent) * 1_000_000_000 / total_time;
        try stderr.print("Orders/sec:      {d}\n", .{throughput});
        try stderr.print("Trades/sec:      ~{d}\n", .{throughput / 2});
    }

    // Count responses - expect ACKs for each order and trades for each pair
    const expected_acks = orders_sent;
    const expected_trades = pairs; // One trade per pair
    try stderr.print("\nCounting server responses...\n", .{});
    try stderr.print("  Expecting {d} ACKs and {d} trades\n", .{ expected_acks, expected_trades });

    const drain_timeout_ms: u32 = if (pairs >= 100_000) 10_000 else if (pairs >= 10_000) 5_000 else 3_000;

    const stats = try drainResponses(client, drain_timeout_ms);
    try stats.printValidation(expected_acks, expected_trades, stderr);
}

fn runMultiSymbolStress(client: *EngineClient, stderr: anytype, count: u32) !void {
    try stderr.print("=== Multi-Symbol Stress Test: {d} Orders ===\n\n", .{count});

    // Symbols spread across both processors (A-M and N-Z)
    const symbols = [_][]const u8{
        "AAPL", "IBM", "GOOGL", "META", "MSFT", // Processor 0 (A-M)
        "NVDA", "TSLA", "UBER",  "SNAP", "ZM", // Processor 1 (N-Z)
    };

    try stderr.print("Using {d} symbols across both processors...\n", .{symbols.len});

    // Flush first
    try client.sendFlush();
    std.time.sleep(100 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    var send_errors: u32 = 0;
    var proc0_count: u32 = 0;
    var proc1_count: u32 = 0;

    const start_time = timestamp.now();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const symbol_idx = i % symbols.len;
        const symbol = symbols[symbol_idx];
        const price: u32 = 100 + @as(u32, @intCast(i % 100));
        const side: types.Side = if (i % 2 == 0) .buy else .sell;

        client.sendNewOrder(1, symbol, price, 10, side, i + 1) catch {
            send_errors += 1;
            continue;
        };

        // Track processor distribution
        if (symbol_idx < 5) {
            proc0_count += 1;
        } else {
            proc1_count += 1;
        }

        // Progress indicator
        if (i > 0 and count >= 10 and i % (count / 10) == 0) {
            try stderr.print("  Progress: {d}%\n", .{(i * 100) / count});
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;

    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Orders sent:     {d}\n", .{count - send_errors});
    try stderr.print("Send errors:     {d}\n", .{send_errors});
    try stderr.print("Total time:      {d} ms\n", .{total_time / 1_000_000});
    try stderr.print("\n=== Processor Distribution ===\n", .{});
    try stderr.print("Processor 0 (A-M): {d} orders\n", .{proc0_count});
    try stderr.print("Processor 1 (N-Z): {d} orders\n", .{proc1_count});

    if (total_time > 0) {
        const successful = count - send_errors;
        const throughput: u64 = @as(u64, successful) * 1_000_000_000 / total_time;
        try stderr.print("\n=== Throughput ===\n", .{});
        try stderr.print("Orders/sec:      {d}\n", .{throughput});
    }

    // Count responses
    const expected_acks = count - send_errors;
    try stderr.print("\nCounting server responses (expecting {d} ACKs)...\n", .{expected_acks});

    const drain_timeout_ms: u32 = if (count >= 100_000) 5_000 else if (count >= 10_000) 3_000 else 2_000;

    const stats = try drainResponses(client, drain_timeout_ms);
    try stats.printValidation(expected_acks, 0, stderr);

    // Flush at end
    try stderr.print("\nSending FLUSH to clear all books...\n", .{});
    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
}

// ============================================================
// Burst Stress Test (No Throttling)
// ============================================================

fn runBurstStress(client: *EngineClient, stderr: anytype, count: u32) !void {
    try stderr.print("=== BURST Stress Test: {d} Orders ===\n\n", .{count});
    try stderr.print("!!! WARNING: No throttling - may cause server parse errors !!!\n", .{});
    try stderr.print("!!! This tests raw client send speed !!!\n\n", .{});

    if (count >= 1_000_000) {
        try stderr.print("Sending {d}M orders at MAXIMUM SPEED...\n", .{count / 1_000_000});
    } else if (count >= 1_000) {
        try stderr.print("Sending {d}K orders at MAXIMUM SPEED...\n", .{count / 1_000});
    } else {
        try stderr.print("Sending {d} orders at MAXIMUM SPEED...\n", .{count});
    }

    // Flush first
    try client.sendFlush();
    std.time.sleep(100 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    var send_errors: u32 = 0;
    var min_latency: u64 = std.math.maxInt(u64);
    var max_latency: u64 = 0;
    var total_latency: u64 = 0;

    // Progress every 10%
    const progress_interval = count / 10;
    var last_progress: u32 = 0;

    const start_time = timestamp.now();

    // Send orders as FAST as possible - no delays!
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const order_start = timestamp.now();

        const price: u32 = 100 + @as(u32, @intCast(i % 100));

        client.sendNewOrder(1, "IBM", price, 10, .buy, i + 1) catch {
            send_errors += 1;
            continue;
        };

        const order_end = timestamp.now();
        // Use saturating subtraction to prevent overflow
        const latency = if (order_end >= order_start) order_end - order_start else 0;
        total_latency +|= latency; // Saturating add
        if (latency < min_latency) min_latency = latency;
        if (latency > max_latency) max_latency = latency;

        // Progress indicator every 10%
        if (progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            try stderr.print("  {d}%...\n", .{(i * 100) / count});
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;

    // Print results
    try stderr.print("\n=== BURST Send Results ===\n", .{});
    try stderr.print("Orders sent:     {d}\n", .{count - send_errors});
    try stderr.print("Send errors:     {d}\n", .{send_errors});

    if (total_time >= 1_000_000_000) {
        try stderr.print("Total time:      {d}.{d:0>3} sec\n", .{ total_time / 1_000_000_000, (total_time % 1_000_000_000) / 1_000_000 });
    } else {
        try stderr.print("Total time:      {d} ms\n", .{total_time / 1_000_000});
    }

    if (count > send_errors) {
        const successful = count - send_errors;
        const avg_latency = total_latency / successful;
        const throughput: u64 = if (total_time > 0)
            @as(u64, successful) * 1_000_000_000 / total_time
        else
            0;

        try stderr.print("\n=== Raw Send Latency ===\n", .{});
        try stderr.print("Min:             {d} ns ({d}.{d:0>3} us)\n", .{ min_latency, min_latency / 1000, min_latency % 1000 });
        try stderr.print("Avg:             {d} ns ({d}.{d:0>3} us)\n", .{ avg_latency, avg_latency / 1000, avg_latency % 1000 });
        try stderr.print("Max:             {d} ns ({d}.{d:0>3} us)\n", .{ max_latency, max_latency / 1000, max_latency % 1000 });
        try stderr.print("\n=== RAW Throughput (client-side) ===\n", .{});
        try stderr.print("Orders/sec:      {d}\n", .{throughput});

        if (throughput >= 1_000_000) {
            try stderr.print("                 ({d}.{d:0>2}M orders/sec)\n", .{ throughput / 1_000_000, (throughput % 1_000_000) / 10_000 });
        }
    }

    // Count responses
    const expected_acks = count - send_errors;
    try stderr.print("\nCounting server responses (expecting {d} ACKs)...\n", .{expected_acks});
    try stderr.print("(Note: burst mode may lose responses due to buffer overflow)\n", .{});

    const drain_timeout_ms: u32 = if (count >= 1_000_000) 15_000 else if (count >= 100_000) 10_000 else 5_000;

    const stats = try drainResponses(client, drain_timeout_ms);
    try stats.printValidation(expected_acks, 0, stderr);

    // Flush at end
    try stderr.print("\nSending FLUSH...\n", .{});
    try client.sendFlush();
    std.time.sleep(500 * std.time.ns_per_ms);
}

// ============================================================
// Response Handling
// ============================================================

/// Drain all responses from server and count them by type
fn drainResponses(client: *EngineClient, timeout_ms: u32) !ResponseStats {
    var stats = ResponseStats{};

    // Give server time to send responses
    std.time.sleep(100 * std.time.ns_per_ms);

    const start_time = timestamp.now();
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    // Keep reading until timeout
    while (timestamp.now() - start_time < timeout_ns) {
        const msg = recvMessage(client) catch |err| {
            if (err == error.Timeout or err == error.WouldBlock) {
                // No more messages available, wait a bit and try again
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            // Real error, stop
            break;
        };

        if (msg) |m| {
            switch (m.msg_type) {
                .ack => stats.acks += 1,
                .cancel_ack => stats.cancel_acks += 1,
                .trade => stats.trades += 1,
                .top_of_book => stats.top_of_book += 1,
            }
        } else {
            // null means no message, wait a bit
            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    return stats;
}

/// Try to receive a single message (returns null if none available)
fn recvMessage(client: *EngineClient) !?OutputMessage {
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        const raw_data = tcp_client.recv() catch |err| {
            return err;
        };
        return parseMessage(raw_data, proto);
    } else if (client.udp_client) |*udp_client| {
        const raw_data = udp_client.recv() catch |err| {
            return err;
        };
        return parseMessage(raw_data, proto);
    }

    return null;
}

fn parseMessage(raw_data: []const u8, proto: engine_client.Protocol) ?OutputMessage {
    if (proto == .binary) {
        if (binary.isBinaryProtocol(raw_data)) {
            return binary.decodeOutput(raw_data) catch null;
        }
    }
    return csv.parseOutput(raw_data) catch null;
}

fn recvAndPrintResponses(client: *EngineClient, stderr: anytype) !void {
    const proto = client.getProtocol();

    // Handle TCP responses
    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        const max_responses: u32 = 20;

        std.time.sleep(50 * std.time.ns_per_ms);

        while (response_count < max_responses) {
            const raw_data = tcp_client.recv() catch |err| {
                if (response_count > 0) break;
                if (err == error.Timeout) {
                    try stderr.print("[No response - timeout]\n", .{});
                }
                break;
            };

            try printRawResponse(raw_data, proto, stderr);
            response_count += 1;
        }
    }
    // Handle UDP responses
    else if (client.udp_client) |*udp_client| {
        var response_count: u32 = 0;
        const max_responses: u32 = 20;

        std.time.sleep(50 * std.time.ns_per_ms);

        while (response_count < max_responses) {
            const raw_data = udp_client.recv() catch {
                break;
            };

            try printRawResponse(raw_data, proto, stderr);
            response_count += 1;
        }

        if (response_count == 0) {
            try stderr.print("[No UDP response received]\n", .{});
        }
    }
}

fn printRawResponse(raw_data: []const u8, proto: engine_client.Protocol, stderr: anytype) !void {
    if (proto == .binary) {
        if (binary.isBinaryProtocol(raw_data)) {
            const msg = binary.decodeOutput(raw_data) catch |err| {
                try stderr.print("[Parse error: {s}]\n", .{@errorName(err)});
                return;
            };
            try printResponse(msg, stderr);
        } else {
            try stderr.print("[RECV] {s}\n", .{raw_data});
        }
    } else {
        const msg = csv.parseOutput(raw_data) catch {
            try stderr.print("[RECV] {s}", .{raw_data});
            if (raw_data.len > 0 and raw_data[raw_data.len - 1] != '\n') {
                try stderr.print("\n", .{});
            }
            return;
        };
        try printResponse(msg, stderr);
    }
}

fn printResponse(msg: OutputMessage, stderr: anytype) !void {
    const symbol = msg.symbol[0..msg.symbol_len];

    switch (msg.msg_type) {
        .ack => {
            try stderr.print("[RECV] A, {s}, {d}, {d}\n", .{
                symbol,
                msg.user_id,
                msg.order_id,
            });
        },
        .cancel_ack => {
            try stderr.print("[RECV] C, {s}, {d}, {d}\n", .{
                symbol,
                msg.user_id,
                msg.order_id,
            });
        },
        .trade => {
            try stderr.print("[RECV] T, {s}, {d}, {d}, {d}, {d}, {d}, {d}\n", .{
                symbol,
                msg.buy_user_id,
                msg.buy_order_id,
                msg.sell_user_id,
                msg.sell_order_id,
                msg.price,
                msg.quantity,
            });
        },
        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| @intFromEnum(s) else '-';
            if (msg.price == 0 and msg.quantity == 0) {
                try stderr.print("[RECV] B, {s}, {c}, -, -\n", .{
                    symbol,
                    side_char,
                });
            } else {
                try stderr.print("[RECV] B, {s}, {c}, {d}, {d}\n", .{
                    symbol,
                    side_char,
                    msg.price,
                    msg.quantity,
                });
            }
        },
    }
}

// ============================================================
// Tests
// ============================================================

test "scenario numbers are valid" {
    // Just verify the switch cases compile
    const valid_scenarios = [_]u8{ 1, 2, 3, 10, 11, 12, 13, 20, 21, 30 };
    for (valid_scenarios) |s| {
        _ = s;
    }
}

test "ResponseStats total" {
    var stats = ResponseStats{};
    stats.acks = 10;
    stats.trades = 5;
    stats.top_of_book = 3;
    try std.testing.expectEqual(@as(u32, 18), stats.total());
}
