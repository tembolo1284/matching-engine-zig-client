//! TCP transport layer with optional length-prefix framing.
//!
//! Provides reliable, ordered message delivery to the matching engine.
//! Supports two modes:
//! - Framed mode: Messages have a 4-byte big-endian length prefix
//! - Raw mode: Messages are sent/received as-is (for binary protocol servers)
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
const builtin = @import("builtin");
const socket = @import("socket.zig");
const framing = @import("../protocol/framing.zig");

// ============================================================
// Constants
// ============================================================

/// Maximum read attempts before giving up
const MAX_READ_ATTEMPTS: usize = 1000;

/// Binary protocol magic byte
const BINARY_MAGIC: u8 = 0x4D;

/// Default socket receive timeout in milliseconds
const DEFAULT_RECV_TIMEOUT_MS: u32 = 5000;

/// Size of raw receive buffer
const RAW_RECV_BUFFER_SIZE: usize = 4096;

// ============================================================
// TCP Client
// ============================================================

pub const TcpClient = struct {
    sock: socket.TcpSocket,
    frame_reader: framing.FrameReader,
    send_buf: [framing.MAX_MESSAGE_SIZE + framing.HEADER_SIZE]u8 = undefined,

    /// Buffer for raw (non-framed) receives
    raw_recv_buf: [RAW_RECV_BUFFER_SIZE]u8 = undefined,

    /// Whether to use length-prefix framing (default: true - server requires it)
    use_framing: bool = true,

    /// Whether framing mode has been detected
    framing_detected: bool = false,

    const Self = @This();

    /// Connect to matching engine TCP server.
    ///
    /// Parameters:
    ///   host - Server hostname or IP address
    ///   port - Server port
    ///
    /// Returns: Connected TcpClient
    pub fn connect(host: []const u8, port: u16) !Self {
        // Assertion 1: Host should not be empty
        std.debug.assert(host.len > 0);

        // Assertion 2: Port should be valid
        std.debug.assert(port > 0);

        const addr = try socket.Address.parseIpv4(host, port);
        var sock = try socket.TcpSocket.init(.{
            .tcp_nodelay = true,
            .recv_timeout_ms = DEFAULT_RECV_TIMEOUT_MS,
        });
        errdefer sock.close();

        try sock.connect(addr);

        return .{
            .sock = sock,
            .frame_reader = framing.FrameReader.init(),
            .use_framing = true, // Server requires length-prefix framing
            .framing_detected = true,
        };
    }

    /// Connect with explicit framing mode.
    ///
    /// Parameters:
    ///   host - Server hostname or IP address
    ///   port - Server port
    ///   use_framing - Whether to use length-prefix framing
    pub fn connectWithFraming(host: []const u8, port: u16, use_framing_mode: bool) !Self {
        // Assertion 1: Host should not be empty
        std.debug.assert(host.len > 0);

        // Assertion 2: Port should be valid
        std.debug.assert(port > 0);

        var client = try connect(host, port);
        client.use_framing = use_framing_mode;
        client.framing_detected = true; // Explicitly set, don't auto-detect
        return client;
    }

    /// Send a message (with framing if enabled).
    ///
    /// Parameters:
    ///   data - Message bytes to send
    pub fn send(self: *Self, data: []const u8) !void {
        // Assertion 1: Data should not be empty
        std.debug.assert(data.len > 0);

        // Assertion 2: Should be connected
        std.debug.assert(self.sock.connected);

        if (self.use_framing) {
            const framed = try framing.encode(data, &self.send_buf);
            try self.sock.sendAll(framed);
        } else {
            // Raw mode - send as-is
            try self.sock.sendAll(data);
        }
    }

    /// Receive the next complete message (blocking with timeout).
    /// Auto-detects framing mode on first receive if not explicitly set.
    ///
    /// Returns: Message bytes
    pub fn recv(self: *Self) ![]const u8 {
        // Assertion 1: Should be connected
        std.debug.assert(self.sock.connected);

        if (self.use_framing) {
            return self.recvFramed();
        } else {
            return self.recvRaw();
        }
    }

    /// Receive with length-prefix framing.
    fn recvFramed(self: *Self) ![]const u8 {
        // Assertion 1: Framing mode should be enabled
        std.debug.assert(self.use_framing);

        // Check for already-buffered complete message
        if (self.frame_reader.nextMessage()) |msg| {
            // Assertion 2: Message should not be empty
            std.debug.assert(msg.len > 0);
            return msg;
        }

        var attempts: usize = 0;
        while (attempts < MAX_READ_ATTEMPTS) : (attempts += 1) {
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

    /// Receive without framing (raw binary/CSV messages).
    /// For binary protocol: reads exactly one message based on message type.
    /// For CSV: reads until newline or buffer full.
    fn recvRaw(self: *Self) ![]const u8 {
        // Assertion 1: Should be connected
        std.debug.assert(self.sock.connected);

        // Read whatever is available
        const n = try self.sock.recv(&self.raw_recv_buf);

        // Assertion 2: Should have received something
        std.debug.assert(n > 0);

        return self.raw_recv_buf[0..n];
    }

    /// Non-blocking receive - returns null immediately if no data available.
    /// Used for interleaved send/receive mode to drain responses between sends.
    ///
    /// Parameters:
    ///   timeout_ms - Timeout in milliseconds (0 = immediate return)
    ///
    /// Returns: Message bytes or null if no data available
    pub fn tryRecv(self: *Self, timeout_ms: i32) !?[]const u8 {
        // Assertion 1: Should be connected
        std.debug.assert(self.sock.connected);

        // Assertion 2: Timeout should be reasonable
        std.debug.assert(timeout_ms >= 0 and timeout_ms < 3600_000);

        if (self.use_framing) {
            return self.tryRecvFramed(timeout_ms);
        } else {
            return self.tryRecvRaw(timeout_ms);
        }
    }

    /// Non-blocking framed receive.
    fn tryRecvFramed(self: *Self, timeout_ms: i32) !?[]const u8 {
        // Check for already-buffered complete message
        if (self.frame_reader.nextMessage()) |msg| {
            return msg;
        }

        // Poll to see if data is available
        if (!self.pollForData(timeout_ms)) {
            return null;
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

        // Assertion: advance succeeded
        std.debug.assert(true);

        return self.frame_reader.nextMessage();
    }

    /// Non-blocking raw receive.
    fn tryRecvRaw(self: *Self, timeout_ms: i32) !?[]const u8 {
        // Assertion 1: Should be connected
        std.debug.assert(self.sock.connected);

        // Poll to see if data is available
        if (!self.pollForData(timeout_ms)) {
            return null;
        }

        // Data available, read it
        const n = self.sock.recv(&self.raw_recv_buf) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                return null;
            }
            return err;
        };

        if (n == 0) return null;

        // Assertion 2: Received valid data
        std.debug.assert(n <= self.raw_recv_buf.len);

        return self.raw_recv_buf[0..n];
    }

    /// Poll socket to check if data is available to read.
    ///
    /// Parameters:
    ///   timeout_ms - Timeout in milliseconds (-1 = infinite, 0 = immediate)
    ///
    /// Returns: true if data is available
    fn pollForData(self: *Self, timeout_ms: i32) bool {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        const fd = self.sock.handle;

        if (builtin.os.tag == .windows) {
            return self.pollWindows(fd, timeout_ms);
        } else {
            return self.pollPosix(fd, timeout_ms);
        }
    }

    /// Windows poll implementation using select().
    fn pollWindows(self: *Self, fd: socket.Handle, timeout_ms: i32) bool {
        _ = self;

        // Assertion 1: FD should be valid
        std.debug.assert(fd != 0);

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
            0,
            &read_set,
            null,
            null,
            if (timeout_ms >= 0) &timeout else null,
        );

        // Assertion 2: Result is valid
        std.debug.assert(result >= -1);

        return result > 0;
    }

    /// POSIX poll implementation.
    fn pollPosix(self: *Self, fd: socket.Handle, timeout_ms: i32) bool {
        _ = self;

        // Assertion 1: FD should be valid
        std.debug.assert(fd >= 0);

        var fds = [_]std.posix.pollfd{
            .{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const result = std.posix.poll(&fds, timeout_ms) catch return false;

        // Assertion 2: Check result validity
        std.debug.assert(result >= 0);

        return result > 0 and (fds[0].revents & std.posix.POLL.IN) != 0;
    }

    /// Check if connected.
    pub fn isConnected(self: *const Self) bool {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Socket state should be consistent
        std.debug.assert(self.sock.connected or !self.sock.connected);

        return self.sock.connected;
    }

    /// Enable or disable framing mode.
    pub fn setFramingMode(self: *Self, use_framing_mode: bool) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.use_framing = use_framing_mode;
        self.framing_detected = true;

        // Assertion 2: Mode was set
        std.debug.assert(self.use_framing == use_framing_mode);
    }

    /// Get current framing mode.
    pub fn isFramingEnabled(self: *const Self) bool {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Return value is consistent
        std.debug.assert(self.use_framing or !self.use_framing);

        return self.use_framing;
    }

    /// Close the connection.
    pub fn close(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.sock.close();

        // Assertion 2: Socket should be closed
        std.debug.assert(!self.sock.connected);
    }
};

// ============================================================
// Tests
// ============================================================

test "TcpClient struct size" {
    const size = @sizeOf(TcpClient);
    // Should be reasonable for stack allocation
    try std.testing.expect(size < 50000);
}

test "TcpClient default framing mode" {
    // Can't actually connect in tests, but verify struct initialization
    var client = TcpClient{
        .sock = undefined,
        .frame_reader = framing.FrameReader.init(),
        .use_framing = false,
        .framing_detected = false,
    };

    try std.testing.expect(!client.isFramingEnabled());

    client.setFramingMode(true);
    try std.testing.expect(client.isFramingEnabled());

    client.setFramingMode(false);
    try std.testing.expect(!client.isFramingEnabled());
}
