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
pub const scenarios = @import("scenarios/mod.zig");
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
    transport: Transport = .auto, // Auto-detect by default
    protocol: Protocol = .auto, // Auto-detect by default
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
// ============================================================
// Helper Functions for Zig 0.15 IO
// ============================================================
/// Helper for formatted printing to a File
fn print(file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, fmt, args);
    try file.writeAll(msg);
}
/// Read a line from a file, stripping the newline.
fn readLine(file: std.fs.File, buf: []u8) !?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const bytes_read = file.read(buf[i .. i + 1]) catch |err| return err;
        if (bytes_read == 0) {
            if (i == 0) return null;
            return buf[0..i];
        }
        if (buf[i] == '\n') {
            return buf[0..i];
        }
        i += 1;
    }
    return buf[0..i];
}
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
    const stderr = std.fs.File.stderr();
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
        \\  20 - Matching stress: 1K trades
        \\  21 - Matching stress: 10K trades
        \\  22 - Matching stress: 100K trades
        \\  23 - Matching stress: 250K trades
        \\  24 - Matching stress: 500K trades
        \\  25 - Matching stress: 250M trades ★★★ LEGENDARY ★★★
        \\  30 - Dual-processor: 500K trades (IBM + NVDA)
        \\  31 - Dual-processor: 1M trades
        \\  32 - Dual-processor: 100M trades ★★★ ULTIMATE ★★★
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
        \\  cancel SYMBOL ORDER_ID
        \\  flush
        \\  quit / exit
        \\
    ;
    stderr.writeAll(help) catch {};
}
// ============================================================
// Interactive Mode (like tcp_client.c)
// ============================================================
fn runInteractive(args: Args) !void {
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();
    // Show what we're trying
    if (args.transport == .auto) {
        try print(stderr, "Auto-detecting server at {s}:{d}...\n", .{ args.host, args.port });
    } else {
        try print(stderr, "Connecting to {s}:{d}...\n", .{ args.host, args.port });
    }
    var client = EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    }) catch |err| {
        try print(stderr, "Connection failed: {s}\n", .{@errorName(err)});
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
    try print(stderr, "Connected to {s}:{d} ({s}/{s})\n", .{
        args.host,
        args.port,
        transport_str,
        protocol_str,
    });
    if (args.transport == .auto or args.protocol == .auto) {
        try stderr.writeAll("(auto-detected)\n");
    }
    try stderr.writeAll("\n");
    try stderr.writeAll("=== Interactive Mode ===\n");
    try stderr.writeAll("Commands:\n");
    try stderr.writeAll("  buy SYMBOL PRICE QTY [ORDER_ID]\n");
    try stderr.writeAll("  sell SYMBOL PRICE QTY [ORDER_ID]\n");
    try stderr.writeAll("  cancel SYMBOL ORDER_ID\n");
    try stderr.writeAll("  flush\n");
    try stderr.writeAll("  quit\n\n");
    var line_buf: [1024]u8 = undefined;
    var order_id: u32 = 1;
    while (true) {
        try stderr.writeAll("> ");
        const line = readLine(stdin, &line_buf) catch |err| {
            try print(stderr, "Read error: {s}\n", .{@errorName(err)});
            break;
        } orelse break;
        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        // Parse command
        if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit")) {
            break;
        } else if (std.mem.eql(u8, trimmed, "flush") or std.mem.eql(u8, trimmed, "F")) {
            try stderr.writeAll("→ FLUSH\n");
            client.sendFlush() catch |err| {
                try print(stderr, "Send error: {s}\n", .{@errorName(err)});
                continue;
            };
            try recvAndPrintResponses(&client, stderr);
        } else if (std.mem.startsWith(u8, trimmed, "buy ")) {
            if (parseBuySell(trimmed[4..], &order_id)) |parsed| {
                try print(stderr, "→ BUY {s} {d}@{d} (order {d})\n", .{
                    parsed.symbol,
                    parsed.qty,
                    parsed.price,
                    parsed.order_id,
                });
                client.sendNewOrder(1, parsed.symbol, parsed.price, parsed.qty, .buy, parsed.order_id) catch |err| {
                    try print(stderr, "Send error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try recvAndPrintResponses(&client, stderr);
            } else {
                try stderr.writeAll("Usage: buy SYMBOL PRICE QTY [ORDER_ID]\n");
            }
        } else if (std.mem.startsWith(u8, trimmed, "sell ")) {
            if (parseBuySell(trimmed[5..], &order_id)) |parsed| {
                try print(stderr, "→ SELL {s} {d}@{d} (order {d})\n", .{
                    parsed.symbol,
                    parsed.qty,
                    parsed.price,
                    parsed.order_id,
                });
                client.sendNewOrder(1, parsed.symbol, parsed.price, parsed.qty, .sell, parsed.order_id) catch |err| {
                    try print(stderr, "Send error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try recvAndPrintResponses(&client, stderr);
            } else {
                try stderr.writeAll("Usage: sell SYMBOL PRICE QTY [ORDER_ID]\n");
            }
        } else if (std.mem.startsWith(u8, trimmed, "cancel ")) {
            if (parseCancel(trimmed[7..])) |parsed| {
                try print(stderr, "→ CANCEL {s} order {d}\n", .{ parsed.symbol, parsed.order_id });
                client.sendCancel(1, parsed.symbol, parsed.order_id) catch |err| {
                    try print(stderr, "Send error: {s}\n", .{@errorName(err)});
                    continue;
                };
                try recvAndPrintResponses(&client, stderr);
            } else {
                try stderr.writeAll("Usage: cancel SYMBOL ORDER_ID\n");
            }
        } else {
            try stderr.writeAll("Unknown command. Type 'quit' to exit.\n");
        }
    }
    try stderr.writeAll("\n=== Disconnecting ===\n");
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
const ParsedCancel = struct {
    symbol: []const u8,
    order_id: u32,
};
fn parseCancel(input: []const u8) ?ParsedCancel {
    var iter = std.mem.tokenizeAny(u8, input, " \t");
    const symbol = iter.next() orelse return null;
    if (symbol.len == 0 or symbol.len > 8) return null;
    const oid_str = iter.next() orelse return null;
    const order_id = std.fmt.parseInt(u32, oid_str, 10) catch return null;
    return ParsedCancel{
        .symbol = symbol,
        .order_id = order_id,
    };
}
fn recvAndPrintResponses(client: *EngineClient, stderr: std.fs.File) !void {
    const proto = client.getProtocol();
    // Handle TCP responses
    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        const max_responses: u32 = 20;
        // Give the server a moment to send all responses
        std.Thread.sleep(50 * 1_000_000);
        while (response_count < max_responses) {
            const raw_data = tcp_client.recv() catch |err| {
                if (response_count > 0) break;
                if (err == error.Timeout) {
                    try stderr.writeAll("[No response - timeout]\n");
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
        // Give server time to respond
        std.Thread.sleep(50 * 1_000_000);
        while (response_count < max_responses) {
            const raw_data = udp_client.recv() catch {
                // For UDP, timeout/no data is normal after getting responses
                break;
            };
            try printRawResponse(raw_data, proto, stderr);
            response_count += 1;
        }
        if (response_count == 0) {
            try stderr.writeAll("[No UDP response received]\n");
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
        // CSV protocol (or auto) - parse or just print raw
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
fn printResponse(msg: OutputMessage, stderr: std.fs.File) !void {
    const symbol = msg.symbol[0..msg.symbol_len];
    switch (msg.msg_type) {
        .ack => {
            try print(stderr, "[RECV] A, {s}, {d}, {d}\n", .{
                symbol,
                msg.user_id,
                msg.order_id,
            });
        },
        .cancel_ack => {
            try print(stderr, "[RECV] C, {s}, {d}, {d}\n", .{
                symbol,
                msg.user_id,
                msg.order_id,
            });
        },
        .trade => {
            try print(stderr, "[RECV] T, {s}, {d}, {d}, {d}, {d}, {d}.{d:0>2}, {d}\n", .{
                symbol,
                msg.buy_user_id,
                msg.buy_order_id,
                msg.sell_user_id,
                msg.sell_order_id,
                msg.price / 100,
                msg.price % 100,
                msg.quantity,
            });
        },
        .reject => {
            try print(stderr, "[RECV] R, {s}, {d}, {d}, {d}\n", .{
                symbol,
                msg.user_id,
                msg.order_id,
                msg.reject_reason,
            });
        },
        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| @intFromEnum(s) else '-';
            if (msg.price == 0 and msg.quantity == 0) {
                try print(stderr, "[RECV] B, {s}, {c}, -, -\n", .{
                    symbol,
                    side_char,
                });
            } else {
                try print(stderr, "[RECV] B, {s}, {c}, {d}, {d}\n", .{
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
// Test Scenarios (delegated to scenarios module)
// ============================================================
fn runScenario(args: Args) !void {
    const stderr = std.fs.File.stderr();
    // Show what we're trying
    try print(stderr, "Connecting to {s}:{d}...\n", .{ args.host, args.port });
    var client = EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    }) catch |err| {
        try print(stderr, "Connection failed: {s}\n", .{@errorName(err)});
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
    try print(stderr, "Connected ({s}/{s})\n", .{ transport_str, protocol_str });
    // Run the scenario
    scenarios.run(&client, args.scenario, stderr) catch |err| {
        if (err == error.UnknownScenario) {
            try print(stderr, "\nUnknown scenario: {d}\n", .{args.scenario});
            try scenarios.printAvailableScenarios(stderr);
        } else {
            return err;
        }
        return;
    };
    try stderr.writeAll("\n=== Disconnecting ===\n");
}
// ============================================================
// Multicast Subscriber
// ============================================================
fn runSubscribe(args: Args) !void {
    const stderr = std.fs.File.stderr();
    try print(stderr, "Joining multicast group {s}:{d}...\n", .{ args.multicast_group, args.port });
    var subscriber = MulticastSubscriber.join(args.multicast_group, args.port) catch |err| {
        try print(stderr, "Failed to join multicast: {s}\n", .{@errorName(err)});
        return;
    };
    defer subscriber.close();
    try stderr.writeAll("Subscribed. Waiting for market data (Ctrl+C to stop)...\n\n");
    while (true) {
        const msg = subscriber.recvMessage() catch |err| {
            try print(stderr, "Receive error: {s}\n", .{@errorName(err)});
            continue;
        };
        try printResponse(msg, stderr);
    }
}
// ============================================================
// Benchmark
// ============================================================
fn runBenchmark(args: Args) !void {
    const stderr = std.fs.File.stderr();
    try print(stderr, "Connecting to {s}:{d}...\n", .{ args.host, args.port });
    var client = EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    }) catch |err| {
        try print(stderr, "Connection failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer client.deinit();
    const iterations: u32 = 10000;
    var tracker = timestamp.LatencyTracker.init();
    try print(stderr, "Running {d} iterations...\n", .{iterations});
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
    try print(stderr, "\nResults: {s}\n", .{stats});
    const throughput: u64 = if (tracker.sum > 0) @as(u64, iterations) * 1_000_000_000 / tracker.sum else 0;
    try print(stderr, "Throughput: {d} msg/sec\n", .{throughput});
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
