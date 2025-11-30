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
    /// Auto-detect from server response
    auto,
};

/// Transport mode
pub const Transport = enum {
    /// Reliable, ordered delivery with framing
    tcp,
    /// Fire-and-forget, lowest latency
    udp,
    /// Auto-detect: try TCP first, then UDP
    auto,
};

/// Client configuration
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 1234,
    transport: Transport = .auto,
    protocol: Protocol = .auto,
};

/// Discovery result
pub const DiscoveryResult = struct {
    transport: Transport,
    protocol: Protocol,
};

/// Unified matching engine client
pub const EngineClient = struct {
    config: Config,
    tcp_client: ?tcp.TcpClient = null,
    udp_client: ?udp.UdpClient = null,
    send_buf: [types.MAX_CSV_LEN]u8 = undefined,
    detected_transport: Transport = .tcp,
    detected_protocol: Protocol = .csv,

    const Self = @This();

    /// Create and connect a new client (with optional auto-discovery)
    pub fn init(config: Config) !Self {
        var client = Self{ .config = config };

        // Handle transport
        const transport = if (config.transport == .auto) blk: {
            // Try TCP first
            if (tcp.TcpClient.connect(config.host, config.port)) |tcp_conn| {
                client.tcp_client = tcp_conn;
                client.detected_transport = .tcp;
                break :blk Transport.tcp;
            } else |_| {
                // TCP failed, try UDP (UDP always "succeeds" as it's connectionless)
                client.udp_client = try udp.UdpClient.init(config.host, config.port);
                client.detected_transport = .udp;
                break :blk Transport.udp;
            }
        } else config.transport;

        // Connect if not already connected during auto-discovery
        if (config.transport != .auto) {
            switch (transport) {
                .tcp => {
                    client.tcp_client = try tcp.TcpClient.connect(config.host, config.port);
                    client.detected_transport = .tcp;
                },
                .udp => {
                    client.udp_client = try udp.UdpClient.init(config.host, config.port);
                    client.detected_transport = .udp;
                },
                .auto => unreachable,
            }
        }

        // Handle protocol detection
        if (config.protocol == .auto) {
            client.detected_protocol = try client.detectProtocol();
        } else {
            client.detected_protocol = if (config.protocol == .auto) .csv else config.protocol;
        }

        // Update config with detected values
        client.config.transport = client.detected_transport;
        client.config.protocol = client.detected_protocol;

        return client;
    }

    /// Detect protocol by sending a probe order and examining response
    fn detectProtocol(self: *Self) !Protocol {
        // Only works with TCP (we get responses back)
        if (self.tcp_client == null) {
            // UDP doesn't send responses back to client, default to CSV
            return .csv;
        }

        // Strategy: Send a binary order, check if we get a binary ACK back
        // Use user_id=1 (normal), and a high order_id we'll cancel immediately
        const probe_order = types.BinaryNewOrder.init(
            1,           // user_id (use 1, server assigns based on connection)
            "ZZPROBE",   // Symbol starting with Z (processor 1)
            1,           // price
            1,           // qty
            .buy,
            999999999,   // High order_id for probe
        );
        
        self.tcp_client.?.send(probe_order.asBytes()) catch {
            // If send fails, try CSV approach
            return self.detectProtocolCsv();
        };

        // Wait for response
        std.time.sleep(200 * std.time.ns_per_ms);

        // Try to receive response
        const response = self.tcp_client.?.recv() catch {
            // No response to binary - server might not understand it, try CSV
            return self.detectProtocolCsv();
        };

        // Check if response looks like binary (starts with magic byte 0x4D)
        if (response.len > 0 and binary.isBinaryProtocol(response)) {
            // Got binary response! Now send a cancel to clean up
            const cancel = types.BinaryCancel.init(1, 999999999);
            self.tcp_client.?.send(cancel.asBytes()) catch {};
            std.time.sleep(50 * std.time.ns_per_ms);
            _ = self.tcp_client.?.recv() catch {}; // Drain cancel ack
            _ = self.tcp_client.?.recv() catch {}; // Drain TOB update
            return .binary;
        }

        // Response was CSV format (or empty) - clean up with CSV cancel
        if (response.len > 0) {
            // Got a CSV response, send CSV cancel to clean up
            const cancel_csv = "C, 1, 999999999\n";
            self.tcp_client.?.send(cancel_csv) catch {};
            std.time.sleep(50 * std.time.ns_per_ms);
            _ = self.tcp_client.?.recv() catch {}; // Drain response
            _ = self.tcp_client.?.recv() catch {}; // Drain TOB
            return .csv;
        }

        return self.detectProtocolCsv();
    }

    /// Fallback CSV detection - try sending CSV order
    fn detectProtocolCsv(self: *Self) Protocol {
        if (self.tcp_client == null) return .csv;

        // Send CSV probe order
        const csv_order = "N, 1, ZZPROBE, 1, 1, B, 999999999\n";
        self.tcp_client.?.send(csv_order) catch {
            return .csv;
        };

        std.time.sleep(200 * std.time.ns_per_ms);

        const response = self.tcp_client.?.recv() catch {
            // No response at all - default to CSV
            return .csv;
        };

        // Check if response is binary (server responds in its native format)
        if (response.len > 0 and binary.isBinaryProtocol(response)) {
            // Server responded with binary to our CSV - it's a binary server
            // Clean up
            const cancel = types.BinaryCancel.init(1, 999999999);
            self.tcp_client.?.send(cancel.asBytes()) catch {};
            std.time.sleep(50 * std.time.ns_per_ms);
            _ = self.tcp_client.?.recv() catch {};
            _ = self.tcp_client.?.recv() catch {};
            return .binary;
        }

        // Got CSV response, clean up
        if (response.len > 0) {
            const cancel_csv = "C, 1, 999999999\n";
            self.tcp_client.?.send(cancel_csv) catch {};
            std.time.sleep(50 * std.time.ns_per_ms);
            _ = self.tcp_client.?.recv() catch {};
            _ = self.tcp_client.?.recv() catch {};
        }

        return .csv;
    }

    /// Get the detected/configured transport
    pub fn getTransport(self: *const Self) Transport {
        return self.detected_transport;
    }

    /// Get the detected/configured protocol
    pub fn getProtocol(self: *const Self) Protocol {
        return self.detected_protocol;
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

        const proto = self.detected_protocol;
        const data = switch (proto) {
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
            .csv, .auto => blk: {
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
        const proto = self.detected_protocol;
        const data = switch (proto) {
            .binary => blk: {
                const msg = types.BinaryCancel.init(user_id, order_id);
                break :blk msg.asBytes();
            },
            .csv, .auto => blk: {
                const result = try csv.formatCancel(&self.send_buf, user_id, order_id);
                break :blk result;
            },
        };

        try self.sendRaw(data);
    }

    /// Send a flush command (cancel all orders)
    pub fn sendFlush(self: *Self) !void {
        const proto = self.detected_protocol;
        const data = switch (proto) {
            .binary => blk: {
                const msg = types.BinaryFlush{};
                break :blk msg.asBytes();
            },
            .csv, .auto => blk: {
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
    try std.testing.expectEqual(@as(u16, 1234), config.port);
    try std.testing.expectEqual(Transport.auto, config.transport);
    try std.testing.expectEqual(Protocol.auto, config.protocol);
}
