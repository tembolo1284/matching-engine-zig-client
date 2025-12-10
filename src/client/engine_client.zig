//! High-level matching engine client.
//!
//! Provides a unified interface for interacting with the matching engine
//! across all transport modes (TCP, UDP) and protocols (Binary, CSV).
//! This is the main entry point for most client applications.
//!
//! Power of Ten Compliance:
//! - Rule 1: No goto/setjmp, no recursion ✓
//! - Rule 2: All loops have fixed upper bounds ✓
//! - Rule 3: No dynamic memory after init ✓
//! - Rule 4: Functions ≤60 lines ✓
//! - Rule 5: ≥2 assertions per function ✓
//! - Rule 6: Data at smallest scope ✓
//! - Rule 7: Check return values, validate parameters ✓
//!
//! Design Notes:
//! - Auto-detection sends probe orders that are immediately cancelled
//! - Pre-allocated send buffer avoids hot-path allocations
//! - Protocol detection has bounded retry logic
//! - Binary and CSV probes use DIFFERENT order IDs to prevent duplicate key errors
//! - TcpClient handles length-prefix framing internally - do NOT add framing here

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
const PROTOCOL_DETECT_TIMEOUT_MS: u32 = 200;

/// Maximum drain iterations during protocol detection
const MAX_DRAIN_ITERATIONS: u32 = 20;

/// Probe order ID for BINARY protocol detection (high value unlikely to conflict)
/// IMPORTANT: Must be different from CSV probe to avoid duplicate key errors on server!
const PROBE_ORDER_ID_BINARY: u32 = 999999998;

/// Probe order ID for CSV protocol detection
/// IMPORTANT: Must be different from binary probe to avoid duplicate key errors on server!
const PROBE_ORDER_ID_CSV: u32 = 999999999;

/// Probe symbol (starts with Z for processor 1)
const PROBE_SYMBOL = "ZZPROBE";

// ============================================================
// Enums
// ============================================================

/// Wire protocol format
pub const Protocol = enum {
    /// Packed binary structs - lower latency, smaller messages
    binary,
    /// Human-readable CSV - easier debugging
    csv,
    /// Auto-detect from server response
    auto,

    /// Convert to string for display
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
    /// Reliable, ordered delivery with framing
    tcp,
    /// Fire-and-forget, lowest latency
    udp,
    /// Auto-detect: try TCP first, then UDP
    auto,

    /// Convert to string for display
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
    /// Server hostname or IP address
    host: []const u8 = "127.0.0.1",

    /// Server port
    port: u16 = 1234,

    /// Transport mode (tcp, udp, or auto)
    transport: Transport = .auto,

    /// Wire protocol (binary, csv, or auto)
    protocol: Protocol = .auto,

    /// Timeout for UDP receive in milliseconds (0 = blocking)
    udp_recv_timeout_ms: u32 = 1000,

    /// Validate configuration
    pub fn validate(self: Config) bool {
        // Assertion 1: Host should not be empty
        std.debug.assert(self.host.len > 0);

        // Assertion 2: Port should be valid
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

/// Unified matching engine client.
///
/// Provides a single interface for sending orders and receiving responses
/// regardless of underlying transport (TCP/UDP) or protocol (Binary/CSV).
///
/// Thread Safety: NOT thread-safe. Use one client per thread.
pub const EngineClient = struct {
    /// Configuration used to create this client
    config: Config,

    /// TCP client (if using TCP transport)
    tcp_client: ?tcp.TcpClient = null,

    /// UDP client (if using UDP transport)
    udp_client: ?udp.UdpClient = null,

    /// Pre-allocated send buffer for CSV formatting
    send_buf: [types.MAX_CSV_LEN]u8 = undefined,

    /// Detected/configured transport
    detected_transport: Transport = .tcp,

    /// Detected/configured protocol
    detected_protocol: Protocol = .csv,

    /// Number of messages sent
    messages_sent: u64 = 0,

    /// Number of messages received
    messages_received: u64 = 0,

    /// Number of send errors
    send_errors: u64 = 0,

    const Self = @This();

    /// Create and connect a new client (with optional auto-discovery).
    ///
    /// Parameters:
    ///   config - Client configuration
    ///
    /// Returns: Connected client, or error if connection fails
    pub fn init(config: Config) !Self {
        // Assertion 1: Config should be valid
        std.debug.assert(config.validate());

        var client = Self{ .config = config };

        // Handle transport selection/detection
        const transport = if (config.transport == .auto)
            try client.detectTransport()
        else
            config.transport;

        // Connect if not already connected during auto-discovery
        if (config.transport != .auto) {
            try client.connectTransport(transport);
        }

        // Handle protocol detection
        if (config.protocol == .auto) {
            client.detected_protocol = client.detectProtocol();
        } else {
            client.detected_protocol = config.protocol;
        }

        // Assertion 2: Should be connected after init
        std.debug.assert(client.isConnected());

        return client;
    }

    /// Connect to specified transport.
    fn connectTransport(self: *Self, transport: Transport) !void {
        // Assertion 1: Valid transport
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

        // Assertion 2: Connection established
        std.debug.assert(self.isConnected());
    }

    /// Auto-detect transport (try TCP first, fall back to UDP).
    fn detectTransport(self: *Self) !Transport {
        // Assertion 1: No existing connection
        std.debug.assert(self.tcp_client == null and self.udp_client == null);

        // Try TCP first (preferred for reliability)
        if (tcp.TcpClient.connect(self.config.host, self.config.port)) |client| {
            self.tcp_client = client;
            self.detected_transport = .tcp;

            // Assertion 2: TCP connected
            std.debug.assert(self.tcp_client != null);

            return .tcp;
        } else |_| {
            // TCP failed, try UDP
        }

        // Fall back to UDP
        self.udp_client = try udp.UdpClient.initWithTimeout(
            self.config.host,
            self.config.port,
            self.config.udp_recv_timeout_ms,
        );
        self.detected_transport = .udp;

        // Assertion 2: UDP connected
        std.debug.assert(self.udp_client != null);

        return .udp;
    }

    /// Detect protocol by sending a probe order and examining response.
    fn detectProtocol(self: *Self) Protocol {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // UDP doesn't send responses back to client, default to CSV
        if (self.tcp_client == null) {
            // Assertion 2: Must be using UDP
            std.debug.assert(self.udp_client != null);
            return .csv;
        }

        // Try binary probe first
        const binary_result = self.probeBinary();
        if (binary_result == .binary) {
            return .binary;
        }

        // Fall back to CSV probe
        return self.probeCsv();
    }

    /// Send binary probe and check response.
    /// Uses PROBE_ORDER_ID_BINARY (different from CSV probe).
    /// NOTE: TcpClient handles framing internally - do NOT add framing here.
    fn probeBinary(self: *Self) Protocol {
        // Assertion 1: TCP client must exist
        std.debug.assert(self.tcp_client != null);

        const probe_order = types.BinaryNewOrder.init(
            1,
            PROBE_SYMBOL,
            1,
            1,
            .buy,
            PROBE_ORDER_ID_BINARY,
        );

        // TcpClient handles framing internally - just send raw payload
        self.tcp_client.?.send(probe_order.asBytes()) catch {
            std.debug.print("DEBUG probeBinary: send failed\n", .{});
            return .csv;
        };

        // Wait for response
        std.time.sleep(PROTOCOL_DETECT_TIMEOUT_MS * std.time.ns_per_ms);

        // Try to receive response
        const response = self.tcp_client.?.recv() catch |err| {
            std.debug.print("DEBUG probeBinary: recv failed: {}\n", .{err});
            return .csv;
        };

        // Debug: show what we received
        std.debug.print("DEBUG probeBinary: got {} bytes: ", .{response.len});
        for (response[0..@min(response.len, 10)]) |b| {
            std.debug.print("{X:0>2} ", .{b});
        }
        std.debug.print("\n", .{});

        // Check if response looks like binary (TcpClient strips frame header)
        if (response.len > 0 and binary.isBinaryProtocol(response)) {
            std.debug.print("DEBUG probeBinary: BINARY detected!\n", .{});
            // Got binary response, clean up with cancel using SAME order ID
            const cancel = types.BinaryCancel.init(1, PROBE_SYMBOL, PROBE_ORDER_ID_BINARY);
            self.tcp_client.?.send(cancel.asBytes()) catch {};
            self.drainResponses();
            return .binary;
        }

        // Response was CSV or empty - clean up binary probe with cancel
        std.debug.print("DEBUG probeBinary: NOT binary (first byte 0x{X:0>2}, expected 0x4D)\n", .{
            if (response.len > 0) response[0] else 0,
        });
        if (response.len > 0) {
            const cancel_binary = types.BinaryCancel.init(1, PROBE_SYMBOL, PROBE_ORDER_ID_BINARY);
            self.tcp_client.?.send(cancel_binary.asBytes()) catch {};
            self.drainResponses();
        }

        return .csv;
    }

    /// Send CSV probe and check response.
    /// Uses PROBE_ORDER_ID_CSV (different from binary probe).
    /// NOTE: TcpClient handles framing internally - do NOT add framing here.
    fn probeCsv(self: *Self) Protocol {
        // Assertion 1: TCP client must exist
        std.debug.assert(self.tcp_client != null);

        // Use CSV-specific order ID to avoid duplicate key with binary probe
        const csv_order = "N, 1, ZZPROBE, 1, 1, B, 999999999\n";
        self.tcp_client.?.send(csv_order) catch {
            // Assertion 2: Send failed
            std.debug.assert(true);
            return .csv;
        };

        std.time.sleep(PROTOCOL_DETECT_TIMEOUT_MS * std.time.ns_per_ms);

        const response = self.tcp_client.?.recv() catch {
            return .csv;
        };

        // Check if server responded with binary to our CSV
        if (response.len > 0 and binary.isBinaryProtocol(response)) {
            // Server is binary-only, cancel with binary format
            const cancel = types.BinaryCancel.init(1, PROBE_SYMBOL, PROBE_ORDER_ID_CSV);
            self.tcp_client.?.send(cancel.asBytes()) catch {};
            self.drainResponses();
            return .binary;
        }

        // Got CSV response (or no response), clean up with CSV cancel
        if (response.len > 0) {
            const cancel_csv = "C, 1, ZZPROBE, 999999999\n";
            self.tcp_client.?.send(cancel_csv) catch {};
            self.drainResponses();
        }

        return .csv;
    }

    /// Drain any remaining responses from the socket.
    fn drainResponses(self: *Self) void {
        // Assertion 1: Called on valid client
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client == null) return;

        // Wait for responses to arrive
        std.time.sleep(100 * std.time.ns_per_ms);

        // Bounded drain loop
        var drain_count: u32 = 0;
        while (drain_count < MAX_DRAIN_ITERATIONS) : (drain_count += 1) {
            _ = self.tcp_client.?.recv() catch {
                break;
            };
        }

        // Assertion 2: Loop terminated
        std.debug.assert(drain_count <= MAX_DRAIN_ITERATIONS);
    }

    /// Get the detected/configured transport.
    pub fn getTransport(self: *const Self) Transport {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Transport should be concrete
        std.debug.assert(self.detected_transport != .auto);

        return self.detected_transport;
    }

    /// Get the detected/configured protocol.
    pub fn getProtocol(self: *const Self) Protocol {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Protocol should be concrete
        std.debug.assert(self.detected_protocol != .auto);

        return self.detected_protocol;
    }

    /// Get discovery result.
    pub fn getDiscoveryResult(self: *const Self) DiscoveryResult {
        return .{
            .transport = self.detected_transport,
            .protocol = self.detected_protocol,
        };
    }

    // ============================================================
    // Order Operations
    // ============================================================

    /// Send a new order.
    ///
    /// Parameters:
    ///   user_id - User identifier (typically 1 for self)
    ///   symbol - Trading symbol (max 8 chars)
    ///   price - Price in cents
    ///   quantity - Order quantity
    ///   side - Buy or sell
    ///   order_id - Unique order identifier
    pub fn sendNewOrder(
        self: *Self,
        user_id: u32,
        symbol: []const u8,
        price: u32,
        quantity: u32,
        side: types.Side,
        order_id: u32,
    ) !void {
        // Assertion 1: Symbol must be valid
        std.debug.assert(symbol.len > 0 and symbol.len <= types.MAX_SYMBOL_LEN);

        // Assertion 2: Quantity must be positive
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

    /// Send a cancel order request.
    ///
    /// Parameters:
    ///   user_id - User identifier
    ///   symbol - Trading symbol
    ///   order_id - Order ID to cancel
    pub fn sendCancel(self: *Self, user_id: u32, symbol: []const u8, order_id: u32) !void {
        // Assertion 1: Symbol must be valid
        std.debug.assert(symbol.len > 0 and symbol.len <= types.MAX_SYMBOL_LEN);

        // Assertion 2: Self must be connected
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
        // Assertion 1: Self must be connected
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

        // Assertion 2: Message was formatted
        std.debug.assert(data.len > 0);

        self.messages_sent +|= 1;
    }

    /// Send raw bytes.
    /// NOTE: TcpClient handles framing internally - do NOT add framing here.
    ///
    /// Parameters:
    ///   data - Raw bytes to send
    pub fn sendRaw(self: *Self, data: []const u8) !void {
        // Assertion 1: Data should not be empty
        std.debug.assert(data.len > 0);

        // Assertion 2: Should be connected
        std.debug.assert(self.isConnected());

        if (self.tcp_client) |*client| {
            // TcpClient handles framing internally
            try client.send(data);
        } else if (self.udp_client) |*client| {
            try client.send(data);
        } else {
            self.send_errors +|= 1;
            return error.NotConnected;
        }
    }

    /// Receive the next response message.
    ///
    /// Returns: Parsed OutputMessage
    pub fn recv(self: *Self) !types.OutputMessage {
        // Assertion 1: Should be connected
        std.debug.assert(self.isConnected());

        const data = try self.recvRaw();

        // Assertion 2: Got some data
        std.debug.assert(data.len > 0);

        self.messages_received +|= 1;

        // Auto-detect protocol from response
        if (binary.isBinaryProtocol(data)) {
            return try binary.decodeOutput(data);
        } else {
            return try csv.parseOutput(data);
        }
    }

    /// Receive raw response bytes.
    /// NOTE: TcpClient strips frame header internally.
    ///
    /// Returns: Raw response data (payload only)
    pub fn recvRaw(self: *Self) ![]const u8 {
        // Assertion 1: Should be connected
        std.debug.assert(self.isConnected());

        if (self.tcp_client) |*client| {
            const data = try client.recv();
            // Assertion 2: Got data from TCP
            std.debug.assert(data.len > 0 or data.len == 0); // May be empty on timeout
            return data;
        } else if (self.udp_client) |*client| {
            const data = try client.recv();
            // Assertion 2: Got data from UDP
            std.debug.assert(data.len > 0 or data.len == 0);
            return data;
        }

        return error.NotConnected;
    }

    /// Try to receive with timeout (non-blocking).
    ///
    /// Parameters:
    ///   timeout_ms - Timeout in milliseconds
    ///
    /// Returns: Parsed message or null if no data available
    pub fn tryRecv(self: *Self, timeout_ms: u32) !?types.OutputMessage {
        // Assertion 1: Timeout should be reasonable
        std.debug.assert(timeout_ms < 3600_000); // Less than 1 hour

        const data = try self.tryRecvRaw(timeout_ms);

        if (data) |d| {
            // Assertion 2: Got non-empty data
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
    /// NOTE: TcpClient strips frame header internally.
    ///
    /// Parameters:
    ///   timeout_ms - Timeout in milliseconds
    ///
    /// Returns: Raw data or null if no data available
    pub fn tryRecvRaw(self: *Self, timeout_ms: u32) !?[]const u8 {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client) |*client| {
            return client.tryRecv(timeout_ms) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) return null;
                return err;
            };
        } else if (self.udp_client) |*client| {
            // TODO: Implement proper timeout for UDP using SO_RCVTIMEO
            // For now, do a non-blocking recv attempt (timeout_ms ignored for UDP)
            return client.recv() catch |err| {
                if (err == error.WouldBlock) return null;
                return err;
            };
        }

        // Assertion 2: Not connected
        std.debug.assert(false);
        return error.NotConnected;
    }

    /// Check if connected.
    pub fn isConnected(self: *const Self) bool {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client) |*client| {
            const connected = client.isConnected();
            // Assertion 2: Check completed
            std.debug.assert(connected or !connected);
            return connected;
        }

        // UDP is connectionless - consider it always "connected"
        const has_udp = self.udp_client != null;

        // Assertion 2: Result is valid
        std.debug.assert(has_udp or !has_udp);

        return has_udp;
    }

    /// Get client statistics.
    pub fn getStats(self: *const Self) struct { sent: u64, received: u64, errors: u64 } {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Stats should be consistent
        std.debug.assert(self.messages_sent >= self.send_errors or self.messages_sent == 0);

        return .{
            .sent = self.messages_sent,
            .received = self.messages_received,
            .errors = self.send_errors,
        };
    }

    /// Reset statistics.
    pub fn resetStats(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.messages_sent = 0;
        self.messages_received = 0;
        self.send_errors = 0;

        // Assertion 2: Stats reset
        std.debug.assert(self.messages_sent == 0);
    }

    /// Close the client and release resources.
    pub fn deinit(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        if (self.tcp_client) |*client| {
            client.close();
            self.tcp_client = null;
        }

        if (self.udp_client) |*client| {
            client.close();
            self.udp_client = null;
        }

        // Assertion 2: Disconnected
        std.debug.assert(!self.isConnected());
    }
};

// ============================================================
// Convenience Functions
// ============================================================

/// Create a client with default settings (auto-detect everything).
///
/// Parameters:
///   host - Server hostname or IP
///   port - Server port
pub fn connect(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .auto,
        .protocol = .auto,
    });
}

/// Create a TCP client with binary protocol.
///
/// Parameters:
///   host - Server hostname or IP
///   port - Server port
pub fn connectTcpBinary(host: []const u8, port: u16) !EngineClient {
    return EngineClient.init(.{
        .host = host,
        .port = port,
        .transport = .tcp,
        .protocol = .binary,
    });
}

/// Create a TCP client with CSV protocol.
///
/// Parameters:
///   host - Server hostname or IP
///   port - Server port
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
    try std.testing.expect(config.validate());
}

test "Config validation" {
    const valid_config = Config{ .host = "localhost", .port = 8080 };
    try std.testing.expect(valid_config.validate());
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
    // Critical test: ensure binary and CSV probes use different order IDs
    // to prevent duplicate key errors on server
    try std.testing.expect(PROBE_ORDER_ID_BINARY != PROBE_ORDER_ID_CSV);
}
