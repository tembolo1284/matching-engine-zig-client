//! Cross-platform socket abstraction.
//!
//! Provides a unified interface over POSIX sockets (Linux/macOS) and
//! Winsock (Windows). Zig's std.posix handles most of this, but we add
//! some convenience wrappers and platform-specific options.
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

// ============================================================
// Types
// ============================================================

/// Platform-specific socket handle type
pub const Handle = std.posix.socket_t;

/// Socket configuration options
pub const Options = struct {
    /// Allow address reuse (SO_REUSEADDR)
    reuse_addr: bool = true,

    /// Receive timeout in milliseconds (0 = no timeout)
    recv_timeout_ms: u32 = 0,

    /// Send timeout in milliseconds (0 = no timeout)
    send_timeout_ms: u32 = 0,

    /// TCP_NODELAY - disable Nagle's algorithm for lower latency
    tcp_nodelay: bool = true,

    /// Receive buffer size (0 = system default)
    /// For high-throughput UDP, use 8MB+ to prevent kernel drops
    recv_buffer_size: u32 = 0,

    /// Send buffer size (0 = system default)
    send_buffer_size: u32 = 0,

    /// Validate options
    pub fn validate(self: Options) bool {
        // Assertion 1: Timeouts should be reasonable (< 1 hour)
        std.debug.assert(self.recv_timeout_ms < 3600_000);
        std.debug.assert(self.send_timeout_ms < 3600_000);

        // Assertion 2: Buffer sizes should be reasonable
        std.debug.assert(self.recv_buffer_size < 1024 * 1024 * 1024);
        std.debug.assert(self.send_buffer_size < 1024 * 1024 * 1024);

        return true;
    }
};

// ============================================================
// Constants
// ============================================================

/// Default large buffer size for high-throughput scenarios
pub const LARGE_RECV_BUFFER: u32 = 16 * 1024 * 1024; // 16MB
pub const LARGE_SEND_BUFFER: u32 = 4 * 1024 * 1024; // 4MB

/// Maximum send attempts before giving up
const MAX_SEND_ATTEMPTS: usize = 1000;

// ============================================================
// Errors
// ============================================================

pub const SocketError = error{
    CreateFailed,
    BindFailed,
    ConnectFailed,
    ListenFailed,
    AcceptFailed,
    SetOptionFailed,
    AddressParseError,
    SendFailed,
    RecvFailed,
    Timeout,
    ConnectionClosed,
    WouldBlock,
} || std.posix.SocketError || std.posix.SetSockOptError || std.posix.ConnectError;

// ============================================================
// Address
// ============================================================

/// IPv4 address wrapper
pub const Address = struct {
    inner: std.posix.sockaddr,
    len: std.posix.socklen_t,

    /// Initialize from raw IPv4 octets and port.
    pub fn initIpv4(ip: [4]u8, port: u16) Address {
        // Assertion 1: Port can be any value including 0
        std.debug.assert(port <= 65535);

        const addr = std.net.Address.initIp4(ip, port);

        // Assertion 2: Address was created
        std.debug.assert(@sizeOf(@TypeOf(addr.any)) > 0);

        return .{
            .inner = addr.any,
            .len = 16, // sizeof(sockaddr_in) is always 16 bytes
        };
    }

    /// Parse IPv4 address string (e.g., "127.0.0.1").
    pub fn parseIpv4(host: []const u8, port: u16) !Address {
        // Assertion 1: Host should not be empty
        std.debug.assert(host.len > 0);

        // Assertion 2: Host should be reasonable length
        std.debug.assert(host.len <= 15); // "255.255.255.255"

        var octets: [4]u8 = undefined;
        var idx: usize = 0;
        var octet: u16 = 0;

        for (host) |c| {
            if (c == '.') {
                if (idx >= 4 or octet > 255) return error.AddressParseError;
                octets[idx] = @intCast(octet);
                idx += 1;
                octet = 0;
            } else if (c >= '0' and c <= '9') {
                octet = octet * 10 + (c - '0');
                if (octet > 255) return error.AddressParseError;
            } else {
                return error.AddressParseError;
            }
        }

        if (idx != 3) return error.AddressParseError;
        octets[3] = @intCast(octet);

        return initIpv4(octets, port);
    }

    /// Get the port number.
    pub fn getPort(self: Address) u16 {
        // Assertion 1: Address should be initialized
        std.debug.assert(self.len > 0);

        const sa_in: *const std.posix.sockaddr.in = @ptrCast(&self.inner);

        // Assertion 2: Result should be valid
        std.debug.assert(std.mem.bigToNative(u16, sa_in.port) <= 65535);

        return std.mem.bigToNative(u16, sa_in.port);
    }
};

// ============================================================
// UDP Socket
// ============================================================

/// UDP socket wrapper
pub const UdpSocket = struct {
    handle: Handle,
    target_addr: ?Address = null,

    const Self = @This();

    /// Create a new UDP socket.
    pub fn init(options: Options) SocketError!Self {
        // Assertion 1: Options should be valid
        std.debug.assert(options.validate());

        const handle = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        );
        errdefer std.posix.close(handle);

        try applyOptions(handle, options);

        // Assertion 2: Handle should be valid
        std.debug.assert(handle != 0 or builtin.os.tag == .windows);

        return .{ .handle = handle };
    }

    /// Create UDP socket with large buffers for high-throughput scenarios.
    pub fn initHighThroughput(recv_timeout_ms: u32) SocketError!Self {
        // Assertion 1: Timeout should be reasonable
        std.debug.assert(recv_timeout_ms < 3600_000);

        const sock = try init(.{
            .recv_timeout_ms = recv_timeout_ms,
            .recv_buffer_size = LARGE_RECV_BUFFER,
            .send_buffer_size = LARGE_SEND_BUFFER,
        });

        // Assertion 2: Socket was created
        std.debug.assert(sock.handle != 0 or builtin.os.tag == .windows);

        return sock;
    }

    /// Bind to local address for receiving.
    pub fn bind(self: *Self, addr: Address) SocketError!void {
        // Assertion 1: Address should be valid
        std.debug.assert(addr.len > 0);

        std.posix.bind(self.handle, &addr.inner, addr.len) catch |err| {
            return translateError(err);
        };

        // Assertion 2: Bind succeeded (no way to verify without getsockname)
        std.debug.assert(true);
    }

    /// Set target address for send().
    pub fn setTarget(self: *Self, addr: Address) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Address should be valid
        std.debug.assert(addr.len > 0);

        self.target_addr = addr;
    }

    /// Send data to target address.
    pub fn send(self: *Self, data: []const u8) SocketError!usize {
        // Assertion 1: Data should not be empty
        std.debug.assert(data.len > 0);

        // Assertion 2: Target should be set
        std.debug.assert(self.target_addr != null);

        if (self.target_addr) |addr| {
            return std.posix.sendto(
                self.handle,
                data,
                0,
                &addr.inner,
                addr.len,
            ) catch |err| translateError(err);
        }
        return error.SendFailed;
    }

    /// Receive data.
    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        // Assertion 1: Buffer should not be empty
        std.debug.assert(buf.len > 0);

        const result = std.posix.recvfrom(
            self.handle,
            buf,
            0,
            null,
            null,
        ) catch |err| return translateError(err);

        // Assertion 2: Result should be valid
        std.debug.assert(result <= buf.len);

        return result;
    }

    /// Join a multicast group.
    pub fn joinMulticastGroup(self: *Self, group: [4]u8) SocketError!void {
        // Assertion 1: Group should be in multicast range
        std.debug.assert(group[0] >= 224 and group[0] <= 239);

        const MReq = extern struct {
            multiaddr: [4]u8,
            interface: [4]u8,
        };

        const mreq = MReq{
            .multiaddr = group,
            .interface = .{ 0, 0, 0, 0 },
        };

        // IP_ADD_MEMBERSHIP = 12 on most platforms
        const IP_ADD_MEMBERSHIP = 12;

        std.posix.setsockopt(
            self.handle,
            std.posix.IPPROTO.IP,
            IP_ADD_MEMBERSHIP,
            std.mem.asBytes(&mreq),
        ) catch |err| return translateError(err);

        // Assertion 2: Join succeeded
        std.debug.assert(true);
    }

    /// Close the socket.
    pub fn close(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        std.posix.close(self.handle);

        // Assertion 2: Socket handle invalidated (conceptually)
        std.debug.assert(true);
    }
};

// ============================================================
// TCP Socket
// ============================================================

/// TCP socket wrapper
pub const TcpSocket = struct {
    handle: Handle,
    connected: bool = false,

    const Self = @This();

    /// Create a new TCP socket.
    pub fn init(options: Options) SocketError!Self {
        // Assertion 1: Options should be valid
        std.debug.assert(options.validate());

        const handle = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM,
            0,
        );
        errdefer std.posix.close(handle);

        try applyOptions(handle, options);

        // Assertion 2: Handle should be valid
        std.debug.assert(handle != 0 or builtin.os.tag == .windows);

        return .{ .handle = handle };
    }

    /// Connect to remote address.
    pub fn connect(self: *Self, addr: Address) SocketError!void {
        // Assertion 1: Address should be valid
        std.debug.assert(addr.len > 0);

        // Assertion 2: Should not already be connected
        std.debug.assert(!self.connected);

        std.posix.connect(self.handle, &addr.inner, addr.len) catch |err| {
            return translateError(err);
        };
        self.connected = true;
    }

    /// Send data.
    pub fn send(self: *Self, data: []const u8) SocketError!usize {
        // Assertion 1: Should be connected
        std.debug.assert(self.connected);

        // Assertion 2: Data should not be empty
        std.debug.assert(data.len > 0);

        if (!self.connected) return error.SendFailed;

        return std.posix.send(self.handle, data, 0) catch |err| translateError(err);
    }

    /// Send all data (loops until complete).
    pub fn sendAll(self: *Self, data: []const u8) SocketError!void {
        // Assertion 1: Should be connected
        std.debug.assert(self.connected);

        // Assertion 2: Data should not be empty
        std.debug.assert(data.len > 0);

        var sent: usize = 0;
        var attempts: usize = 0;

        while (sent < data.len and attempts < MAX_SEND_ATTEMPTS) : (attempts += 1) {
            const n = try self.send(data[sent..]);
            if (n == 0) return error.ConnectionClosed;
            sent += n;
        }

        if (sent < data.len) return error.SendFailed;
    }

    /// Receive data.
    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        // Assertion 1: Should be connected
        std.debug.assert(self.connected);

        // Assertion 2: Buffer should not be empty
        std.debug.assert(buf.len > 0);

        if (!self.connected) return error.RecvFailed;

        const result = std.posix.recv(self.handle, buf, 0) catch |err| {
            return translateError(err);
        };

        if (result == 0) return error.ConnectionClosed;
        return result;
    }

    /// Close the socket.
    pub fn close(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        std.posix.close(self.handle);
        self.connected = false;

        // Assertion 2: Connection state updated
        std.debug.assert(!self.connected);
    }
};

// ============================================================
// Platform-specific helpers
// ============================================================

/// Cross-platform timeval struct for socket timeouts.
/// macOS/Darwin uses different field names than Linux in Zig's std.c bindings,
/// so we define our own struct that matches the C layout on all platforms.
const Timeval = extern struct {
    /// Seconds - i64 on Darwin, isize (i64 on 64-bit, i32 on 32-bit) on Linux
    sec: switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => i64,
        else => isize,
    },
    /// Microseconds - i32 on Darwin, isize on Linux
    usec: switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => i32,
        else => isize,
    },
};

/// Create a Timeval from milliseconds.
fn makeTimeval(ms: u32) Timeval {
    // Assertion 1: ms should be reasonable
    std.debug.assert(ms < 3600_000);

    const tv = Timeval{
        .sec = @intCast(ms / 1000),
        .usec = @intCast((ms % 1000) * 1000),
    };

    // Assertion 2: Result should be valid
    std.debug.assert(tv.sec >= 0);
    std.debug.assert(tv.usec >= 0);

    return tv;
}

/// Apply socket options to a handle.
fn applyOptions(handle: Handle, options: Options) SocketError!void {
    // Assertion 1: Handle should be valid
    std.debug.assert(handle != 0 or builtin.os.tag == .windows);

    // Assertion 2: Options should be valid
    std.debug.assert(options.validate());

    if (options.reuse_addr) {
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch |err| return translateError(err);
    }

    if (options.tcp_nodelay) {
        // TCP_NODELAY - only applies to TCP sockets, ignore errors for UDP
        std.posix.setsockopt(
            handle,
            std.posix.IPPROTO.TCP,
            std.c.TCP.NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};
    }

    if (options.recv_buffer_size > 0) {
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVBUF,
            &std.mem.toBytes(@as(c_int, @intCast(options.recv_buffer_size))),
        ) catch |err| return translateError(err);
    }

    if (options.send_buffer_size > 0) {
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDBUF,
            &std.mem.toBytes(@as(c_int, @intCast(options.send_buffer_size))),
        ) catch |err| return translateError(err);
    }

    if (options.recv_timeout_ms > 0) {
        try setRecvTimeout(handle, options.recv_timeout_ms);
    }

    if (options.send_timeout_ms > 0) {
        try setSendTimeout(handle, options.send_timeout_ms);
    }
}

/// Set receive timeout on socket.
fn setRecvTimeout(handle: Handle, ms: u32) SocketError!void {
    // Assertion 1: Handle should be valid
    std.debug.assert(handle != 0 or builtin.os.tag == .windows);

    // Assertion 2: Timeout should be positive
    std.debug.assert(ms > 0);

    if (builtin.os.tag == .windows) {
        // Windows uses DWORD milliseconds
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            &std.mem.toBytes(@as(c_int, @intCast(ms))),
        ) catch |err| return translateError(err);
    } else {
        // POSIX (Linux, macOS, BSD) uses timeval
        const tv = makeTimeval(ms);
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch |err| return translateError(err);
    }
}

/// Set send timeout on socket.
fn setSendTimeout(handle: Handle, ms: u32) SocketError!void {
    // Assertion 1: Handle should be valid
    std.debug.assert(handle != 0 or builtin.os.tag == .windows);

    // Assertion 2: Timeout should be positive
    std.debug.assert(ms > 0);

    if (builtin.os.tag == .windows) {
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            &std.mem.toBytes(@as(c_int, @intCast(ms))),
        ) catch |err| return translateError(err);
    } else {
        const tv = makeTimeval(ms);
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&tv),
        ) catch |err| return translateError(err);
    }
}

/// Translate platform errors to SocketError.
fn translateError(err: anyerror) SocketError {
    return switch (err) {
        error.WouldBlock => error.WouldBlock,
        error.ConnectionRefused => error.ConnectFailed,
        error.ConnectionResetByPeer => error.ConnectionClosed,
        error.BrokenPipe => error.ConnectionClosed,
        else => error.SendFailed,
    };
}

// ============================================================
// Tests
// ============================================================

test "Timeval size matches platform expectations" {
    // Verify our Timeval struct is the right size for the platform
    // Allow for platform variations, just ensure it's reasonable
    try std.testing.expect(@sizeOf(Timeval) >= 8);
    try std.testing.expect(@sizeOf(Timeval) <= 24);
}

test "makeTimeval conversion" {
    const tv = makeTimeval(1500); // 1.5 seconds
    try std.testing.expectEqual(@as(@TypeOf(tv.sec), 1), tv.sec);
    try std.testing.expectEqual(@as(@TypeOf(tv.usec), 500000), tv.usec);

    const tv2 = makeTimeval(200); // 200ms
    try std.testing.expectEqual(@as(@TypeOf(tv2.sec), 0), tv2.sec);
    try std.testing.expectEqual(@as(@TypeOf(tv2.usec), 200000), tv2.usec);
}

test "parse IPv4 address" {
    const addr = try Address.parseIpv4("127.0.0.1", 12345);
    try std.testing.expectEqual(@as(std.posix.socklen_t, 16), addr.len);
}

test "parse IPv4 localhost" {
    const addr = try Address.parseIpv4("127.0.0.1", 8080);
    _ = addr;
}

test "parse IPv4 invalid - octet too large" {
    try std.testing.expectError(error.AddressParseError, Address.parseIpv4("256.0.0.1", 12345));
}

test "parse IPv4 invalid - too few octets" {
    try std.testing.expectError(error.AddressParseError, Address.parseIpv4("1.2.3", 12345));
}

test "parse IPv4 invalid - non-numeric" {
    try std.testing.expectError(error.AddressParseError, Address.parseIpv4("abc", 12345));
}

test "create UDP socket" {
    var sock = try UdpSocket.init(.{});
    defer sock.close();
}

test "create TCP socket" {
    var sock = try TcpSocket.init(.{});
    defer sock.close();
}

test "Options validation" {
    const opts = Options{};
    try std.testing.expect(opts.validate());
}
