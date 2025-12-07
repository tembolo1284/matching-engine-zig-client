//! UDP transport layer.
//! Supports both single-message packets and batched packets (multiple CSV messages).

const std = @import("std");
const socket = @import("socket.zig");

pub const UdpClient = struct {
    sock: socket.UdpSocket,
    /// Receive buffer - sized for batched responses (multiple messages per packet)
    /// Server may send up to ~1400 bytes per packet containing many CSV messages
    recv_buf: [2048]u8 = undefined,

    const Self = @This();

    /// Default receive timeout in milliseconds
    const DEFAULT_RECV_TIMEOUT_MS: u32 = 200;

    /// Create UDP client targeting the specified server
    pub fn init(host: []const u8, port: u16) !Self {
        return initWithTimeout(host, port, DEFAULT_RECV_TIMEOUT_MS);
    }

    /// Create UDP client with custom receive timeout
    pub fn initWithTimeout(host: []const u8, port: u16, recv_timeout_ms: u32) !Self {
        const addr = try socket.Address.parseIpv4(host, port);

        // Create socket with LARGE kernel buffers to prevent drops under load
        var sock = try socket.UdpSocket.init(.{
            .recv_timeout_ms = recv_timeout_ms,
            .recv_buffer_size = socket.LARGE_RECV_BUFFER, // 8MB kernel buffer
            .send_buffer_size = socket.LARGE_SEND_BUFFER, // 4MB kernel buffer
        });

        // Bind to ephemeral port so we can receive responses
        const bind_addr = socket.Address.initIpv4(.{ 0, 0, 0, 0 }, 0);
        try sock.bind(bind_addr);

        sock.setTarget(addr);

        return .{ .sock = sock };
    }

    /// Send message (fire-and-forget)
    pub fn send(self: *Self, data: []const u8) !void {
        _ = try self.sock.send(data);
    }

    /// Receive a packet (may contain multiple CSV messages if server is batching)
    /// Returns the received data, or error.WouldBlock on timeout
    pub fn recv(self: *Self) ![]const u8 {
        const n = try self.sock.recv(&self.recv_buf);
        return self.recv_buf[0..n];
    }

    /// Close the socket
    pub fn close(self: *Self) void {
        self.sock.close();
    }
};

// ============================================================
// Tests
// ============================================================

test "UdpClient struct size" {
    const size = @sizeOf(UdpClient);
    try std.testing.expect(size < 3000); // Should be under 3KB
}
