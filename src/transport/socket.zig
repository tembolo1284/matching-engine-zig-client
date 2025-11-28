//! Cross-platform socket abstraction.
//!
//! Provides a unified interface over POSIX sockets (Linux/macOS) and
//! Winsock (Windows). Zig's std.posix handles most of this, but we add
//! some convenience wrappers and platform-specific options.

const std = @import("std");
const builtin = @import("builtin");

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
    recv_buffer_size: u32 = 0,

    /// Send buffer size (0 = system default)
    send_buffer_size: u32 = 0,
};

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

/// IPv4 address wrapper
pub const Address = struct {
    inner: std.posix.sockaddr,
    len: std.posix.socklen_t,

    pub fn initIpv4(ip: [4]u8, port: u16) Address {
        const addr = std.net.Address.initIp4(ip, port);
        return .{
            .inner = addr.any,
            .len = 16, // sizeof(sockaddr_in) is always 16 bytes
        };
    }

    pub fn parseIpv4(host: []const u8, port: u16) !Address {
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
};

/// UDP socket wrapper
pub const UdpSocket = struct {
    handle: Handle,
    target_addr: ?Address = null,

    const Self = @This();

    pub fn init(options: Options) SocketError!Self {
        const handle = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            0,
        );
        errdefer std.posix.close(handle);

        try applyOptions(handle, options);

        return .{ .handle = handle };
    }

    /// Bind to local address for receiving
    pub fn bind(self: *Self, addr: Address) SocketError!void {
        std.posix.bind(self.handle, &addr.inner, addr.len) catch |err| {
            return translateError(err);
        };
    }

    /// Set target address for send()
    pub fn setTarget(self: *Self, addr: Address) void {
        self.target_addr = addr;
    }

    /// Send data to target address
    pub fn send(self: *Self, data: []const u8) SocketError!usize {
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

    /// Receive data
    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        const result = std.posix.recvfrom(
            self.handle,
            buf,
            0,
            null,
            null,
        ) catch |err| return translateError(err);

        return result;
    }

    /// Join a multicast group
    pub fn joinMulticastGroup(self: *Self, group: [4]u8) SocketError!void {
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
    }

    pub fn close(self: *Self) void {
        std.posix.close(self.handle);
    }
};

/// TCP socket wrapper
pub const TcpSocket = struct {
    handle: Handle,
    connected: bool = false,

    const Self = @This();

    pub fn init(options: Options) SocketError!Self {
        const handle = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM,
            0,
        );
        errdefer std.posix.close(handle);

        try applyOptions(handle, options);

        return .{ .handle = handle };
    }

    /// Connect to remote address
    pub fn connect(self: *Self, addr: Address) SocketError!void {
        std.posix.connect(self.handle, &addr.inner, addr.len) catch |err| {
            return translateError(err);
        };
        self.connected = true;
    }

    /// Send data
    pub fn send(self: *Self, data: []const u8) SocketError!usize {
        if (!self.connected) return error.SendFailed;

        return std.posix.send(self.handle, data, 0) catch |err| translateError(err);
    }

    /// Send all data (loops until complete)
    pub fn sendAll(self: *Self, data: []const u8) SocketError!void {
        var sent: usize = 0;
        const max_attempts = 1000; // Bounded loop
        var attempts: usize = 0;

        while (sent < data.len and attempts < max_attempts) : (attempts += 1) {
            const n = try self.send(data[sent..]);
            if (n == 0) return error.ConnectionClosed;
            sent += n;
        }

        if (sent < data.len) return error.SendFailed;
    }

    /// Receive data
    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        if (!self.connected) return error.RecvFailed;

        const result = std.posix.recv(self.handle, buf, 0) catch |err| {
            return translateError(err);
        };

        if (result == 0) return error.ConnectionClosed;
        return result;
    }

    pub fn close(self: *Self) void {
        std.posix.close(self.handle);
        self.connected = false;
    }
};

// ============================================================
// Platform-specific helpers
// ============================================================

fn applyOptions(handle: Handle, options: Options) SocketError!void {
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

    // Timeouts - platform specific
    if (options.recv_timeout_ms > 0) {
        try setRecvTimeout(handle, options.recv_timeout_ms);
    }

    if (options.send_timeout_ms > 0) {
        try setSendTimeout(handle, options.send_timeout_ms);
    }
}

fn setRecvTimeout(handle: Handle, ms: u32) SocketError!void {
    if (builtin.os.tag == .windows) {
        // Windows uses DWORD milliseconds
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            &std.mem.toBytes(@as(c_int, @intCast(ms))),
        ) catch |err| return translateError(err);
    } else {
        // POSIX uses timeval
        const tv = std.posix.timeval{
            .tv_sec = @intCast(ms / 1000),
            .tv_usec = @intCast((ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch |err| return translateError(err);
    }
}

fn setSendTimeout(handle: Handle, ms: u32) SocketError!void {
    if (builtin.os.tag == .windows) {
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            &std.mem.toBytes(@as(c_int, @intCast(ms))),
        ) catch |err| return translateError(err);
    } else {
        const tv = std.posix.timeval{
            .tv_sec = @intCast(ms / 1000),
            .tv_usec = @intCast((ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.SNDTIMEO,
            std.mem.asBytes(&tv),
        ) catch |err| return translateError(err);
    }
}

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

test "parse IPv4 address" {
    const addr = try Address.parseIpv4("127.0.0.1", 12345);
    _ = addr;
}

test "parse IPv4 invalid" {
    try std.testing.expectError(error.AddressParseError, Address.parseIpv4("256.0.0.1", 12345));
    try std.testing.expectError(error.AddressParseError, Address.parseIpv4("1.2.3", 12345));
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
