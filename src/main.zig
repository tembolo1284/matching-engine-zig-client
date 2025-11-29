//! Matching Engine Zig Client
//!
//! A cross-platform client for the high-performance matching engine.
//! Supports TCP, UDP, and Multicast transports with both Binary and CSV protocols.

const std = @import("std");

// Re-export public API
pub const types = @import("protocol/types.zig");
pub const binary = @import("protocol/binary.zig");
pub const csv = @import("protocol/csv.zig");
pub const framing = @import("protocol/framing.zig");

pub const socket = @import("transport/socket.zig");
pub const tcp = @import("transport/tcp.zig");
pub const udp = @import("transport/udp.zig");
pub const multicast = @import("transport/multicast.zig");

pub const engine_client = @import("client/engine_client.zig");
pub const order_builder = @import("client/order_builder.zig");

pub const pool = @import("memory/pool.zig");
pub const ring_buffer = @import("memory/ring_buffer.zig");

pub const timestamp = @import("util/timestamp.zig");
pub const scenarios = @import("scenarios.zig");

// Convenience re-exports
pub const EngineClient = engine_client.EngineClient;
pub const Config = engine_client.Config;
pub const Protocol = engine_client.Protocol;
pub const Transport = engine_client.Transport;
pub const Side = types.Side;
pub const OutputMessage = types.OutputMessage;
pub const MulticastSubscriber = multicast.MulticastSubscriber;

/// Connect to matching engine with TCP/binary (most common case)
pub const connectTcpBinary = engine_client.connectTcpBinary;

/// Connect to matching engine with UDP/binary
pub const connectUdpBinary = engine_client.connectUdpBinary;

/// Start building an order with fluent API
pub const order = order_builder.order;

// ============================================================
// CLI Entry Point
// ============================================================

const Args = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 1234,
    transport: Transport = .auto,  // Auto-detect by default
    protocol: Protocol = .auto,    // Auto-detect by default
    command: Command = .interactive,

    // Scenario number (1, 2, 3, or 0 for interactive)
    scenario: u8 = 0,

    // Multicast args
    multicast_group: []const u8 = "239.255.0.1",
};

const Command = enum {
    help,
    interactive,
    scenario,
    subscribe,
    benchmark,
};

pub fn main() !void {
    const args = parseArgs();

    switch (args.command) {
        .help => printHelp(),
        .interactive => try runInteractive(args),
        .scenario => try runScenario(args),
        .subscribe => try runSubscribe(args),
        .benchmark => try runBenchmark(args),
    }
}

fn parseArgs() Args {
    var args = Args{};
    var iter = std.process.args();

    _ = iter.next(); // Skip program name

    var positional_index: u8 = 0; // Track which positional arg we're on

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.command = .help;
            return args;
        } else if (std.mem.eql(u8, arg, "--tcp")) {
            args.transport = .tcp;
        } else if (std.mem.eql(u8, arg, "--udp")) {
            args.transport = .udp;
        } else if (std.mem.eql(u8, arg, "--binary")) {
            args.protocol = .binary;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            args.protocol = .csv;
        } else if (std.mem.eql(u8, arg, "subscribe")) {
            args.command = .subscribe;
            // Parse multicast group and port from remaining args
            if (iter.next()) |group| {
                args.multicast_group = group;
            }
            if (iter.next()) |port_str| {
                args.port = std.fmt.parseInt(u16, port_str, 10) catch 5000;
            }
            return args;
        } else if (std.mem.eql(u8, arg, "benchmark")) {
            args.command = .benchmark;
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (iter.next()) |host| {
                args.host = host;
            }
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (iter.next()) |port_str| {
                args.port = std.fmt.parseInt(u16, port_str, 10) catch 1234;
            }
        } else if (arg[0] != '-') {
            // Positional arguments: [host] [port] [scenario]
            if (positional_index == 0) {
                // First positional: host (or could be just scenario if only one arg)
                if (std.fmt.parseInt(u16, arg, 10)) |_| {
                    // It's a number - if only arg, treat as scenario
                    // But we don't know yet, so treat as host for now
                    args.host = arg;
                } else |_| {
                    // Not a number - definitely host
                    if (std.mem.eql(u8, arg, "i") or std.mem.eql(u8, arg, "interactive")) {
                        args.command = .interactive;
                    } else {
                        args.host = arg;
                    }
                }
                positional_index += 1;
            } else if (positional_index == 1) {
                // Second positional: port
                args.port = std.fmt.parseInt(u16, arg, 10) catch 1234;
                positional_index += 1;
            } else if (positional_index == 2) {
                // Third positional: scenario
                if (std.mem.eql(u8, arg, "i") or std.mem.eql(u8, arg, "interactive")) {
                    args.command = .interactive;
                } else if (std.fmt.parseInt(u8, arg, 10)) |scenario| {
                    args.scenario = scenario;
                    args.command = .scenario;
                } else |_| {}
                positional_index += 1;
            }
        }
    }

    return args;
}

fn printHelp() void {
    const stderr = std.io.getStdErr().writer();
    const help =
        \\Matching Engine Zig Client
        \\
        \\Usage: me-client [OPTIONS] [host] [port] [scenario]
        \\
        \\Arguments:
        \\  host      Server host (default: 127.0.0.1)
        \\  port      Server port (default: 1234)
        \\  scenario  Test scenario number, or 'i' for interactive (default)
        \\
        \\Options:
        \\  --tcp     Force TCP transport (auto-detects by default)
        \\  --udp     Force UDP transport
        \\  --binary  Force binary protocol (auto-detects by default)
        \\  --csv     Force CSV protocol
        \\  --host    Server host
        \\  --port    Server port
        \\  -h, --help Show this help
        \\
        \\Auto-Detection:
        \\  By default, the client auto-detects transport and protocol:
        \\  1. Tries TCP first, falls back to UDP if TCP fails
        \\  2. Sends probe to detect CSV vs Binary protocol
        \\
        \\Basic Scenarios:
        \\  1  - Simple orders (buy + sell at different prices + flush)
        \\  2  - Matching trade (buy + sell at same price)
        \\  3  - Cancel order
        \\
        \\Stress Test Scenarios:
        \\  10 - Stress test: 1K orders
        \\  11 - Stress test: 10K orders
        \\  12 - Stress test: 100K orders
        \\  13 - Stress test: 1M orders
        \\  14 - Stress test: 10M orders  ** EXTREME **
        \\  20 - Matching stress: 1K trade pairs
        \\  21 - Matching stress: 10K trade pairs
        \\  30 - Multi-symbol stress: 10K orders
        \\  40 - Burst mode: 100K (no throttling)
        \\  41 - Burst mode: 1M (no throttling)
        \\
        \\Examples:
        \\  me-client localhost 1234            # Auto-detect, interactive
        \\  me-client localhost 1234 1          # Auto-detect, scenario 1
        \\  me-client --tcp localhost 1234      # Force TCP
        \\  me-client --udp localhost 1234      # Force UDP
        \\
        \\Interactive Commands:
        \\  buy SYMBOL PRICE QTY [ORDER_ID]
        \\  sell SYMBOL PRICE QTY [ORDER_ID]
        \\  cancel ORDER_ID
        \\  flush
        \\  quit / exit
        \\
    ;
    stderr.print("{s}", .{help}) catch {};
}

// ============================================================
// Interactive Mode (like tcp_client.c)
// ============================================================

fn runInteractive(args: Args) !void {
    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();

    // Show what we're trying
    if (args.transport == .auto) {
        try stderr.print("Auto-detecting server at {s}:{d}...\n", .{ args.host, args.port });
    } else {
        try stderr.print("Connecting to {s}:{d}...\n", .{ args.host, args.port });
    }

    var client = EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    }) catch |err| {
        try stderr.print("Connection failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer client.deinit();

    // Show what we detected/connected with
    const transport_str = switch (client.getTransport()) {
        .tcp => "tcp",
        .udp => "udp",
        .auto => "auto",
    };
    const protocol_str = switch (client.getProtocol()) {
        .csv => "csv",
        .binary => "binary",
        .auto => "auto",
    };

    try stderr.print("Connected to {s}:{d} ({s}/{s})\n", .{
        args.host,
        args.port,
        transport_str,
        protocol_str,
    });

    if (args.transport == .auto or args.protocol == .auto) {
        try stderr.print("(auto-detected)\n", .{});
    }
    try stderr.print("\n", .{});

    try stderr.print("=== Interactive Mode ===\n", .{});
    try stderr.print("Commands:\n", .{});
    try stderr.print("  buy SYMBOL PRICE QTY [ORDER_ID]\n", .{});
    try stderr.print("  sell SYMBOL PRICE QTY [ORDER_ID]\n", .{});
    try stderr.print("  cancel ORDER_ID\n", .{});
    try stderr.print("  flush\n", .{});
    try stderr.print("  quit\n\n", .{});

    var line_buf: [1024]u8 = undefined;
    var order_id: u32 = 1;

    while (true) {
        try stderr.print("> ", .{});

        const line = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| {
            try stderr.print("Read error: {s}\n", .{@errorName(err)});
            break;
        } orelse break;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Parse command
        if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit")) {
            break;
        } else if (std.mem.eql(u8, trimmed, "flush") or std.mem.eql(u8, trimmed, "F")) {
            try stderr.print("→ FLUSH\n", .{});
            client.sendFlush() catch |err| {
                try stderr.print("Send error: {s}\n", .{@errorName(err)});
                continue;
            };
            try recvAndPrintResponses(&client, stderr);
        } else if (std.mem.startsWith(u8, trimmed, "buy ")) {
            if (parseBuySell(trimmed[4..], &order_id)) |parsed| {
                try stderr.print("→ BUY {s} {d}@{d} (order {d})\n", .{
                    parsed.symbol,
                    parsed.qty,
                    parsed.price,
                    parsed.order_id,
                });
                client.sendNewOrder(1, parsed.symbol, parsed.price, parsed.qty, .buy, parsed.order_id) catch |err| {
                    try stderr.print("Send error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try recvAndPrintResponses(&client, stderr);
            } else {
                try stderr.print("Usage: buy SYMBOL PRICE QTY [ORDER_ID]\n", .{});
            }
        } else if (std.mem.startsWith(u8, trimmed, "sell ")) {
            if (parseBuySell(trimmed[5..], &order_id)) |parsed| {
                try stderr.print("→ SELL {s} {d}@{d} (order {d})\n", .{
                    parsed.symbol,
                    parsed.qty,
                    parsed.price,
                    parsed.order_id,
                });
                client.sendNewOrder(1, parsed.symbol, parsed.price, parsed.qty, .sell, parsed.order_id) catch |err| {
                    try stderr.print("Send error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try recvAndPrintResponses(&client, stderr);
            } else {
                try stderr.print("Usage: sell SYMBOL PRICE QTY [ORDER_ID]\n", .{});
            }
        } else if (std.mem.startsWith(u8, trimmed, "cancel ")) {
            if (parseCancel(trimmed[7..])) |oid| {
                try stderr.print("→ CANCEL order {d}\n", .{oid});
                client.sendCancel(1, oid) catch |err| {
                    try stderr.print("Send error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try recvAndPrintResponses(&client, stderr);
            } else {
                try stderr.print("Usage: cancel ORDER_ID\n", .{});
            }
        } else {
            try stderr.print("Unknown command. Type 'quit' to exit.\n", .{});
        }
    }

    try stderr.print("\n=== Disconnecting ===\n", .{});
}

const ParsedOrder = struct {
    symbol: []const u8,
    price: u32,
    qty: u32,
    order_id: u32,
};

fn parseBuySell(input: []const u8, auto_order_id: *u32) ?ParsedOrder {
    var iter = std.mem.tokenizeAny(u8, input, " \t");

    const symbol = iter.next() orelse return null;
    if (symbol.len > 8) return null;

    const price_str = iter.next() orelse return null;
    const price = std.fmt.parseInt(u32, price_str, 10) catch return null;

    const qty_str = iter.next() orelse return null;
    const qty = std.fmt.parseInt(u32, qty_str, 10) catch return null;

    // Optional order_id
    const order_id = if (iter.next()) |oid_str|
        std.fmt.parseInt(u32, oid_str, 10) catch auto_order_id.*
    else blk: {
        const oid = auto_order_id.*;
        auto_order_id.* += 1;
        break :blk oid;
    };

    return ParsedOrder{
        .symbol = symbol,
        .price = price,
        .qty = qty,
        .order_id = order_id,
    };
}

fn parseCancel(input: []const u8) ?u32 {
    const trimmed = std.mem.trim(u8, input, " \t");
    return std.fmt.parseInt(u32, trimmed, 10) catch null;
}

fn recvAndPrintResponses(client: *EngineClient, stderr: anytype) !void {
    // For TCP, try to receive responses
    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        const max_responses: u32 = 20; // Allow more responses

        // Give the server a moment to send all responses
        std.time.sleep(50 * std.time.ns_per_ms);

        while (response_count < max_responses) {
            const raw_data = tcp_client.recv() catch |err| {
                // After receiving at least one response, timeout is normal
                if (response_count > 0) break;
                // No response at all
                if (err == error.Timeout) {
                    try stderr.print("[No response - timeout]\n", .{});
                }
                break;
            };

            // Parse the response based on detected protocol
            const proto = client.getProtocol();
            if (proto == .binary) {
                if (binary.isBinaryProtocol(raw_data)) {
                    const msg = binary.decodeOutput(raw_data) catch |err| {
                        try stderr.print("[Parse error: {s}]\n", .{@errorName(err)});
                        response_count += 1;
                        continue;
                    };
                    try printResponse(msg, stderr);
                } else {
                    // Unexpected non-binary response
                    try stderr.print("[RECV] {s}\n", .{raw_data});
                }
            } else {
                // CSV protocol (or auto) - parse or just print raw
                const msg = csv.parseOutput(raw_data) catch {
                    // Just print raw if parse fails
                    try stderr.print("[RECV] {s}", .{raw_data});
                    if (raw_data.len > 0 and raw_data[raw_data.len - 1] != '\n') {
                        try stderr.print("\n", .{});
                    }
                    response_count += 1;
                    continue;
                };
                try printResponse(msg, stderr);
            }
            response_count += 1;
        }
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
// Test Scenarios (delegated to scenarios.zig)
// ============================================================

fn runScenario(args: Args) !void {
    const stderr = std.io.getStdErr().writer();

    // Show what we're trying
    if (args.transport == .auto) {
        try stderr.print("Auto-detecting server at {s}:{d}...\n", .{ args.host, args.port });
    } else {
        try stderr.print("Connecting to {s}:{d}...\n", .{ args.host, args.port });
    }

    var client = EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    }) catch |err| {
        try stderr.print("Connection failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer client.deinit();

    // Show what we detected/connected with
    const transport_str = switch (client.getTransport()) {
        .tcp => "tcp",
        .udp => "udp",
        .auto => "auto",
    };
    const protocol_str = switch (client.getProtocol()) {
        .csv => "csv",
        .binary => "binary",
        .auto => "auto",
    };

    try stderr.print("Connected ({s}/{s})", .{ transport_str, protocol_str });
    if (args.transport == .auto or args.protocol == .auto) {
        try stderr.print(" [auto-detected]", .{});
    }
    try stderr.print("\n\n", .{});

    scenarios.run(&client, args.scenario, stderr) catch |err| {
        if (err == error.UnknownScenario) {
            try stderr.print("\nUnknown scenario: {d}\n", .{args.scenario});
        } else {
            return err;
        }
        return;
    };

    try stderr.print("\n=== Disconnecting ===\n", .{});
}

// ============================================================
// Multicast Subscriber
// ============================================================

fn runSubscribe(args: Args) !void {
    const stderr = std.io.getStdErr().writer();

    try stderr.print("Joining multicast group {s}:{d}...\n", .{ args.multicast_group, args.port });

    var subscriber = MulticastSubscriber.join(args.multicast_group, args.port) catch |err| {
        try stderr.print("Failed to join multicast: {s}\n", .{@errorName(err)});
        return;
    };
    defer subscriber.close();

    try stderr.print("Subscribed. Waiting for market data (Ctrl+C to stop)...\n\n", .{});

    while (true) {
        const msg = subscriber.recvMessage() catch |err| {
            try stderr.print("Receive error: {s}\n", .{@errorName(err)});
            continue;
        };

        try printResponse(msg, stderr);
    }
}

// ============================================================
// Benchmark
// ============================================================

fn runBenchmark(args: Args) !void {
    const stderr = std.io.getStdErr().writer();

    try stderr.print("Connecting to {s}:{d}...\n", .{ args.host, args.port });

    var client = EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    }) catch |err| {
        try stderr.print("Connection failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer client.deinit();

    const iterations: u32 = 10000;
    var tracker = timestamp.LatencyTracker.init();

    try stderr.print("Running {d} iterations...\n", .{iterations});

    for (0..iterations) |i| {
        const start = timestamp.now();

        try client.sendNewOrder(1, "TEST", 10000, 100, .buy, @intCast(i));

        if (client.tcp_client != null) {
            _ = client.recv() catch {};
        }

        tracker.recordSince(start);
    }

    var buf: [256]u8 = undefined;
    const stats = tracker.format(&buf);
    try stderr.print("\nResults: {s}\n", .{stats});
    const throughput: u64 = if (tracker.sum > 0) @as(u64, iterations) * 1_000_000_000 / tracker.sum else 0;
    try stderr.print("Throughput: {d} msg/sec\n", .{throughput});
}

// ============================================================
// Tests - run with `zig build test`
// ============================================================

test {
    // Run all module tests
    _ = types;
    _ = binary;
    _ = csv;
    _ = framing;
    _ = socket;
    _ = tcp;
    _ = udp;
    _ = multicast;
    _ = engine_client;
    _ = order_builder;
    _ = pool;
    _ = ring_buffer;
    _ = timestamp;
    _ = scenarios;
}
