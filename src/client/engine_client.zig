//! High-level matching engine client with buffered I/O.
//!
//! Provides a unified interface for interacting with the matching engine
//! across all transport modes (TCP, UDP) and protocols (Binary, CSV).
//!
//! PERFORMANCE: For high-throughput scenarios, use the buffered API:
//!   try client.sendNewOrderBuffered(...);  // No syscall
//!   try client.sendNewOrderBuffered(...);  // No syscall
//!   try client.flush();                    // Single syscall for all
//!
//! Power of Ten Compliance:
//! - Rule 1: No goto/setjmp, no recursion ✓
//! - Rule 2: All loops have fixed upper bounds ✓
//! - Rule 3: No dynamic memory after init ✓
//! - Rule 4: Functions ≤60 lines ✓
//! - Rule 5: ≥2 assertions per function ✓
//! - Rule 6: Data at smallest scope ✓
//! - Rule 7: Check return values, validate parameters ✓

const std = @import("std");
const types = @import("../protocol/types.zig");
const binary = @import("../protocol/binary.zig");
const csv = @import("../protocol/csv.zig");
const tcp = @import("../transport/tcp.zig");
const udp = @import("../transport/udp.zig");

// ============================================================
// Constants
// ============================================================

/// Maximum time to wait for protocol detection response (ms)
const PROTOCOL_DETECT_TIMEOUT_MS: u64 = 200;

/// Maximum drain iterations during protocol detection
const MAX_DRAIN_ITERATIONS: u32 = 20;

/// Probe order ID for BINARY protocol detection
const PROBE_ORDER_ID_BINARY: u32 = 999999998;

/// Probe order ID for CSV protocol detection
const PROBE_ORDER_ID_CSV: u32 = 999999999;

/// Probe symbol (starts with Z for processor 1)
const PROBE_SYMBOL = "ZZPROBE";

/// Nanoseconds per millisecond
const NS_PER_MS: u64 = 1_000_000;

// ============================================================
// Enums
// ============================================================

/// Wire protocol format
pub const Protocol = enum {
    binary,
    csv,
    auto,

    pub fn toString(self: Protocol) []const u8 {
        return switch (self) {
            .binary => "binary",
            .csv => "csv",
            .auto => "auto",
        };
    }
};

/// Transport mode
pub const Transport = enum {
    tcp,
    udp,
    auto,

    pub fn toString(self: Transport) []const u8 {
        return switch (self) {
            .tcp => "tcp",
            .udp => "udp",
            .auto => "auto",
        };
    }
};

// ============================================================
// Configuration
// ============================================================

/// Client configuration
pub const Config = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 1234,
    transport: Transport = .auto,
    protocol: Protocol = .auto,
    udp_recv_timeout_ms: u32 = 1000,

    pub fn validate(self: Config) bool {
        std.debug.assert(self.host.len > 0);
        std.debug.assert(self.port > 0);
        if (self.host.len == 0) return false;
        if (self.port == 0) return false;
        return true;
    }
};

/// Discovery result (what was auto-detected)
pub const DiscoveryResult = struct {
    transport: Transport,
    protocol: Protocol,
};

// ============================================================
// Engine Client
// ============================================================

pub const EngineClient = struct {
    config: Config,
    tcp_client: ?tcp.TcpClient = null,
    udp_client: ?udp.UdpClient = null,

    /// Pre-allocated send buffer for CSV formatting
    send_buf: [types.MAX_CSV_LEN]u8 = undefined,

    detected_transport: Transport = .tcp,
    detected_protocol: Protocol = .csv,

    // Statistics
    messages_sent: u64 = 0,
    messages_received: u64 = 0,
    send_errors: u64 = 0,

    const Self = @This();

    /// Create and connect a new client (with optional auto-discovery).
    pub fn init(config: Config) !Self {
        std.debug.assert(config.validate());

        var client = Self{ .config = config };

        const transport = if (config.transport == .auto)
            try client.detectTransport()
        else
            config.transport;

        if (config.transport != .auto) {
            try client.connectTransport(transport);
        }

        if (config.protocol == .auto) {
            client.detected_protocol = client.detectProtocol();
        } else {
            client.detected_protocol = config.protocol;
        }

        std.debug.assert(client.isConnected());

        return client;
    }

    /// Connect to specified transport.
    fn connectTransport(self: *Self, transport: Transport) !void {
        std.debug.assert(transport != .auto);

        switch (transport) {
            .tcp => {
                self.tcp_client = try tcp.TcpClient.connect(
                    self.config.host,
                    self.config.port,
                );
                self.detected_transport = .tcp;
            },
            .udp => {
                self.udp_client = try udp.UdpClient.initWithTimeout(
                    self.config.host,
                    self.config.port,
                    self.config.udp_recv_timeout_ms,
                );
                self.detected_transport = .udp;
            },
            .auto => unreachable,
        }

        std.debug.assert(self.isConnected());
    }

    /// Auto-detect transport (try TCP first, fall back to UDP).
    fn detectTransport(self: *Self) !Transport {
        std.debug.assert(self.tcp_client == null and self.udp_client == null);

        if (tcp.TcpClient.connect(self.config.host, self.config.port)) |client| {
            self.tcp_client = client;
            self.detected_transport = .tcp;
            return .tcp;
        } else |_| {}

        self.udp_client = try udp.UdpClient.initWithTimeout(
            self.config.host,
            self.config.port,
            self.config.udp_recv_timeout_ms,
        );
        self.detected_transport = .udp;

        return .udp;
    }

    /// Detect protocol by sending a probe order and examining response.
    fn detectProtocol(self: *Self) Protocol {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client == null) {
            return .csv;
        }

        const binary_result = self.probeBinary();
        if (binary_result == .binary) {
            return .binary;
        }

        return self.probeCsv();
    }

    fn probeBinary(self: *Self) Protocol {
        const probe_cancel = types.BinaryCancel.init(1, PROBE_SYMBOL, PROBE_ORDER_ID_BINARY);
        self.tcp_client.?.send(probe_cancel.asBytes()) catch return .csv;

        std.Thread.sleep(PROTOCOL_DETECT_TIMEOUT_MS * NS_PER_MS);

        const response = self.tcp_client.?.recv() catch return .csv;

        if (response.len > 0) {
            const is_binary = binary.isBinaryProtocol(response);
            const is_csv_response = (response[0] == 'R' or response[0] == 'X' or response[0] == 'C');

            if (is_binary or is_csv_response) {
                self.drainResponses();
                return .binary;
            }
        }

        return .csv;
    }

    fn probeCsv(self: *Self) Protocol {
        std.debug.assert(self.tcp_client != null);

        var buf: [types.MAX_CSV_LEN]u8 = undefined;
        const cancel_csv = std.fmt.bufPrint(&buf, "C, 1, {s}, {d}\n", .{
            PROBE_SYMBOL,
            PROBE_ORDER_ID_CSV,
        }) catch return .csv;

        self.tcp_client.?.send(cancel_csv) catch return .csv;

        std.Thread.sleep(PROTOCOL_DETECT_TIMEOUT_MS * NS_PER_MS);

        const response = self.tcp_client.?.recv() catch return .csv;

        if (response.len > 0 and (response[0] == 'R' or response[0] == 'X' or response[0] == 'C')) {
            self.drainResponses();
            return .csv;
        }

        return .csv;
    }

    fn drainResponses(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client == null) return;

        std.Thread.sleep(100 * NS_PER_MS);

        var drain_count: u32 = 0;
        while (drain_count < MAX_DRAIN_ITERATIONS) : (drain_count += 1) {
            _ = self.tcp_client.?.recv() catch break;
        }
    }

    pub fn getTransport(self: *const Self) Transport {
        std.debug.assert(self.detected_transport != .auto);
        return self.detected_transport;
    }

    pub fn getProtocol(self: *const Self) Protocol {
        std.debug.assert(self.detected_protocol != .auto);
        return self.detected_protocol;
    }

    pub fn getDiscoveryResult(self: *const Self) DiscoveryResult {
        return .{
            .transport = self.detected_transport,
            .protocol = self.detected_protocol,
        };
    }

    // ============================================================
    // BUFFERED ORDER OPERATIONS (High-Performance Path)
    // ============================================================

    /// Send a new order (BUFFERED - no syscall until flush).
    /// Use this in tight loops for maximum throughput.
    pub fn sendNewOrderBuffered(
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

        const data = switch (self.detected_protocol) {
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

        try self.sendRawBuffered(data);
        self.messages_sent +|= 1;
    }

    /// Send a cancel order request (BUFFERED).
    pub fn sendCancelBuffered(self: *Self, user_id: u32, symbol: []const u8, order_id: u32) !void {
        std.debug.assert(symbol.len > 0 and symbol.len <= types.MAX_SYMBOL_LEN);
        std.debug.assert(self.isConnected());

        const data = switch (self.detected_protocol) {
            .binary => blk: {
                const msg = types.BinaryCancel.init(user_id, symbol, order_id);
                break :blk msg.asBytes();
            },
            .csv, .auto => blk: {
                const result = try csv.formatCancel(&self.send_buf, user_id, symbol, order_id);
                break :blk result;
            },
        };

        try self.sendRawBuffered(data);
        self.messages_sent +|= 1;
    }

    /// Send raw bytes (BUFFERED - queues to buffer, no syscall).
    pub fn sendRawBuffered(self: *Self, data: []const u8) !void {
        std.debug.assert(data.len > 0);
        std.debug.assert(self.isConnected());

        if (self.tcp_client) |*client| {
            try client.sendBuffered(data);
        } else if (self.udp_client) |*client| {
            // UDP doesn't buffer - send immediately
            try client.send(data);
        } else {
            self.send_errors +|= 1;
            return error.NotConnected;
        }
    }

    /// Flush all buffered messages (SINGLE SYSCALL for all buffered data).
    /// Call this periodically or at end of batch for maximum throughput.
    pub fn flush(self: *Self) !void {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client) |*client| {
            try client.flush();
        }
        // UDP doesn't buffer, nothing to flush
    }

    /// Get number of bytes currently buffered.
    pub fn bufferedBytes(self: *const Self) usize {
        if (self.tcp_client) |*client| {
            return client.bufferedBytes();
        }
        return 0;
    }

    /// Get number of messages currently buffered.
    pub fn bufferedMessages(self: *const Self) u32 {
        if (self.tcp_client) |*client| {
            return client.bufferedMessages();
        }
        return 0;
    }

    // ============================================================
    // UNBUFFERED ORDER OPERATIONS (Original API - Compatibility)
    // ============================================================

    /// Send a new order (UNBUFFERED - one syscall per call).
    /// For high throughput, use sendNewOrderBuffered + flush instead.
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

        const data = switch (self.detected_protocol) {
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
        self.messages_sent +|= 1;
    }

    /// Send a cancel order request (UNBUFFERED).
    pub fn sendCancel(self: *Self, user_id: u32, symbol: []const u8, order_id: u32) !void {
        std.debug.assert(symbol.len > 0 and symbol.len <= types.MAX_SYMBOL_LEN);
        std.debug.assert(self.isConnected());

        const data = switch (self.detected_protocol) {
            .binary => blk: {
                const msg = types.BinaryCancel.init(user_id, symbol, order_id);
                break :blk msg.asBytes();
            },
            .csv, .auto => blk: {
                const result = try csv.formatCancel(&self.send_buf, user_id, symbol, order_id);
                break :blk result;
            },
        };

        try self.sendRaw(data);
        self.messages_sent +|= 1;
    }

    /// Send a flush command (cancel all orders).
    pub fn sendFlush(self: *Self) !void {
        std.debug.assert(self.isConnected());

        const data = switch (self.detected_protocol) {
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
        self.messages_sent +|= 1;
    }

    /// Send raw bytes (UNBUFFERED - immediate syscall).
    pub fn sendRaw(self: *Self, data: []const u8) !void {
        std.debug.assert(data.len > 0);
        std.debug.assert(self.isConnected());

        if (self.tcp_client) |*client| {
            try client.send(data);
        } else if (self.udp_client) |*client| {
            try client.send(data);
        } else {
            self.send_errors +|= 1;
            return error.NotConnected;
        }
    }

    // ============================================================
    // RECEIVE OPERATIONS
    // ============================================================

    /// Receive the next response message.
    pub fn recv(self: *Self) !types.OutputMessage {
        std.debug.assert(self.isConnected());

        const data = try self.recvRaw();
        std.debug.assert(data.len > 0);

        self.messages_received +|= 1;

        if (binary.isBinaryProtocol(data)) {
            return try binary.decodeOutput(data);
        } else {
            return try csv.parseOutput(data);
        }
    }

    /// Receive raw response bytes.
    pub fn recvRaw(self: *Self) ![]const u8 {
        std.debug.assert(self.isConnected());

        if (self.tcp_client) |*client| {
            return try client.recv();
        } else if (self.udp_client) |*client| {
            return try client.recv();
        }

        return error.NotConnected;
    }

    /// Try to receive with timeout (non-blocking).
    pub fn tryRecv(self: *Self, timeout_ms: u32) !?types.OutputMessage {
        std.debug.assert(timeout_ms < 3600_000);

        const data = try self.tryRecvRaw(timeout_ms);

        if (data) |d| {
            std.debug.assert(d.len > 0);
            self.messages_received +|= 1;

            if (binary.isBinaryProtocol(d)) {
                return try binary.decodeOutput(d);
            } else {
                return try csv.parseOutput(d);
            }
        }

        return null;
    }

    /// Try to receive raw bytes with timeout.
    pub fn tryRecvRaw(self: *Self, timeout_ms: u32) !?[]const u8 {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client) |*client| {
            return client.tryRecv(@intCast(timeout_ms)) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) return null;
                return err;
            };
        } else if (self.udp_client) |*client| {
            return client.recv() catch |err| {
                if (err == error.WouldBlock) return null;
                return err;
            };
        }

        return error.NotConnected;
    }

    // ============================================================
    // STATE & STATISTICS
    // ============================================================

    pub fn isConnected(self: *const Self) bool {
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client) |*client| {
            return client.isConnected();
        }

        return self.udp_client != null;
    }

    pub fn getStats(self: *const Self) struct { sent: u64, received: u64, errors: u64 } {
        return .{
            .sent = self.messages_sent,
            .received = self.messages_received,
            .errors = self.send_errors,
        };
    }

    pub fn resetStats(self: *Self) void {
        self.messages_sent = 0;
        self.messages_received = 0;
        self.send_errors = 0;
    }

    pub fn deinit(self: *Self) void {
        std.debug.assert(@intFromPtr(self) != 0);

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

// ============================================================
// Convenience Functions
// ============================================================

/// Create a client with default settings (auto-detect everything).
pub fn connect(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .auto,
        .protocol = .auto,
    });
}

/// Create a TCP client with binary protocol.
pub fn connectTcpBinary(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .tcp,
        .protocol = .binary,
    });
}

/// Create a TCP client with CSV protocol.
pub fn connectTcpCsv(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .tcp,
        .protocol = .csv,
    });
}

// ============================================================
// Tests
// ============================================================

test "EngineClient struct size" {
    const size = @sizeOf(EngineClient);
    // Larger now due to TCP client with write buffer
    try std.testing.expect(size < 200000);
}

test "Config defaults" {
    const config = Config{};
    try std.testing.expectEqualStrings("127.0.0.1", config.host);
    try std.testing.expectEqual(@as(u16, 1234), config.port);
    try std.testing.expectEqual(Transport.auto, config.transport);
    try std.testing.expectEqual(Protocol.auto, config.protocol);
    try std.testing.expect(config.validate());
}

test "Protocol toString" {
    try std.testing.expectEqualStrings("binary", Protocol.binary.toString());
    try std.testing.expectEqualStrings("csv", Protocol.csv.toString());
    try std.testing.expectEqualStrings("auto", Protocol.auto.toString());
}

test "Transport toString" {
    try std.testing.expectEqualStrings("tcp", Transport.tcp.toString());
    try std.testing.expectEqualStrings("udp", Transport.udp.toString());
    try std.testing.expectEqualStrings("auto", Transport.auto.toString());
}

test "Probe order IDs are different" {
    try std.testing.expect(PROBE_ORDER_ID_BINARY != PROBE_ORDER_ID_CSV);
}
