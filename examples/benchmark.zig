//! Latency Benchmark Example
//!
//! Measures round-trip latency for order submission.
//! Useful for comparing TCP vs UDP and Binary vs CSV protocols.

const std = @import("std");
const me = @import("me_client");

const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 1234,
    transport: me.Transport = .tcp,
    protocol: me.Protocol = .binary,
    iterations: u32 = 10000,
    warmup: u32 = 1000,
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    const config = Config{};

    try stdout.print("=== Matching Engine Latency Benchmark ===\n\n", .{});
    try stdout.print("Configuration:\n", .{});
    try stdout.print("  Host:       {s}:{d}\n", .{ config.host, config.port });
    try stdout.print("  Transport:  {s}\n", .{@tagName(config.transport)});
    try stdout.print("  Protocol:   {s}\n", .{@tagName(config.protocol)});
    try stdout.print("  Iterations: {d}\n", .{config.iterations});
    try stdout.print("  Warmup:     {d}\n\n", .{config.warmup});

    // Connect
    try stdout.print("Connecting...\n", .{});
    var client = me.EngineClient.init(.{
        .host = config.host,
        .port = config.port,
        .transport = config.transport,
        .protocol = config.protocol,
    }) catch |err| {
        try stdout.print("Connection failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer client.deinit();

    // Warmup phase
    try stdout.print("Warming up ({d} iterations)...\n", .{config.warmup});
    for (0..config.warmup) |i| {
        try client.sendNewOrder(1, "WARM", 10000, 100, .buy, @intCast(i));
        if (config.transport == .tcp) {
            _ = client.recv() catch {};
        }
    }

    // Flush to reset state
    try client.sendFlush();
    if (config.transport == .tcp) {
        // Drain any pending responses
        for (0..100) |_| {
            _ = client.recv() catch break;
        }
    }

    // Benchmark phase
    try stdout.print("Running benchmark ({d} iterations)...\n", .{config.iterations});

    var tracker = me.timestamp.LatencyTracker.init();
    var send_tracker = me.timestamp.LatencyTracker.init();

    const start_time = me.timestamp.now();

    for (0..config.iterations) |i| {
        const iter_start = me.timestamp.now();

        // Measure send time
        const send_start = me.timestamp.now();
        try client.sendNewOrder(1, "BENCH", 10000, 100, .buy, @intCast(i));
        send_tracker.recordSince(send_start);

        // Measure full round-trip (TCP only)
        if (config.transport == .tcp) {
            _ = client.recv() catch {};
        }

        tracker.recordSince(iter_start);

        // Progress indicator
        if ((i + 1) % 1000 == 0) {
            try stdout.print("  {d}/{d}\r", .{ i + 1, config.iterations });
        }
    }

    const total_time = me.timestamp.elapsed(start_time);

    // Print results
    try stdout.print("\n\n=== Results ===\n\n", .{});

    try stdout.print("Round-trip latency:\n", .{});
    try stdout.print("  Min:    {d} ns ({d}.{d:0>3} µs)\n", .{
        tracker.minNs(),
        tracker.minNs() / 1000,
        tracker.minNs() % 1000,
    });
    try stdout.print("  Avg:    {d} ns ({d}.{d:0>3} µs)\n", .{
        tracker.avgNs(),
        tracker.avgNs() / 1000,
        tracker.avgNs() % 1000,
    });
    try stdout.print("  Max:    {d} ns ({d}.{d:0>3} µs)\n", .{
        tracker.maxNs(),
        tracker.maxNs() / 1000,
        tracker.maxNs() % 1000,
    });

    try stdout.print("\nSend latency:\n", .{});
    try stdout.print("  Min:    {d} ns\n", .{send_tracker.minNs()});
    try stdout.print("  Avg:    {d} ns\n", .{send_tracker.avgNs()});
    try stdout.print("  Max:    {d} ns\n", .{send_tracker.maxNs()});

    const throughput = if (total_time > 0)
        config.iterations * 1_000_000_000 / total_time
    else
        0;

    try stdout.print("\nThroughput:\n", .{});
    try stdout.print("  Total time: {d} ms\n", .{total_time / 1_000_000});
    try stdout.print("  Messages:   {d}/sec\n", .{throughput});

    // Protocol comparison tips
    try stdout.print("\n=== Tips ===\n", .{});
    try stdout.print("Compare protocols by running:\n", .{});
    try stdout.print("  ./benchmark --tcp --binary    (default, lowest latency)\n", .{});
    try stdout.print("  ./benchmark --tcp --csv       (human-readable)\n", .{});
    try stdout.print("  ./benchmark --udp --binary    (fire-and-forget)\n", .{});
}
