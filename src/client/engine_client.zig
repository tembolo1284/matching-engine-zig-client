//! High-level matching engine client.
//!
//! Provides a unified interface for interacting with the matching engine
//! across all transport modes (TCP, UDP) and protocols (Binary, CSV).
//! This is the main entry point for most client applications.

const std = @import("std");
const types = @import("../protocol/types.zig");
const binary = @import("../protocol/binary.zig");
const csv = @import("../protocol/csv.zig");
const tcp = @import("../transport/tcp.zig");
const udp = @import("../transport/udp.zig");

/// Wire protocol format
pub const Protocol = enum {
    /// Packed binary structs - lower latency, smaller messages
    binary,
    /// Human-readable CSV - easier debugging
    csv,
};

/// Transport mode
pub const Transport = enum {
    /// Reliable, ordered delivery with framing
    tcp,
    /// Fire-and-forget, lowest latency
    udp,
};

/// Client configuration
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 12345,
    transport: Transport = .tcp,
    protocol: Protocol = .binary,
};

/// Unified matching engine client
pub const EngineClient = struct {
    config: Config,
    tcp_client: ?tcp.TcpClient = null,
    udp_client: ?udp.UdpClient = null,
    send_buf: [types.MAX_CSV_LEN]u8 = undefined,

    const Self = @This();

    /// Create and connect a new client
    pub fn init(config: Config) !Self {
        var client = Self{ .config = config };

        switch (config.transport) {
            .tcp => {
                client.tcp_client = try tcp.TcpClient.connect(config.host, config.port);
            },
            .udp => {
                client.udp_client = try udp.UdpClient.init(config.host, config.port);
            },
        }

        return client;
    }

    /// Send a new order
    pub fn sendNewOrder(
        self: *Self,
        user_id: u32,
        symbol: []const u8,
        price: u32,
        quantity: u32,
        side: types.Side,
        order_id: u32,
    ) !void {
        std.debug.assert(symbol.len > 0 and symbol.len <= types.MAX_SYMBOL_LEN);
        std.debug.assert(quantity > 0);

        const data = switch (self.config.protocol) {
            .binary => blk: {
                const msg = types.BinaryNewOrder.init(
                    user_id,
                    symbol,
                    price,
                    quantity,
                    side,
                    order_id,
                );
                break :blk msg.asBytes();
            },
            .csv => blk: {
                const result = try csv.formatNewOrder(
                    &self.send_buf,
                    user_id,
                    symbol,
                    price,
                    quantity,
                    side,
                    order_id,
                );
                break :blk result;
            },
        };

        try self.sendRaw(data);
    }

    /// Send a cancel order request
    pub fn sendCancel(self: *Self, user_id: u32, order_id: u32) !void {
        const data = switch (self.config.protocol) {
            .binary => blk: {
                const msg = types.BinaryCancel.init(user_id, order_id);
                break :blk msg.asBytes();
            },
            .csv => blk: {
                const result = try csv.formatCancel(&self.send_buf, user_id, order_id);
                break :blk result;
            },
        };

        try self.sendRaw(data);
    }

    /// Send a flush command (cancel all orders)
    pub fn sendFlush(self: *Self) !void {
        const data = switch (self.config.protocol) {
            .binary => blk: {
                const msg = types.BinaryFlush{};
                break :blk msg.asBytes();
            },
            .csv => blk: {
                const result = try csv.formatFlush(&self.send_buf);
                break :blk result;
            },
        };

        try self.sendRaw(data);
    }

    /// Send raw bytes (for custom messages)
    pub fn sendRaw(self: *Self, data: []const u8) !void {
        if (self.tcp_client) |*client| {
            try client.send(data);
        } else if (self.udp_client) |*client| {
            try client.send(data);
        }
    }

    /// Receive the next response message (TCP only).
    /// For UDP, use multicast subscriber to receive market data.
    pub fn recv(self: *Self) !types.OutputMessage {
        if (self.tcp_client) |*client| {
            const data = try client.recv();

            // Auto-detect protocol
            if (binary.isBinaryProtocol(data)) {
                return try binary.decodeOutput(data);
            } else {
                return try csv.parseOutput(data);
            }
        }

        return error.RecvFailed;
    }

    /// Receive raw response bytes (TCP only)
    pub fn recvRaw(self: *Self) ![]const u8 {
        if (self.tcp_client) |*client| {
            return try client.recv();
        }
        return error.RecvFailed;
    }

    /// Check if connected (TCP only, UDP is connectionless)
    pub fn isConnected(self: *const Self) bool {
        if (self.tcp_client) |*client| {
            return client.isConnected();
        }
        // UDP is connectionless - consider it always "connected" to target
        return self.udp_client != null;
    }

    /// Close the client
    pub fn deinit(self: *Self) void {
        if (self.tcp_client) |*client| {
            client.close();
            self.tcp_client = null;
        }
        if (self.udp_client) |*client| {
            client.close();
            self.udp_client = null;
        }
    }
};

/// Convenience function to create a TCP binary client (most common case)
pub fn connectTcpBinary(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .tcp,
        .protocol = .binary,
    });
}

/// Convenience function to create a UDP binary client
pub fn connectUdpBinary(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .udp,
        .protocol = .binary,
    });
}

// ============================================================
// Tests
// ============================================================

test "EngineClient struct size" {
    // Keep the client reasonably sized for stack allocation
    const size = @sizeOf(EngineClient);
    try std.testing.expect(size < 50000);
}

test "Config defaults" {
    const config = Config{};
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 12345), config.port);
    try std.testing.expectEqual(Transport.tcp, config.transport);
    try std.testing.expectEqual(Protocol.binary, config.protocol);
}
