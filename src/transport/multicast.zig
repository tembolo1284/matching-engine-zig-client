//! Multicast subscriber for market data.
//!
//! Receives broadcast market data (trades, top-of-book updates) from
//! the matching engine's multicast publisher. This is how real exchanges
//! distribute market data - one send reaches all subscribers.

const std = @import("std");
const socket = @import("socket.zig");
const binary = @import("../protocol/binary.zig");
const csv = @import("../protocol/csv.zig");
const types = @import("../protocol/types.zig");

pub const MulticastSubscriber = struct {
    sock: socket.UdpSocket,
    recv_buf: [1500]u8 = undefined, // MTU-sized

    // Statistics (useful for monitoring)
    packets_received: u64 = 0,
    parse_errors: u64 = 0,

    const Self = @This();

    /// Join a multicast group to receive market data
    pub fn join(group: []const u8, port: u16) !Self {
        // Parse multicast group address
        const group_octets = try parseMulticastAddr(group);

        var sock = try socket.UdpSocket.init(.{
            .reuse_addr = true,
        });
        errdefer sock.close();

        // Bind to any address on the multicast port
        const bind_addr = socket.Address.initIpv4(.{ 0, 0, 0, 0 }, port);
        try sock.bind(bind_addr);

        // Join the multicast group
        try sock.joinMulticastGroup(group_octets);

        return .{ .sock = sock };
    }

    /// Receive and parse the next market data message.
    /// Blocks until data is available.
    pub fn recvMessage(self: *Self) !types.OutputMessage {
        const bytes_read = try self.sock.recv(&self.recv_buf);
        self.packets_received += 1;
        
        const data = self.recv_buf[0..bytes_read];

        // Auto-detect protocol and parse
        if (binary.isBinaryProtocol(data)) {
            return binary.decodeOutput(data) catch |err| {
                self.parse_errors += 1;
                return err;
            };
        } else {
            return csv.parseOutput(data) catch |err| {
                self.parse_errors += 1;
                return err;
            };
        }
    }

    /// Receive raw data without parsing (for custom handling)
    pub fn recvRaw(self: *Self) ![]const u8 {
        const n = try self.sock.recv(&self.recv_buf);
        self.packets_received += 1;
        return self.recv_buf[0..n];
    }

    /// Detect protocol type from raw data
    pub fn detectProtocol(data: []const u8) enum { binary, csv, unknown } {
        if (data.len == 0) return .unknown;
        if (binary.isBinaryProtocol(data)) return .binary;
        return .csv;
    }

    /// Get statistics
    pub fn getStats(self: *const Self) struct { packets: u64, errors: u64 } {
        return .{
            .packets = self.packets_received,
            .errors = self.parse_errors,
        };
    }

    /// Close the subscriber
    pub fn close(self: *Self) void {
        self.sock.close();
    }
};

fn parseMulticastAddr(addr: []const u8) ![4]u8 {
    var octets: [4]u8 = undefined;
    var idx: usize = 0;
    var octet: u16 = 0;

    for (addr) |c| {
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

    // Validate multicast range (224.0.0.0 - 239.255.255.255)
    if (octets[0] < 224 or octets[0] > 239) {
        return error.AddressParseError;
    }

    return octets;
}

// ============================================================
// Tests
// ============================================================

test "parse multicast address" {
    const addr = try parseMulticastAddr("239.255.0.1");
    try std.testing.expectEqual([4]u8{ 239, 255, 0, 1 }, addr);
}

test "reject non-multicast address" {
    try std.testing.expectError(error.AddressParseError, parseMulticastAddr("192.168.1.1"));
    try std.testing.expectError(error.AddressParseError, parseMulticastAddr("223.0.0.1"));
    try std.testing.expectError(error.AddressParseError, parseMulticastAddr("240.0.0.1"));
}

test "detect protocol" {
    const binary_data = [_]u8{ 0x4D, 'A', 0, 0, 0, 1 };
    const csv_data = "A, IBM, 1, 1";

    try std.testing.expectEqual(MulticastSubscriber.detectProtocol(&binary_data), .binary);
    try std.testing.expectEqual(MulticastSubscriber.detectProtocol(csv_data), .csv);
    try std.testing.expectEqual(MulticastSubscriber.detectProtocol(""), .unknown);
}
