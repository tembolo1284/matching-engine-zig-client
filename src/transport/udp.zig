//! UDP transport layer.
//!
//! Fire-and-forget message delivery with lowest latency.
//! No framing needed - each UDP packet is one message.

const std = @import("std");
const socket = @import("socket.zig");

pub const UdpClient = struct {
    sock: socket.UdpSocket,
    recv_buf: [1500]u8 = undefined, // MTU-sized buffer

    const Self = @This();

    /// Create UDP client targeting the specified server
    pub fn init(host: []const u8, port: u16) !Self {
        const addr = try socket.Address.parseIpv4(host, port);

        var sock = try socket.UdpSocket.init(.{});
        sock.setTarget(addr);

        return .{ .sock = sock };
    }

    /// Send message (fire-and-forget)
    pub fn send(self: *Self, data: []const u8) !void {
        _ = try self.sock.send(data);
    }

    /// Receive a message (blocking)
    /// Note: UDP mode is typically fire-and-forget, so this is mainly
    /// for testing or receiving multicast data.
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
    try std.testing.expect(size < 2000); // Should be under 2KB
}
