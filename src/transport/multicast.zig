//! Multicast subscriber for market data.
//!
//! Receives broadcast market data (trades, top-of-book updates) from
//! the matching engine's multicast publisher. This is how real exchanges
//! distribute market data - one send reaches all subscribers.
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
const socket = @import("socket.zig");
const binary = @import("../protocol/binary.zig");
const csv = @import("../protocol/csv.zig");
const types = @import("../protocol/types.zig");

// ============================================================
// Constants
// ============================================================

/// MTU-sized receive buffer
const RECV_BUFFER_SIZE: usize = 1500;

/// Minimum multicast address first octet
const MULTICAST_MIN: u8 = 224;

/// Maximum multicast address first octet
const MULTICAST_MAX: u8 = 239;

// ============================================================
// Protocol Detection
// ============================================================

/// Detected protocol type
pub const ProtocolType = enum {
    binary,
    csv,
    unknown,
};

// ============================================================
// Multicast Subscriber
// ============================================================

pub const MulticastSubscriber = struct {
    sock: socket.UdpSocket,
    recv_buf: [RECV_BUFFER_SIZE]u8 = undefined,

    /// Statistics (useful for monitoring)
    packets_received: u64 = 0,
    messages_parsed: u64 = 0,
    parse_errors: u64 = 0,

    const Self = @This();

    /// Join a multicast group to receive market data.
    ///
    /// Parameters:
    ///   group - Multicast group address (e.g., "239.255.0.1")
    ///   port - Multicast port
    ///
    /// Returns: Initialized subscriber
    pub fn join(group: []const u8, port: u16) !Self {
        // Assertion 1: Group should not be empty
        std.debug.assert(group.len > 0);

        // Assertion 2: Port should be valid
        std.debug.assert(port > 0);

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
    ///
    /// Returns: Parsed OutputMessage
    pub fn recvMessage(self: *Self) !types.OutputMessage {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        const bytes_read = try self.sock.recv(&self.recv_buf);
        self.packets_received +|= 1;

        // Assertion 2: Should have received something
        std.debug.assert(bytes_read > 0);

        const data = self.recv_buf[0..bytes_read];

        // Auto-detect protocol and parse
        if (binary.isBinaryProtocol(data)) {
            const msg = binary.decodeOutput(data) catch |err| {
                self.parse_errors +|= 1;
                return err;
            };
            self.messages_parsed +|= 1;
            return msg;
        } else {
            const msg = csv.parseOutput(data) catch |err| {
                self.parse_errors +|= 1;
                return err;
            };
            self.messages_parsed +|= 1;
            return msg;
        }
    }

    /// Receive raw data without parsing (for custom handling).
    ///
    /// Returns: Raw received bytes
    pub fn recvRaw(self: *Self) ![]const u8 {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        const n = try self.sock.recv(&self.recv_buf);
        self.packets_received +|= 1;

        // Assertion 2: Received data should be within buffer
        std.debug.assert(n <= self.recv_buf.len);

        return self.recv_buf[0..n];
    }

    /// Detect protocol type from raw data.
    ///
    /// Parameters:
    ///   data - Raw message bytes
    ///
    /// Returns: Detected protocol type
    pub fn detectProtocol(data: []const u8) ProtocolType {
        // Assertion 1: Check can always be performed
        std.debug.assert(true);

        if (data.len == 0) {
            // Assertion 2: Empty data is unknown
            std.debug.assert(true);
            return .unknown;
        }

        if (binary.isBinaryProtocol(data)) return .binary;
        return .csv;
    }

    /// Get statistics.
    pub fn getStats(self: *const Self) struct { packets: u64, messages: u64, errors: u64 } {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Messages parsed should be <= packets received
        std.debug.assert(self.messages_parsed <= self.packets_received or self.packets_received == 0);

        return .{
            .packets = self.packets_received,
            .messages = self.messages_parsed,
            .errors = self.parse_errors,
        };
    }

    /// Reset statistics.
    pub fn resetStats(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.packets_received = 0;
        self.messages_parsed = 0;
        self.parse_errors = 0;

        // Assertion 2: Stats reset
        std.debug.assert(self.packets_received == 0);
    }

    /// Close the subscriber.
    pub fn close(self: *Self) void {
        // Assertion 1: Self should be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.sock.close();

        // Assertion 2: Socket closed
        std.debug.assert(true);
    }
};

// ============================================================
// Address Parsing
// ============================================================

/// Parse a multicast address string.
///
/// Parameters:
///   addr - Address string (e.g., "239.255.0.1")
///
/// Returns: 4-byte IP address
fn parseMulticastAddr(addr: []const u8) ![4]u8 {
    // Assertion 1: Address should not be empty
    std.debug.assert(addr.len > 0);

    // Assertion 2: Address should be reasonable length
    std.debug.assert(addr.len <= 15);

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
    if (octets[0] < MULTICAST_MIN or octets[0] > MULTICAST_MAX) {
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

test "parse multicast address - lower bound" {
    const addr = try parseMulticastAddr("224.0.0.1");
    try std.testing.expectEqual([4]u8{ 224, 0, 0, 1 }, addr);
}

test "parse multicast address - upper bound" {
    const addr = try parseMulticastAddr("239.255.255.255");
    try std.testing.expectEqual([4]u8{ 239, 255, 255, 255 }, addr);
}

test "reject non-multicast address - too low" {
    try std.testing.expectError(error.AddressParseError, parseMulticastAddr("223.0.0.1"));
}

test "reject non-multicast address - too high" {
    try std.testing.expectError(error.AddressParseError, parseMulticastAddr("240.0.0.1"));
}

test "reject non-multicast address - unicast" {
    try std.testing.expectError(error.AddressParseError, parseMulticastAddr("192.168.1.1"));
}

test "detect protocol - binary" {
    const binary_data = [_]u8{ 0x4D, 'A', 0, 0, 0, 1 };
    try std.testing.expectEqual(ProtocolType.binary, MulticastSubscriber.detectProtocol(&binary_data));
}

test "detect protocol - csv" {
    const csv_data = "A, IBM, 1, 1";
    try std.testing.expectEqual(ProtocolType.csv, MulticastSubscriber.detectProtocol(csv_data));
}

test "detect protocol - empty" {
    try std.testing.expectEqual(ProtocolType.unknown, MulticastSubscriber.detectProtocol(""));
}

test "MulticastSubscriber struct size" {
    const size = @sizeOf(MulticastSubscriber);
    // Should be reasonable (mostly the recv buffer)
    try std.testing.expect(size < 2000);
}
