//! TCP transport layer with length-prefix framing.
//!
//! Provides reliable, ordered message delivery to the matching engine.
//! Messages are framed with a 4-byte big-endian length prefix.
//! Includes tryRecv for non-blocking receive (used in interleaved mode).

const std = @import("std");
const builtin = @import("builtin");
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
            .tcp_nodelay = true,
            .recv_timeout_ms = 5000,
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

    /// Receive the next complete message (blocking with timeout)
    pub fn recv(self: *Self) ![]const u8 {
        if (self.frame_reader.nextMessage()) |msg| {
            return msg;
        }

        const max_read_attempts = 1000;
        var attempts: usize = 0;

        while (attempts < max_read_attempts) : (attempts += 1) {
            const buf = self.frame_reader.getWriteBuffer();
            if (buf.len == 0) {
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

    /// Non-blocking receive - returns null immediately if no data available.
    /// Used for interleaved send/receive mode to drain responses between sends.
    pub fn tryRecv(self: *Self, timeout_ms: i32) !?[]const u8 {
        // First check if we already have a complete message buffered
        if (self.frame_reader.nextMessage()) |msg| {
            return msg;
        }

        // Poll to see if data is available
        if (!self.pollForData(timeout_ms)) {
            return null; // No data available within timeout
        }

        // Data available, read it
        const buf = self.frame_reader.getWriteBuffer();
        if (buf.len == 0) {
            self.frame_reader.reset();
            return null;
        }

        const n = self.sock.recv(buf) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                return null;
            }
            return err;
        };

        if (n == 0) return null;

        self.frame_reader.advance(n);

        return self.frame_reader.nextMessage();
    }

    /// Poll socket to check if data is available to read
    fn pollForData(self: *Self, timeout_ms: i32) bool {
        const fd = self.sock.handle;

        if (builtin.os.tag == .windows) {
            // Windows: use select
            // Note: Windows fd_set is different, using WinSock structures
            var read_set: std.os.windows.ws2_32.fd_set = .{
                .fd_count = 1,
                .fd_array = undefined,
            };
            read_set.fd_array[0] = fd;

            var timeout: std.os.windows.ws2_32.timeval = .{
                .tv_sec = @divTrunc(timeout_ms, 1000),
                .tv_usec = @mod(timeout_ms, 1000) * 1000,
            };

            const result = std.os.windows.ws2_32.select(
                0, // ignored on Windows
                &read_set,
                null,
                null,
                if (timeout_ms >= 0) &timeout else null,
            );

            return result > 0;
        } else {
            // POSIX: use poll
            var fds = [_]std.posix.pollfd{
                .{
                    .fd = fd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            const result = std.posix.poll(&fds, timeout_ms) catch return false;
            return result > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
        }
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
    const size = @sizeOf(TcpClient);
    try std.testing.expect(size < 40000);
}
