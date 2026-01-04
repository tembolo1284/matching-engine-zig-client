//! Threaded Matching Scenarios
//!
//! Uses separate sender and receiver threads for maximum throughput.
//! The sender blasts orders while the receiver continuously drains.

const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const helpers = @import("helpers.zig");

const EngineClient = @import("../client/engine_client.zig").EngineClient;
const Protocol = @import("../client/engine_client.zig").Protocol;
const TcpClient = @import("../transport/tcp.zig").TcpClient;
const timestamp = @import("../util/timestamp.zig");
const binary = @import("../protocol/binary.zig");
const proto_types = @import("../protocol/types.zig");

// ============================================================
// Shared State Between Threads
// ============================================================

const SharedState = struct {
    // Counters (atomic)
    pairs_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    messages_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    acks_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    trades_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    tob_received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    send_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    recv_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Control flags
    sender_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    receiver_should_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Target
    target_trades: u64,

    // Timing
    start_time: u64 = 0,
    send_end_time: u64 = 0,

    pub fn init(target: u64) SharedState {
        return SharedState{
            .target_trades = target,
        };
    }

    pub fn getStats(self: *SharedState) types.ResponseStats {
        return types.ResponseStats{
            .acks = self.acks_received.load(.monotonic),
            .trades = self.trades_received.load(.monotonic),
            .top_of_book = self.tob_received.load(.monotonic),
        };
    }
};

// ============================================================
// Receiver Thread
// ============================================================

fn receiverThread(tcp_client: *TcpClient, state: *SharedState, proto: Protocol) void {
    const expected_total = state.target_trades * 5; // 2 ACKs + 1 Trade + 2 TOB per pair

    while (true) {
        // Check if we should stop
        if (state.receiver_should_stop.load(.monotonic)) {
            break;
        }

        // Check if we have all messages
        const received = state.messages_received.load(.monotonic);
        if (received >= expected_total and state.sender_done.load(.monotonic)) {
            break;
        }

        // Try to receive with short timeout
        const maybe_data = tcp_client.tryRecv(1) catch |err| {
            if (err == error.Timeout or err == error.WouldBlock) {
                // No data ready, check if sender is done and we've waited enough
                if (state.sender_done.load(.monotonic)) {
                    const idle_start = timestamp.now();
                    var consecutive_empty: u32 = 0;
                    
                    // Patient drain after sender is done
                    while (consecutive_empty < 100) { // 100 * 10ms = 1 second max
                        const drain_data = tcp_client.tryRecv(10) catch {
                            consecutive_empty += 1;
                            continue;
                        };
                        
                        if (drain_data) |data| {
                            consecutive_empty = 0;
                            countResponse(data, proto, state);
                        } else {
                            consecutive_empty += 1;
                        }
                        
                        // Also check total timeout
                        if (timestamp.now() - idle_start > 5 * config.NS_PER_SEC) {
                            break;
                        }
                    }
                    break;
                }
                continue;
            }
            _ = state.recv_errors.fetchAdd(1, .monotonic);
            continue;
        };

        if (maybe_data) |data| {
            countResponse(data, proto, state);
        }
    }
}

fn countResponse(data: []const u8, proto: Protocol, state: *SharedState) void {
    _ = state.messages_received.fetchAdd(1, .monotonic);

    if (proto == .binary) {
        if (binary.decodeOutput(data)) |msg| {
            switch (msg.msg_type) {
                .ack => _ = state.acks_received.fetchAdd(1, .monotonic),
                .trade => _ = state.trades_received.fetchAdd(1, .monotonic),
                .top_of_book => _ = state.tob_received.fetchAdd(1, .monotonic),
                else => {},
            }
        } else |_| {}
    }
}

// ============================================================
// Sender Thread
// ============================================================

fn senderThread(client: *EngineClient, state: *SharedState) void {
    const target = state.target_trades;

    var i: u64 = 0;
    while (i < target) : (i += 1) {
        const price: u32 = 100 + @as(u32, @intCast(i % 50));
        const buy_oid: u32 = @intCast((i * 2 + 1) % 0xFFFFFFFF);
        const sell_oid: u32 = @intCast((i * 2 + 2) % 0xFFFFFFFF);

        // Send buy
        client.sendNewOrder(1, "IBM", price, 10, .buy, buy_oid) catch {
            _ = state.send_errors.fetchAdd(1, .monotonic);
            continue;
        };

        // Send sell
        client.sendNewOrder(1, "IBM", price, 10, .sell, sell_oid) catch {
            _ = state.send_errors.fetchAdd(1, .monotonic);
            continue;
        };

        _ = state.pairs_sent.fetchAdd(1, .monotonic);
    }

    state.send_end_time = timestamp.now();
    state.sender_done.store(true, .monotonic);
}

// ============================================================
// Main Entry Point
// ============================================================

pub fn runThreadedMatchingStress(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    const orders = trades * 2;

    // Header
    try helpers.print(stderr, "=== THREADED Matching Stress: {d} Trades ===\n\n", .{trades});
    try printTarget(stderr, trades, orders);
    try helpers.print(stderr, "Mode: Separate sender/receiver threads\n\n", .{});

    // Initial flush
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);

    // Drain any stale data
    if (client.tcp_client) |*tcp| {
        while (true) {
            const d = tcp.tryRecv(0) catch break;
            if (d == null) break;
        }
    }

    var state = SharedState.init(trades);
    state.start_time = timestamp.now();

    const tcp_ptr = &(client.tcp_client orelse return error.NotConnected);
    const proto = client.getProtocol();

    // Start receiver thread
    const receiver = std.Thread.spawn(.{}, receiverThread, .{ tcp_ptr, &state, proto }) catch |err| {
        try helpers.print(stderr, "Failed to spawn receiver thread: {s}\n", .{@errorName(err)});
        return err;
    };

    // Start sender thread
    const sender = std.Thread.spawn(.{}, senderThread, .{ client, &state }) catch |err| {
        state.receiver_should_stop.store(true, .monotonic);
        receiver.join();
        try helpers.print(stderr, "Failed to spawn sender thread: {s}\n", .{@errorName(err)});
        return err;
    };

    // Progress reporting from main thread
    const progress_points = [_]u64{ 25, 50, 75 };
    var next_progress_idx: usize = 0;

    while (!state.sender_done.load(.monotonic)) {
        std.Thread.sleep(50 * config.NS_PER_MS);

        const pairs = state.pairs_sent.load(.monotonic);
        const received = state.messages_received.load(.monotonic);

        if (next_progress_idx < progress_points.len) {
            const target_pct = progress_points[next_progress_idx];
            const current_pct = (pairs * 100) / trades;
            if (current_pct >= target_pct) {
                const elapsed_ms = (timestamp.now() - state.start_time) / config.NS_PER_MS;
                const rate: u64 = if (elapsed_ms > 0) pairs * 1000 / elapsed_ms else 0;
                try helpers.print(stderr, "  {d}% | {d} pairs sent | {d} recv'd | {d} trades/sec\n", .{
                    target_pct, pairs, received, rate,
                });
                next_progress_idx += 1;
            }
        }
    }

    // Wait for sender to finish
    sender.join();

    const send_time = state.send_end_time - state.start_time;
    const pairs_sent = state.pairs_sent.load(.monotonic);
    const orders_sent = pairs_sent * 2;

    // Report send phase
    try helpers.print(stderr, "\n=== Send Phase Complete ===\n", .{});
    try helpers.print(stderr, "Trade pairs:     {d}\n", .{pairs_sent});
    try helpers.print(stderr, "Orders sent:     {d}\n", .{orders_sent});
    try helpers.print(stderr, "Send errors:     {d}\n", .{state.send_errors.load(.monotonic)});
    try helpers.printTime(stderr, "Send time:       ", send_time);
    if (send_time > 0) {
        const send_rate: u64 = pairs_sent * config.NS_PER_SEC / send_time;
        try helpers.printThroughput(stderr, "Send rate:       ", send_rate);
    }

    // Wait for receiver to drain (with timeout)
    try helpers.print(stderr, "\n=== Waiting for receiver... ===\n", .{});
    
    const expected_total = orders_sent + pairs_sent + orders_sent;
    const drain_start = timestamp.now();
    const max_drain_time = 10 * config.NS_PER_SEC; // 10 seconds max

    while (timestamp.now() - drain_start < max_drain_time) {
        const received = state.messages_received.load(.monotonic);
        if (received >= expected_total) {
            break;
        }
        std.Thread.sleep(100 * config.NS_PER_MS);
    }

    // Signal receiver to stop and wait
    state.receiver_should_stop.store(true, .monotonic);
    receiver.join();

    const total_time = timestamp.now() - state.start_time;

    // Final results
    try helpers.print(stderr, "\n=== Final Results ===\n", .{});
    try helpers.printTime(stderr, "Total time:      ", total_time);
    if (total_time > 0) {
        const trade_rate: u64 = pairs_sent * config.NS_PER_SEC / total_time;
        try helpers.printThroughput(stderr, "Trades/sec:      ", trade_rate);
    }

    const stats = state.getStats();
    try stats.printValidation(orders_sent, pairs_sent, stderr);

    // Cleanup
    try helpers.print(stderr, "\n[FLUSH] Cleaning up server state\n", .{});
    try client.sendFlush();
    std.Thread.sleep(500 * config.NS_PER_MS);
}

// ============================================================
// Dual-Processor Threaded Version
// ============================================================

pub fn runThreadedDualProcessorStress(client: *EngineClient, stderr: std.fs.File, trades: u64) !void {
    // TODO: Implement dual-processor version
    // For now, just call single processor
    try runThreadedMatchingStress(client, stderr, trades);
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
