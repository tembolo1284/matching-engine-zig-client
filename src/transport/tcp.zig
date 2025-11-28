//! TCP transport layer with length-prefix framing.
//!
//! Provides reliable, ordered message delivery to the matching engine.
//! Messages are framed with a 4-byte big-endian length prefix.

const std = @import("std");
const socket = @import("socket.zig");
const framing = @import("../protocol/framing.zig");

pub const TcpClient = struct {
    sock: socket.TcpSocket,
    frame_reader: framing.FrameReader,
    send_buf: [framing.MAX_MESSAGE_SIZE + framing.HEADER_SIZE]u8 = undefined,

    const Self = @This();

    /// Connect to matching engine TCP server
    pub fn connect(host: []const u8, port: u16) !Self {
        const addr = try socket.Address.parseIpv4(host, port);

        var sock = try socket.TcpSocket.init(.{
            .tcp_nodelay = true, // Disable Nagle for lower latency
            .recv_timeout_ms = 5000, // 5 second timeout
        });
        errdefer sock.close();

        try sock.connect(addr);

        return .{
            .sock = sock,
            .frame_reader = framing.FrameReader.init(),
        };
    }

    /// Send a message with length-prefix framing
    pub fn send(self: *Self, data: []const u8) !void {
        const framed = try framing.encode(data, &self.send_buf);
        try self.sock.sendAll(framed);
    }

    /// Receive the next complete message.
    /// Blocks until a full message is available or timeout/error.
    pub fn recv(self: *Self) ![]const u8 {
        // First check if we already have a complete message buffered
        if (self.frame_reader.nextMessage()) |msg| {
            return msg;
        }

        // Need to read more data
        const max_read_attempts = 1000;
        var attempts: usize = 0;

        while (attempts < max_read_attempts) : (attempts += 1) {
            const buf = self.frame_reader.getWriteBuffer();
            if (buf.len == 0) {
                // Buffer full but no complete message - protocol error
                self.frame_reader.reset();
                return error.RecvFailed;
            }

            const n = try self.sock.recv(buf);
            self.frame_reader.advance(n);

            if (self.frame_reader.nextMessage()) |msg| {
                return msg;
            }
        }

        return error.Timeout;
    }

    /// Check if connected
    pub fn isConnected(self: *const Self) bool {
        return self.sock.connected;
    }

    /// Close the connection
    pub fn close(self: *Self) void {
        self.sock.close();
    }
};

// ============================================================
// Tests
// ============================================================

test "TcpClient struct size" {
    // Ensure the client doesn't have unexpected padding
    const size = @sizeOf(TcpClient);
    try std.testing.expect(size < 40000); // Should be under 40KB
}
