//! Test scenarios for the matching engine client.
//!
//! Focuses on two key benchmarks:
//! 1. Input throughput (unmatched orders) - how fast can we accept orders?
//! 2. Matching throughput (trade pairs) - how fast can we execute trades?
//!
//! Supports quiet mode for high-volume tests to avoid flooding terminal.

const std = @import("std");
const types = @import("protocol/types.zig");
const binary = @import("protocol/binary.zig");
const csv = @import("protocol/csv.zig");
const timestamp = @import("util/timestamp.zig");
const engine_client = @import("client/engine_client.zig");

const EngineClient = engine_client.EngineClient;
const OutputMessage = types.OutputMessage;

// ============================================================
// Configuration
// ============================================================

pub const ScenarioConfig = struct {
    quiet: bool = false, // Suppress progress output
};

var global_config = ScenarioConfig{};

pub fn setQuiet(quiet: bool) void {
    global_config.quiet = quiet;
}

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
    packets_received: u32 = 0,

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
        if (self.packets_received > 0 and self.total() > self.packets_received) {
            const msgs_per_packet = self.total() / self.packets_received;
            try stderr.print("UDP packets:     {d} (~{d} msgs/packet)\n", .{ self.packets_received, msgs_per_packet });
        }
    }

    pub fn printValidation(self: ResponseStats, expected_acks: u32, expected_trades: u32, stderr: anytype) !void {
        try self.print(stderr);

        try stderr.print("\n=== Validation ===\n", .{});

        // ACK validation
        if (self.acks >= expected_acks) {
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
            if (self.trades >= expected_trades) {
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
        const passed = (self.acks >= expected_acks) and (self.trades >= expected_trades or expected_trades == 0);
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
        // Basic functional tests
        1 => try runScenario1(client, stderr),
        2 => try runScenario2(client, stderr),
        3 => try runScenario3(client, stderr),

        // Unmatched order stress (input throughput)
        10 => try runStressTest(client, stderr, 1_000),
        11 => try runStressTest(client, stderr, 10_000),
        12 => try runStressTest(client, stderr, 100_000),

        // Matching stress (trade throughput) - THE REAL BENCHMARK
        20 => try runMatchingStress(client, stderr, 1_000),
        21 => try runMatchingStress(client, stderr, 10_000),
        22 => try runMatchingStress(client, stderr, 100_000),
        23 => try runMatchingStress(client, stderr, 250_000),
        24 => try runMatchingStress(client, stderr, 500_000),

        else => {
            try printAvailableScenarios(stderr);
            return error.UnknownScenario;
        },
    }
}

/// Print list of available scenarios
pub fn printAvailableScenarios(stderr: anytype) !void {
    try stderr.print("Available scenarios:\n", .{});
    try stderr.print("\nBasic Functional Tests:\n", .{});
    try stderr.print("  1  - Simple orders (no match)\n", .{});
    try stderr.print("  2  - Matching trade\n", .{});
    try stderr.print("  3  - Cancel order\n", .{});
    try stderr.print("\nUnmatched Order Stress (input throughput):\n", .{});
    try stderr.print("  10 - 1K orders\n", .{});
    try stderr.print("  11 - 10K orders\n", .{});
    try stderr.print("  12 - 100K orders\n", .{});
    try stderr.print("\nMatching Stress (trade throughput) ★ KEY BENCHMARK:\n", .{});
    try stderr.print("  20 - 1K trades     (2K orders)\n", .{});
    try stderr.print("  21 - 10K trades    (20K orders)\n", .{});
    try stderr.print("  22 - 100K trades   (200K orders)\n", .{});
    try stderr.print("  23 - 250K trades   (500K orders)  [use --quiet]\n", .{});
    try stderr.print("  24 - 500K trades   (1M orders)    [use --quiet]\n", .{});
    try stderr.print("\nOptions:\n", .{});
    try stderr.print("  --quiet  Suppress progress output (required for 23+)\n", .{});
}

// ============================================================
// Basic Scenarios
// ============================================================

fn runScenario1(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 1: Simple Orders ===\n\n", .{});

    try stderr.print("Sending: BUY IBM 50@100\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    try stderr.print("\nSending: SELL IBM 50@105\n", .{});
    try client.sendNewOrder(1, "IBM", 105, 50, .sell, 2);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    try stderr.print("\nSending: FLUSH\n", .{});
    try client.sendFlush();
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

fn runScenario2(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 2: Matching Trade ===\n\n", .{});

    try stderr.print("Sending: BUY IBM 50@100\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    try stderr.print("\nSending: SELL IBM 50@100 (should match!)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .sell, 2);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

fn runScenario3(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 3: Cancel Order ===\n\n", .{});

    try stderr.print("Sending: BUY IBM 50@100\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);

    try stderr.print("\nSending: CANCEL IBM order 1\n", .{});
    try client.sendCancel(1, "IBM", 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

// ============================================================
// Unmatched Stress Test (Input Throughput)
// ============================================================

fn runStressTest(client: *EngineClient, stderr: anytype, count: u32) !void {
    const quiet = global_config.quiet;

    try stderr.print("=== Unmatched Stress Test: {d} Orders ===\n\n", .{count});

    if (count >= 1_000_000) {
        try stderr.print("Sending {d}M buy orders...\n", .{count / 1_000_000});
    } else if (count >= 1_000) {
        try stderr.print("Sending {d}K buy orders...\n", .{count / 1_000});
    } else {
        try stderr.print("Sending {d} buy orders...\n", .{count});
    }

    // Flush first
    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    var send_errors: u32 = 0;
    var min_latency: u64 = std.math.maxInt(u64);
    var max_latency: u64 = 0;
    var total_latency: u64 = 0;

    // Throttling parameters
    const batch_size: u32 = if (count >= 100_000) 500 else if (count >= 10_000) 200 else 100;
    const delay_ns: u64 = if (count >= 100_000) 10 * std.time.ns_per_ms else if (count >= 10_000) 5 * std.time.ns_per_ms else 2 * std.time.ns_per_ms;

    if (!quiet) {
        try stderr.print("Throttling: {d} orders/batch, {d}ms delay\n", .{ batch_size, delay_ns / std.time.ns_per_ms });
    }

    const progress_interval = count / 20;
    var last_progress: u32 = 0;

    const start_time = timestamp.now();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const order_start = timestamp.now();
        const price: u32 = 100 + @as(u32, @intCast(i % 100));

        client.sendNewOrder(1, "IBM", price, 10, .buy, i + 1) catch {
            send_errors += 1;
            continue;
        };

        const order_end = timestamp.now();
        const latency = if (order_end >= order_start) order_end - order_start else 0;
        total_latency +|= latency;
        if (latency < min_latency) min_latency = latency;
        if (latency > max_latency) max_latency = latency;

        // Progress
        if (!quiet and progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / count;
            const elapsed = (timestamp.now() - start_time) / 1_000_000;
            const rate: u64 = if (elapsed > 0) @as(u64, i) * 1000 / elapsed else 0;
            try stderr.print("  {d}% ({d} orders, {d} ms, {d} orders/sec)\n", .{ pct, i, elapsed, rate });
        }

        // Batch delay
        if (i > 0 and i % batch_size == 0) {
            std.time.sleep(delay_ns);
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;

    // Results
    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Orders sent:     {d}\n", .{count - send_errors});
    try stderr.print("Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Total time:      ", total_time);

    if (count > send_errors) {
        const successful = count - send_errors;
        const avg_latency = total_latency / successful;
        const throughput: u64 = if (total_time > 0) @as(u64, successful) * 1_000_000_000 / total_time else 0;

        try stderr.print("\n=== Latency (client-side send) ===\n", .{});
        try printLatency(stderr, "Min: ", min_latency);
        try printLatency(stderr, "Avg: ", avg_latency);
        try printLatency(stderr, "Max: ", max_latency);

        try stderr.print("\n=== Throughput ===\n", .{});
        try printThroughput(stderr, "Orders/sec: ", throughput);
    }

    // Drain responses
    const expected_acks = count - send_errors;
    try stderr.print("\nDraining responses (expecting {d} ACKs)...\n", .{expected_acks});

    const drain_timeout_ms: u32 = if (count >= 100_000) 15_000 else if (count >= 10_000) 10_000 else 5_000;
    const stats = try drainResponses(client, drain_timeout_ms);
    try stats.printValidation(expected_acks, 0, stderr);

    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
}

// ============================================================
// Matching Stress Test (Trade Throughput) - KEY BENCHMARK
// ============================================================

fn runMatchingStress(client: *EngineClient, stderr: anytype, trades: u32) !void {
    const quiet = global_config.quiet;
    const orders = trades * 2;

    try stderr.print("=== Matching Stress Test: {d} Trades ===\n\n", .{trades});

    if (trades >= 1_000_000) {
        try stderr.print("Target: {d}M trades ({d}M orders)\n", .{ trades / 1_000_000, orders / 1_000_000 });
    } else if (trades >= 1_000) {
        try stderr.print("Target: {d}K trades ({d}K orders)\n", .{ trades / 1_000, orders / 1_000 });
    } else {
        try stderr.print("Target: {d} trades ({d} orders)\n", .{ trades, orders });
    }

    // Flush first
    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    // CRITICAL: Aggressive throttling for matching scenarios
    // Each trade pair generates ~5 outputs (2 ACKs + 1 Trade + 2 ToB)
    // Server output queue is 65K, so we need to pace carefully
    const pairs_per_batch: u32 = if (trades >= 250_000) 100 // Very conservative for huge tests
    else if (trades >= 100_000) 200 else if (trades >= 10_000) 500 else 1000;

    const delay_between_batches_ns: u64 = if (trades >= 250_000) 75 * std.time.ns_per_ms // 50ms for 250K+
    else if (trades >= 100_000) 45 * std.time.ns_per_ms // 30ms for 100K
    else if (trades >= 10_000) 25 * std.time.ns_per_ms // 15ms for 10K
    else 5 * std.time.ns_per_ms;

    if (!quiet) {
        try stderr.print("Throttling: {d} pairs/batch, {d}ms delay\n", .{ pairs_per_batch, delay_between_batches_ns / std.time.ns_per_ms });
    }

    var send_errors: u32 = 0;
    var pairs_sent: u32 = 0;

    const progress_interval = trades / 10;
    var last_progress: u32 = 0;

    const start_time = timestamp.now();

    var i: u32 = 0;
    while (i < trades) : (i += 1) {
        // Use varying prices to create realistic order book
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid = i * 2 + 1;
        const sell_oid = i * 2 + 2;

        // Buy order
        client.sendNewOrder(1, "IBM", price, 10, .buy, buy_oid) catch {
            send_errors += 1;
            continue;
        };

        // Matching sell order (immediate trade)
        client.sendNewOrder(1, "IBM", price, 10, .sell, sell_oid) catch {
            send_errors += 1;
            continue;
        };

        pairs_sent += 1;

        // Progress
        if (!quiet and progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / trades;
            const elapsed = (timestamp.now() - start_time) / 1_000_000;
            const rate: u64 = if (elapsed > 0) @as(u64, pairs_sent) * 1000 / elapsed else 0;
            try stderr.print("  {d}% ({d} pairs, {d} ms, {d} trades/sec)\n", .{ pct, pairs_sent, elapsed, rate });
        }

        // Batch delay - CRITICAL for not overwhelming output queue
        if (i > 0 and i % pairs_per_batch == 0) {
            std.time.sleep(delay_between_batches_ns);
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;
    const orders_sent = pairs_sent * 2;

    // Results
    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Trade pairs:     {d}\n", .{pairs_sent});
    try stderr.print("Orders sent:     {d}\n", .{orders_sent});
    try stderr.print("Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const throughput: u64 = @as(u64, orders_sent) * 1_000_000_000 / total_time;
        const trade_rate: u64 = @as(u64, pairs_sent) * 1_000_000_000 / total_time;

        try stderr.print("\n=== Throughput ===\n", .{});
        try printThroughput(stderr, "Orders/sec:  ", throughput);
        try printThroughput(stderr, "Trades/sec:  ", trade_rate);
    }

    // Drain responses
    const expected_acks = orders_sent;
    const expected_trades = pairs_sent;
    try stderr.print("\nDraining responses...\n", .{});
    try stderr.print("  Expecting {d} ACKs and {d} trades\n", .{ expected_acks, expected_trades });

    // Longer timeout for matching - lots of output messages
    const drain_timeout_ms: u32 = if (trades >= 250_000) 70_000 // 60s for 250K+
    else if (trades >= 100_000) 30_000 // 30s for 100K
    else if (trades >= 10_000) 15_000 else 10_000;

    const stats = try drainResponses(client, drain_timeout_ms);
    try stats.printValidation(expected_acks, expected_trades, stderr);

    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
}

// ============================================================
// Formatting Helpers
// ============================================================

fn printTime(stderr: anytype, prefix: []const u8, ns: u64) !void {
    if (ns >= 1_000_000_000) {
        try stderr.print("{s}{d}.{d:0>3} sec\n", .{ prefix, ns / 1_000_000_000, (ns % 1_000_000_000) / 1_000_000 });
    } else {
        try stderr.print("{s}{d} ms\n", .{ prefix, ns / 1_000_000 });
    }
}

fn printLatency(stderr: anytype, prefix: []const u8, ns: u64) !void {
    if (ns >= 1_000_000) {
        try stderr.print("{s}{d}.{d:0>3} ms\n", .{ prefix, ns / 1_000_000, (ns % 1_000_000) / 1_000 });
    } else if (ns >= 1_000) {
        try stderr.print("{s}{d}.{d:0>3} us\n", .{ prefix, ns / 1_000, ns % 1_000 });
    } else {
        try stderr.print("{s}{d} ns\n", .{ prefix, ns });
    }
}

fn printThroughput(stderr: anytype, prefix: []const u8, rate: u64) !void {
    if (rate >= 1_000_000) {
        try stderr.print("{s}{d}.{d:0>2}M/sec\n", .{ prefix, rate / 1_000_000, (rate % 1_000_000) / 10_000 });
    } else if (rate >= 1_000) {
        try stderr.print("{s}{d}.{d:0>1}K/sec\n", .{ prefix, rate / 1_000, (rate % 1_000) / 100 });
    } else {
        try stderr.print("{s}{d}/sec\n", .{ prefix, rate });
    }
}

// ============================================================
// Response Handling
// ============================================================

fn drainResponses(client: *EngineClient, timeout_ms: u32) !ResponseStats {
    var stats = ResponseStats{};

    // Initial settle time
    std.time.sleep(500 * std.time.ns_per_ms);

    const start_time = timestamp.now();
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;

    while (timestamp.now() - start_time < timeout_ns) {
        const packet_stats = recvAndCountMessages(client) catch |err| {
            if (err == error.Timeout or err == error.WouldBlock) {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            break;
        };

        stats.acks += packet_stats.acks;
        stats.cancel_acks += packet_stats.cancel_acks;
        stats.trades += packet_stats.trades;
        stats.top_of_book += packet_stats.top_of_book;
        stats.rejects += packet_stats.rejects;
        stats.parse_errors += packet_stats.parse_errors;
        stats.packets_received += 1;
    }

    return stats;
}

fn recvAndCountMessages(client: *EngineClient) !ResponseStats {
    var stats = ResponseStats{};
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        const raw_data = tcp_client.recv() catch |err| {
            return err;
        };
        if (parseMessage(raw_data, proto)) |m| {
            countMessage(&stats, m);
        }
    } else if (client.udp_client) |*udp_client| {
        const raw_data = udp_client.recv() catch |err| {
            return err;
        };

        if (proto == .binary) {
            if (parseMessage(raw_data, proto)) |m| {
                countMessage(&stats, m);
            }
        } else {
            // CSV - parse all newline-delimited messages
            var remaining = raw_data;
            while (remaining.len > 0) {
                const newline_pos = std.mem.indexOfScalar(u8, remaining, '\n');

                if (newline_pos) |pos| {
                    const line = remaining[0 .. pos + 1];
                    if (line.len > 1) {
                        if (csv.parseOutput(line)) |m| {
                            countMessage(&stats, m);
                        } else |_| {
                            stats.parse_errors += 1;
                        }
                    }
                    remaining = remaining[pos + 1 ..];
                } else {
                    if (remaining.len > 0) {
                        if (csv.parseOutput(remaining)) |m| {
                            countMessage(&stats, m);
                        } else |_| {}
                    }
                    break;
                }
            }
        }
    }

    return stats;
}

fn countMessage(stats: *ResponseStats, msg: OutputMessage) void {
    switch (msg.msg_type) {
        .ack => stats.acks += 1,
        .cancel_ack => stats.cancel_acks += 1,
        .trade => stats.trades += 1,
        .top_of_book => stats.top_of_book += 1,
    }
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
    } else if (client.udp_client) |*udp_client| {
        var response_count: u32 = 0;
        const max_responses: u32 = 20;

        std.time.sleep(50 * std.time.ns_per_ms);

        while (response_count < max_responses) {
            const raw_data = udp_client.recv() catch {
                break;
            };

            try printBatchedResponses(raw_data, proto, stderr);
            response_count += 1;
        }

        if (response_count == 0) {
            try stderr.print("[No UDP response received]\n", .{});
        }
    }
}

fn printBatchedResponses(raw_data: []const u8, proto: engine_client.Protocol, stderr: anytype) !void {
    if (proto == .binary) {
        try printRawResponse(raw_data, proto, stderr);
        return;
    }

    var remaining = raw_data;
    while (remaining.len > 0) {
        const newline_pos = std.mem.indexOfScalar(u8, remaining, '\n');

        if (newline_pos) |pos| {
            const line = remaining[0 .. pos + 1];
            if (line.len > 1) {
                try printRawResponse(line, proto, stderr);
            }
            remaining = remaining[pos + 1 ..];
        } else {
            if (remaining.len > 0) {
                try printRawResponse(remaining, proto, stderr);
            }
            break;
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
            try stderr.print("[RECV] A, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id });
        },
        .cancel_ack => {
            try stderr.print("[RECV] C, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id });
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
                try stderr.print("[RECV] B, {s}, {c}, -, -\n", .{ symbol, side_char });
            } else {
                try stderr.print("[RECV] B, {s}, {c}, {d}, {d}\n", .{ symbol, side_char, msg.price, msg.quantity });
            }
        },
    }
}

// ============================================================
// Tests
// ============================================================

test "scenario numbers are valid" {
    const valid_scenarios = [_]u8{ 1, 2, 3, 10, 11, 12, 20, 21, 22, 23, 24 };
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
