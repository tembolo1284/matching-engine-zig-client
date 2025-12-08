//! Test scenarios for the matching engine client.
//! Uses interleaved send/receive with tryRecv for high-volume tests.

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
    quiet: bool = false,
};

var global_config = ScenarioConfig{};

pub fn setQuiet(quiet: bool) void {
    global_config.quiet = quiet;
}

// ============================================================
// Response Statistics (u64 for huge tests)
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

    pub fn print(self: ResponseStats, stderr: anytype) !void {
        try stderr.print("\n=== Server Response Summary ===\n", .{});
        try stderr.print("ACKs:            {d}\n", .{self.acks});
        if (self.cancel_acks > 0) try stderr.print("Cancel ACKs:     {d}\n", .{self.cancel_acks});
        if (self.trades > 0) try stderr.print("Trades:          {d}\n", .{self.trades});
        try stderr.print("Top of Book:     {d}\n", .{self.top_of_book});
        if (self.rejects > 0) try stderr.print("Rejects:         {d}\n", .{self.rejects});
        if (self.parse_errors > 0) try stderr.print("Parse errors:    {d}\n", .{self.parse_errors});
        try stderr.print("Total messages:  {d}\n", .{self.total()});
    }

    pub fn printValidation(self: ResponseStats, expected_acks: u64, expected_trades: u64, stderr: anytype) !void {
        try self.print(stderr);
        try stderr.print("\n=== Validation ===\n", .{});

        if (self.acks >= expected_acks) {
            try stderr.print("ACKs:            {d}/{d} ✓ PASS\n", .{ self.acks, expected_acks });
        } else {
            const pct = if (expected_acks > 0) (self.acks * 100) / expected_acks else 0;
            try stderr.print("ACKs:            {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                self.acks, expected_acks, pct, expected_acks - self.acks,
            });
        }

        if (expected_trades > 0) {
            if (self.trades >= expected_trades) {
                try stderr.print("Trades:          {d}/{d} ✓ PASS\n", .{ self.trades, expected_trades });
            } else {
                const pct = if (expected_trades > 0) (self.trades * 100) / expected_trades else 0;
                try stderr.print("Trades:          {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                    self.trades, expected_trades, pct, expected_trades - self.trades,
                });
            }
        }

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

pub fn run(client: *EngineClient, scenario: u8, stderr: anytype) !void {
    switch (scenario) {
        1 => try runScenario1(client, stderr),
        2 => try runScenario2(client, stderr),
        3 => try runScenario3(client, stderr),
        10 => try runStressTest(client, stderr, 1_000),
        11 => try runStressTest(client, stderr, 10_000),
        12 => try runStressTest(client, stderr, 100_000),
        20 => try runMatchingStress(client, stderr, 1_000),
        21 => try runMatchingStress(client, stderr, 10_000),
        22 => try runMatchingStress(client, stderr, 100_000),
        23 => try runMatchingStress(client, stderr, 250_000),
        24 => try runMatchingStress(client, stderr, 500_000),
        25 => try runMatchingStress(client, stderr, 250_000_000),
        else => {
            try printAvailableScenarios(stderr);
            return error.UnknownScenario;
        },
    }
}

pub fn printAvailableScenarios(stderr: anytype) !void {
    try stderr.print("Available scenarios:\n", .{});
    try stderr.print("\nBasic: 1 (orders), 2 (trade), 3 (cancel)\n", .{});
    try stderr.print("\nUnmatched: 10 (1K), 11 (10K), 12 (100K)\n", .{});
    try stderr.print("\nMatching ★ KEY BENCHMARK:\n", .{});
    try stderr.print("  20 - 1K trades\n", .{});
    try stderr.print("  21 - 10K trades\n", .{});
    try stderr.print("  22 - 100K trades\n", .{});
    try stderr.print("  23 - 250K trades\n", .{});
    try stderr.print("  24 - 500K trades\n", .{});
    try stderr.print("  25 - 250M trades ★★★ LEGENDARY ★★★\n", .{});
}

// ============================================================
// Basic Scenarios
// ============================================================

fn runScenario1(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 1: Simple Orders ===\n\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
    try client.sendNewOrder(1, "IBM", 105, 50, .sell, 2);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

fn runScenario2(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 2: Matching Trade ===\n\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
    try client.sendNewOrder(1, "IBM", 100, 50, .sell, 2);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

fn runScenario3(client: *EngineClient, stderr: anytype) !void {
    try stderr.print("=== Scenario 3: Cancel Order ===\n\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
    try client.sendCancel(1, "IBM", 1);
    std.time.sleep(100 * std.time.ns_per_ms);
    try recvAndPrintResponses(client, stderr);
}

// ============================================================
// Unmatched Stress Test
// ============================================================

fn runStressTest(client: *EngineClient, stderr: anytype, count: u32) !void {
    const quiet = global_config.quiet;
    try stderr.print("=== Unmatched Stress: {d} Orders ===\n\n", .{count});

    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    const batch_size: u32 = if (count >= 100_000) 500 else if (count >= 10_000) 200 else 100;
    const delay_ns: u64 = if (count >= 100_000) 10 * std.time.ns_per_ms 
        else if (count >= 10_000) 5 * std.time.ns_per_ms 
        else 2 * std.time.ns_per_ms;

    if (!quiet) try stderr.print("Throttle: {d}/batch, {d}ms delay\n", .{ batch_size, delay_ns / std.time.ns_per_ms });

    var send_errors: u32 = 0;
    const progress_interval = count / 10;
    var last_progress: u32 = 0;
    const start_time = timestamp.now();

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const price: u32 = 100 + @as(u32, @intCast(i % 100));
        client.sendNewOrder(1, "IBM", price, 10, .buy, i + 1) catch {
            send_errors += 1;
            continue;
        };

        if (!quiet and progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / count;
            try stderr.print("  {d}%\n", .{pct});
        }

        if (i > 0 and i % batch_size == 0) {
            std.time.sleep(delay_ns);
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;

    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Orders sent:     {d}\n", .{count - send_errors});
    try stderr.print("Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Total time:      ", total_time);

    const expected_acks: u64 = count - send_errors;
    try stderr.print("\nDraining responses...\n", .{});
    const stats = try drainResponses(client, 15_000);
    try stats.printValidation(expected_acks, 0, stderr);
}

// ============================================================
// Matching Stress Test - INTERLEAVED SEND/RECEIVE
// ============================================================

fn runMatchingStress(client: *EngineClient, stderr: anytype, trades: u64) !void {
    const quiet = global_config.quiet;
    const orders = trades * 2;

    // Epic banner for legendary test
    if (trades >= 100_000_000) {
        try stderr.print("\n", .{});
        try stderr.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        try stderr.print("║  ★★★ LEGENDARY MATCHING STRESS TEST ★★★                  ║\n", .{});
        try stderr.print("║  {d}M TRADES ({d}M ORDERS)                              ║\n", .{ trades / 1_000_000, orders / 1_000_000 });
        try stderr.print("║  Blood, Sweat, and Tears Mode                            ║\n", .{});
        try stderr.print("╚══════════════════════════════════════════════════════════╝\n", .{});
        try stderr.print("\n", .{});
    } else {
        try stderr.print("=== Matching Stress Test: {d} Trades ===\n\n", .{trades});
    }

    if (trades >= 1_000_000) {
        try stderr.print("Target: {d}M trades ({d}M orders)\n", .{ trades / 1_000_000, orders / 1_000_000 });
    } else if (trades >= 1_000) {
        try stderr.print("Target: {d}K trades ({d}K orders)\n", .{ trades / 1_000, orders / 1_000 });
    } else {
        try stderr.print("Target: {d} trades ({d} orders)\n", .{ trades, orders });
    }

    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
    _ = try drainResponses(client, 500);

    // Throttling parameters
    const pairs_per_batch: u64 = if (trades >= 100_000_000) 50
        else if (trades >= 1_000_000) 100
        else if (trades >= 250_000) 100
        else if (trades >= 100_000) 150
        else if (trades >= 10_000) 300
        else 500;

    const delay_between_batches_ns: u64 = if (trades >= 100_000_000) 50 * std.time.ns_per_ms
        else if (trades >= 1_000_000) 40 * std.time.ns_per_ms
        else if (trades >= 250_000) 30 * std.time.ns_per_ms
        else if (trades >= 100_000) 25 * std.time.ns_per_ms
        else if (trades >= 10_000) 15 * std.time.ns_per_ms
        else 5 * std.time.ns_per_ms;

    // Progress: 5% for huge tests, 10% for others
    const progress_pct: u64 = if (trades >= 1_000_000) 5 else 10;
    const progress_interval = trades / (100 / progress_pct);

    try stderr.print("Throttling: {d} pairs/batch, {d}ms delay (interleaved recv)\n", .{ 
        pairs_per_batch, delay_between_batches_ns / std.time.ns_per_ms 
    });

    var send_errors: u64 = 0;
    var pairs_sent: u64 = 0;
    var running_stats = ResponseStats{};
    var last_progress: u64 = 0;

    const start_time = timestamp.now();

    var i: u64 = 0;
    while (i < trades) : (i += 1) {
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
        const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

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

        pairs_sent += 1;

        // Progress
        if (!quiet and progress_interval > 0 and i > 0 and i / progress_interval > last_progress) {
            last_progress = i / progress_interval;
            const pct = (i * 100) / trades;
            const elapsed = (timestamp.now() - start_time) / 1_000_000;
            const rate: u64 = if (elapsed > 0) pairs_sent * 1000 / elapsed else 0;
            try stderr.print("  {d}% | {d} pairs | {d} ms | {d} trades/sec | recv'd: {d}\n", .{ 
                pct, pairs_sent, elapsed, rate, running_stats.total() 
            });
        }

        // INTERLEAVED RECEIVE - drain between batches using tryRecv
        if (i > 0 and i % pairs_per_batch == 0) {
            // Non-blocking drain: poll with short timeout, get what's available
            var drained: u64 = 0;
            const max_drain = pairs_per_batch * 8;
            while (drained < max_drain) : (drained += 1) {
                // Use tryRecv with 1ms timeout - returns null if no data
                const packet_stats = tryRecvAndCount(client) catch break;
                if (packet_stats.total() == 0) break; // No more data available
                running_stats.add(packet_stats);
            }
            std.time.sleep(delay_between_batches_ns);
        }
    }

    const end_time = timestamp.now();
    const total_time = if (end_time >= start_time) end_time - start_time else 0;
    const orders_sent = pairs_sent * 2;

    try stderr.print("\n=== Send Results ===\n", .{});
    try stderr.print("Trade pairs:     {d}\n", .{pairs_sent});
    try stderr.print("Orders sent:     {d}\n", .{orders_sent});
    try stderr.print("Send errors:     {d}\n", .{send_errors});
    try printTime(stderr, "Total time:      ", total_time);

    if (total_time > 0) {
        const throughput: u64 = orders_sent * 1_000_000_000 / total_time;
        const trade_rate: u64 = pairs_sent * 1_000_000_000 / total_time;
        try stderr.print("\n=== Throughput ===\n", .{});
        try printThroughput(stderr, "Orders/sec:  ", throughput);
        try printThroughput(stderr, "Trades/sec:  ", trade_rate);
    }

    try stderr.print("\nReceived during send: {d} messages\n", .{running_stats.total()});

    const expected_acks = orders_sent;
    const expected_trades = pairs_sent;
    const expected_total = expected_acks + expected_trades + expected_trades * 2; // ACKs + trades + ToB
    const remaining = expected_total -| running_stats.total();
    try stderr.print("Final drain (expecting ~{d} more)...\n", .{remaining});

    // Final drain - longer for huge tests
    const drain_timeout_ms: u32 = if (trades >= 100_000_000) 600_000
        else if (trades >= 1_000_000) 300_000
        else if (trades >= 250_000) 120_000
        else if (trades >= 100_000) 90_000
        else if (trades >= 10_000) 45_000
        else 30_000;

    const final_stats = try drainResponses(client, drain_timeout_ms);
    
    var total_stats = ResponseStats{};
    total_stats.add(running_stats);
    total_stats.add(final_stats);

    try total_stats.printValidation(expected_acks, expected_trades, stderr);

    // Victory banner
    if (trades >= 100_000_000 and total_stats.trades >= expected_trades) {
        try stderr.print("\n", .{});
        try stderr.print("╔══════════════════════════════════════════════════════════╗\n", .{});
        try stderr.print("║  ★★★ LEGENDARY ACHIEVEMENT UNLOCKED ★★★                  ║\n", .{});
        try stderr.print("║  {d}M TRADES MATCHED SUCCESSFULLY!                      ║\n", .{total_stats.trades / 1_000_000});
        try stderr.print("╚══════════════════════════════════════════════════════════╝\n", .{});
    }

    try client.sendFlush();
    std.time.sleep(200 * std.time.ns_per_ms);
}

// ============================================================
// Formatting Helpers
// ============================================================

fn printTime(stderr: anytype, prefix: []const u8, ns: u64) !void {
    if (ns >= 60_000_000_000) {
        const mins = ns / 60_000_000_000;
        const secs = (ns % 60_000_000_000) / 1_000_000_000;
        try stderr.print("{s}{d}m {d}s\n", .{ prefix, mins, secs });
    } else if (ns >= 1_000_000_000) {
        try stderr.print("{s}{d}.{d:0>3} sec\n", .{ prefix, ns / 1_000_000_000, (ns % 1_000_000_000) / 1_000_000 });
    } else {
        try stderr.print("{s}{d} ms\n", .{ prefix, ns / 1_000_000 });
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

/// Non-blocking receive - uses tryRecv with 1ms timeout
fn tryRecvAndCount(client: *EngineClient) !ResponseStats {
    var stats = ResponseStats{};
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        // Use tryRecv with 1ms timeout
        const maybe_data = tcp_client.tryRecv(1) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                return stats; // Empty stats = no data
            }
            return err;
        };
        
        if (maybe_data) |raw_data| {
            if (parseMessage(raw_data, proto)) |m| {
                countMessage(&stats, m);
            }
        }
    } else if (client.udp_client) |*udp_client| {
        // UDP is already non-blocking with short timeout
        const raw_data = udp_client.recv() catch {
            return stats;
        };

        if (proto == .binary) {
            if (parseMessage(raw_data, proto)) |m| {
                countMessage(&stats, m);
            }
        } else {
            // CSV batched
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

/// Blocking drain with timeout
fn drainResponses(client: *EngineClient, timeout_ms: u32) !ResponseStats {
    var stats = ResponseStats{};
    std.time.sleep(100 * std.time.ns_per_ms);

    const start_time = timestamp.now();
    const timeout_ns: u64 = @as(u64, timeout_ms) * std.time.ns_per_ms;
    var consecutive_empty: u32 = 0;

    while (timestamp.now() - start_time < timeout_ns) {
        const packet_stats = recvAndCountMessages(client) catch |err| {
            if (err == error.Timeout or err == error.WouldBlock) {
                consecutive_empty += 1;
                if (consecutive_empty > 100) {
                    // No data for a while, slow down polling
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
                continue;
            }
            break;
        };

        if (packet_stats.total() > 0) {
            consecutive_empty = 0;
            stats.add(packet_stats);
        } else {
            consecutive_empty += 1;
        }
    }

    return stats;
}

/// Standard blocking receive
fn recvAndCountMessages(client: *EngineClient) !ResponseStats {
    var stats = ResponseStats{};
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        const raw_data = tcp_client.recv() catch |err| return err;
        if (parseMessage(raw_data, proto)) |m| {
            countMessage(&stats, m);
        }
    } else if (client.udp_client) |*udp_client| {
        const raw_data = udp_client.recv() catch |err| return err;

        if (proto == .binary) {
            if (parseMessage(raw_data, proto)) |m| {
                countMessage(&stats, m);
            }
        } else {
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
        var count: u32 = 0;
        std.time.sleep(50 * std.time.ns_per_ms);
        while (count < 20) : (count += 1) {
            const raw_data = tcp_client.recv() catch break;
            try printRawResponse(raw_data, proto, stderr);
        }
    } else if (client.udp_client) |*udp_client| {
        var count: u32 = 0;
        std.time.sleep(50 * std.time.ns_per_ms);
        while (count < 20) : (count += 1) {
            const raw_data = udp_client.recv() catch break;
            try printBatchedResponses(raw_data, proto, stderr);
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
        const pos = std.mem.indexOfScalar(u8, remaining, '\n');
        if (pos) |p| {
            if (p > 0) try printRawResponse(remaining[0 .. p + 1], proto, stderr);
            remaining = remaining[p + 1 ..];
        } else {
            if (remaining.len > 0) try printRawResponse(remaining, proto, stderr);
            break;
        }
    }
}

fn printRawResponse(raw_data: []const u8, proto: engine_client.Protocol, stderr: anytype) !void {
    if (proto == .binary and binary.isBinaryProtocol(raw_data)) {
        const msg = binary.decodeOutput(raw_data) catch |err| {
            try stderr.print("[Parse error: {s}]\n", .{@errorName(err)});
            return;
        };
        try printResponse(msg, stderr);
    } else {
        const msg = csv.parseOutput(raw_data) catch {
            try stderr.print("[RECV] {s}", .{raw_data});
            return;
        };
        try printResponse(msg, stderr);
    }
}

fn printResponse(msg: OutputMessage, stderr: anytype) !void {
    const symbol = msg.symbol[0..msg.symbol_len];
    switch (msg.msg_type) {
        .ack => try stderr.print("[RECV] A, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id }),
        .cancel_ack => try stderr.print("[RECV] C, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id }),
        .trade => try stderr.print("[RECV] T, {s}, {d}, {d}, {d}, {d}, {d}, {d}\n", .{
            symbol, msg.buy_user_id, msg.buy_order_id, msg.sell_user_id, msg.sell_order_id, msg.price, msg.quantity,
        }),
        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| @intFromEnum(s) else '-';
            try stderr.print("[RECV] B, {s}, {c}, {d}, {d}\n", .{ symbol, side_char, msg.price, msg.quantity });
        },
    }
}

test "scenario numbers valid" {
    const valid = [_]u8{ 1, 2, 3, 10, 11, 12, 20, 21, 22, 23, 24, 25 };
    for (valid) |s| _ = s;
}
