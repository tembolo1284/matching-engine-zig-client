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
    transport: Transport = .tcp,
    protocol: Protocol = .binary,
    command: Command = .help,

    // Command-specific args
    user_id: u32 = 1,
    symbol: []const u8 = "IBM",
    price: u32 = 10000,
    quantity: u32 = 100,
    side: Side = .buy,
    order_id: u32 = 1,

    // Multicast args
    multicast_group: []const u8 = "239.255.0.1",
};

const Command = enum {
    help,
    send_order,
    send_cancel,
    send_flush,
    subscribe,
    benchmark,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try parseArgs();

    switch (args.command) {
        .help => printHelp(),
        .send_order => try runSendOrder(args),
        .send_cancel => try runSendCancel(args),
        .send_flush => try runSendFlush(args),
        .subscribe => try runSubscribe(args),
        .benchmark => try runBenchmark(args),
    }
}

fn parseArgs() !Args {
    var args = Args{};
    var iter = std.process.args();

    _ = iter.next(); // Skip program name

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args.command = .help;
        } else if (std.mem.eql(u8, arg, "--host")) {
            args.host = iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            const port_str = iter.next() orelse return error.MissingArgument;
            args.port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--tcp")) {
            args.transport = .tcp;
        } else if (std.mem.eql(u8, arg, "--udp")) {
            args.transport = .udp;
        } else if (std.mem.eql(u8, arg, "--binary")) {
            args.protocol = .binary;
        } else if (std.mem.eql(u8, arg, "--csv")) {
            args.protocol = .csv;
        } else if (std.mem.eql(u8, arg, "order")) {
            args.command = .send_order;
        } else if (std.mem.eql(u8, arg, "cancel")) {
            args.command = .send_cancel;
        } else if (std.mem.eql(u8, arg, "flush")) {
            args.command = .send_flush;
        } else if (std.mem.eql(u8, arg, "subscribe")) {
            args.command = .subscribe;
        } else if (std.mem.eql(u8, arg, "benchmark")) {
            args.command = .benchmark;
        } else if (std.mem.eql(u8, arg, "--symbol") or std.mem.eql(u8, arg, "-s")) {
            args.symbol = iter.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--price")) {
            const price_str = iter.next() orelse return error.MissingArgument;
            args.price = std.fmt.parseInt(u32, price_str, 10) catch return error.InvalidPrice;
        } else if (std.mem.eql(u8, arg, "--qty") or std.mem.eql(u8, arg, "-q")) {
            const qty_str = iter.next() orelse return error.MissingArgument;
            args.quantity = std.fmt.parseInt(u32, qty_str, 10) catch return error.InvalidQuantity;
        } else if (std.mem.eql(u8, arg, "--buy") or std.mem.eql(u8, arg, "-b")) {
            args.side = .buy;
        } else if (std.mem.eql(u8, arg, "--sell")) {
            args.side = .sell;
        } else if (std.mem.eql(u8, arg, "--user")) {
            const user_str = iter.next() orelse return error.MissingArgument;
            args.user_id = std.fmt.parseInt(u32, user_str, 10) catch return error.InvalidUserId;
        } else if (std.mem.eql(u8, arg, "--order-id")) {
            const oid_str = iter.next() orelse return error.MissingArgument;
            args.order_id = std.fmt.parseInt(u32, oid_str, 10) catch return error.InvalidOrderId;
        } else if (std.mem.eql(u8, arg, "--group")) {
            args.multicast_group = iter.next() orelse return error.MissingArgument;
        }
    }

    return args;
}

fn printHelp() void {
    const help =
        \\Matching Engine Zig Client
        \\
        \\USAGE:
        \\    me-client [OPTIONS] <COMMAND>
        \\
        \\COMMANDS:
        \\    order       Send a new order
        \\    cancel      Cancel an order
        \\    flush       Cancel all orders
        \\    subscribe   Subscribe to multicast market data
        \\    benchmark   Run latency benchmark
        \\
        \\CONNECTION OPTIONS:
        \\    --host <HOST>    Server host (default: 127.0.0.1)
        \\    --port <PORT>    Server port (default: 1234)
        \\    --tcp            Use TCP transport (default)
        \\    --udp            Use UDP transport
        \\    --binary         Use binary protocol (default)
        \\    --csv            Use CSV protocol
        \\
        \\ORDER OPTIONS:
        \\    --symbol <SYM>   Symbol (default: IBM)
        \\    --price <PRICE>  Price in cents (default: 10000)
        \\    --qty <QTY>      Quantity (default: 100)
        \\    --buy            Buy side (default)
        \\    --sell           Sell side
        \\    --user <ID>      User ID (default: 1)
        \\    --order-id <ID>  Order ID (default: 1)
        \\
        \\MULTICAST OPTIONS:
        \\    --group <ADDR>   Multicast group (default: 239.255.0.1)
        \\
        \\EXAMPLES:
        \\    me-client order --symbol AAPL --price 15000 --qty 50 --buy
        \\    me-client cancel --user 1 --order-id 1001
        \\    me-client subscribe --group 239.255.0.1 --port 5000
        \\    me-client benchmark --tcp --binary
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn runSendOrder(args: Args) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Connecting to {s}:{d} ({s}/{s})...\n", .{
        args.host,
        args.port,
        @tagName(args.transport),
        @tagName(args.protocol),
    });

    var client = try EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    });
    defer client.deinit();

    try stdout.print("Sending order: {s} {s} {d}@{d} (user={d}, oid={d})\n", .{
        @tagName(args.side),
        args.symbol,
        args.quantity,
        args.price,
        args.user_id,
        args.order_id,
    });

    try client.sendNewOrder(
        args.user_id,
        args.symbol,
        args.price,
        args.quantity,
        args.side,
        args.order_id,
    );

    try stdout.print("Order sent.\n", .{});

    // Try to receive response (TCP only)
    if (args.transport == .tcp) {
        try stdout.print("Waiting for response...\n", .{});
        const response = client.recv() catch |err| {
            try stdout.print("No response (error: {s})\n", .{@errorName(err)});
            return;
        };

        var buf: [256]u8 = undefined;
        const formatted = binary.formatOutput(&response, &buf);
        try stdout.print("Response: {s}\n", .{formatted});
    }
}

fn runSendCancel(args: Args) !void {
    const stdout = std.io.getStdOut().writer();

    var client = try EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    });
    defer client.deinit();

    try stdout.print("Sending cancel: user={d} order={d}\n", .{ args.user_id, args.order_id });
    try client.sendCancel(args.user_id, args.order_id);
    try stdout.print("Cancel sent.\n", .{});
}

fn runSendFlush(args: Args) !void {
    const stdout = std.io.getStdOut().writer();

    var client = try EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    });
    defer client.deinit();

    try stdout.print("Sending flush...\n", .{});
    try client.sendFlush();
    try stdout.print("Flush sent.\n", .{});
}

fn runSubscribe(args: Args) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Joining multicast group {s}:{d}...\n", .{ args.multicast_group, args.port });

    var subscriber = try MulticastSubscriber.join(args.multicast_group, args.port);
    defer subscriber.close();

    try stdout.print("Subscribed. Waiting for market data (Ctrl+C to stop)...\n\n", .{});

    var buf: [256]u8 = undefined;

    while (true) {
        const msg = subscriber.recvMessage() catch |err| {
            try stdout.print("Receive error: {s}\n", .{@errorName(err)});
            continue;
        };

        const formatted = binary.formatOutput(&msg, &buf);
        try stdout.print("{s}\n", .{formatted});
    }
}

fn runBenchmark(args: Args) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("Connecting to {s}:{d}...\n", .{ args.host, args.port });

    var client = try EngineClient.init(.{
        .host = args.host,
        .port = args.port,
        .transport = args.transport,
        .protocol = args.protocol,
    });
    defer client.deinit();

    const iterations: u32 = 10000;
    var tracker = timestamp.LatencyTracker.init();

    try stdout.print("Running {d} iterations...\n", .{iterations});

    for (0..iterations) |i| {
        const start = timestamp.now();

        try client.sendNewOrder(1, "TEST", 10000, 100, .buy, @intCast(i));

        if (args.transport == .tcp) {
            _ = client.recv() catch {};
        }

        tracker.recordSince(start);
    }

    var buf: [256]u8 = undefined;
    const stats = tracker.format(&buf);
    try stdout.print("\nResults: {s}\n", .{stats});
    try stdout.print("Throughput: {d} msg/sec\n", .{iterations * 1_000_000_000 / tracker.sum});
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
}
