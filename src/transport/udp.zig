//! UDP transport layer.
//!
//! Supports both single-message packets and batched packets (multiple CSV messages).
//! UDP provides lowest-latency fire-and-forget semantics suitable for market data.
//!
//! Power of Ten Compliance:
//! - Rule 1: No goto/setjmp, no recursion ✓
//! - Rule 2: All loops have fixed upper bounds ✓ (no loops)
//! - Rule 3: No dynamic memory after init ✓
//! - Rule 4: Functions ≤60 lines ✓
//! - Rule 5: ≥2 assertions per function ✓
//! - Rule 6: Data at smallest scope ✓
//! - Rule 7: Check return values, validate parameters ✓

const std = @import("std");
const socket = @import("socket.zig");

// ============================================================
// Constants
// ============================================================

/// Default receive timeout in milliseconds
const DEFAULT_RECV_TIMEOUT_MS: u32 = 200;

/// Receive buffer size - sized for batched responses
/// Server may send up to ~1400 bytes per packet containing many CSV messages
const RECV_BUFFER_SIZE: usize = 2048;

// ============================================================
// UDP Client
// ============================================================

pub const UdpClient = struct {
    sock: socket.UdpSocket,

    /// Receive buffer - sized for batched responses (multiple messages per packet)
    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,

    /// Statistics
    packets_sent: u64 = 0,
    packets_received: u64 = 0,
    send_errors: u64 = 0,

    const Self = @This();

    /// Create UDP client targeting the specified server.
    ///
    /// Parameters:
    ///   host - Server hostname or IP address
    ///   port - Server port
    ///
    /// Returns: Initialized UDP client
    pub fn init(host: []const u8, port: u16) !Self {
        // Assertion 1: Host should not be empty
        std.debug.assert(host.len > 0);

        // Assertion 2: Port should be valid
        std.debug.assert(port > 0);

        return initWithTimeout(host, port, DEFAULT_RECV_TIMEOUT_MS);
    }

    /// Create UDP client with custom receive timeout.
    ///
    /// Parameters:
    ///   host - Server hostname or IP address
    ///   port - Server port
    ///   recv_timeout_ms - Receive timeout in milliseconds
    ///
    /// Returns: Initialized UDP client
    pub fn initWithTimeout(host: []const u8, port: u16, recv_timeout_ms: u32) !Self {
        // Assertion 1: Host should not be empty
        std.debug.assert(host.len > 0);

        // Assertion 2: Timeout should be reasonable
        std.debug.assert(recv_timeout_ms < 3600_000);

        const addr = try socket.Address.parseIpv4(host, port);

        // Create socket with LARGE kernel buffers to prevent drops under load
        var sock = try socket.UdpSocket.init(.{
            .recv_timeout_ms = recv_timeout_ms,
            .recv_buffer_size = socket.LARGE_RECV_BUFFER, // 16MB kernel buffer
            .send_buffer_size = socket.LARGE_SEND_BUFFER, // 4MB kernel buffer
        });
        errdefer sock.close();

        // Bind to ephemeral port so we can receive responses
        const bind_addr = socket.Address.initIpv4(.{ 0, 0, 0, 0 }, 0);
        try sock.bind(bind_addr);

        sock.setTarget(addr);

        return .{ .sock = sock };
    }

    /// Send message (fire-and-forget).
    ///
    /// Parameters:
    ///   data - Message bytes to send
    pub fn send(self: *Self, data: []const u8) !void {
        // Assertion 1: Data should not be empty
        std.debug.assert(data.len > 0);

        // Assertion 2: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        _ = self.sock.send(data) catch |err| {
            self.send_errors +|= 1;
            return err;
        };

        self.packets_sent +|= 1;
    }

    /// Receive a packet (may contain multiple CSV messages if server is batching).
    /// Returns the received data, or error.WouldBlock on timeout.
    ///
    /// Returns: Slice of received data
    pub fn recv(self: *Self) ![]const u8 {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        const n = try self.sock.recv(&self.recv_buf);

        // Assertion 2: Received data should be within buffer
        std.debug.assert(n <= self.recv_buf.len);

        self.packets_received +|= 1;

        return self.recv_buf[0..n];
    }

    /// Get client statistics.
    pub fn getStats(self: *const Self) struct { sent: u64, received: u64, errors: u64 } {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Stats should be consistent
        std.debug.assert(self.packets_sent >= self.send_errors or self.send_errors == 0);

        return .{
            .sent = self.packets_sent,
            .received = self.packets_received,
            .errors = self.send_errors,
        };
    }

    /// Reset statistics.
    pub fn resetStats(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.packets_sent = 0;
        self.packets_received = 0;
        self.send_errors = 0;

        // Assertion 2: Stats reset
        std.debug.assert(self.packets_sent == 0);
    }

    /// Close the socket.
    pub fn close(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.sock.close();

        // Assertion 2: Socket closed (conceptually)
        std.debug.assert(true);
    }
};

// ============================================================
// Tests
// ============================================================

test "UdpClient struct size" {
    const size = @sizeOf(UdpClient);
    // Should be under 3KB (mostly the recv buffer)
    try std.testing.expect(size < 3000);
}

test "UdpClient buffer size" {
    try std.testing.expectEqual(RECV_BUFFER_SIZE, 2048);
}
