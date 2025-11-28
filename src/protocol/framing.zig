//! TCP length-prefix framing protocol.
//!
//! TCP is a stream protocol with no message boundaries. We use a simple
//! 4-byte big-endian length prefix to delimit messages:
//!
//!   +----------------+------------------+
//!   | Length (4B BE) | Payload (N bytes)|
//!   +----------------+------------------+
//!
//! This matches the C server's TCP framing exactly.

const std = @import("std");

pub const HEADER_SIZE: usize = 4;
pub const MAX_MESSAGE_SIZE: usize = 16384; // 16KB max message

pub const FramingError = error{
    MessageTooLarge,
    IncompleteHeader,
    IncompletePayload,
    BufferTooSmall,
};

/// Encode a message with length prefix into buffer.
/// Returns slice containing [length_header][payload].
pub fn encode(payload: []const u8, buf: []u8) FramingError![]const u8 {
    if (payload.len > MAX_MESSAGE_SIZE) return FramingError.MessageTooLarge;
    if (buf.len < HEADER_SIZE + payload.len) return FramingError.BufferTooSmall;

    // Write 4-byte big-endian length header
    const len_u32: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, buf[0..4], len_u32, .big);

    // Copy payload
    @memcpy(buf[HEADER_SIZE .. HEADER_SIZE + payload.len], payload);

    return buf[0 .. HEADER_SIZE + payload.len];
}

/// Frame reader state machine for parsing length-prefixed messages from a stream.
///
/// Usage:
///   var reader = FrameReader.init();
///   while (true) {
///       const n = socket.recv(reader.getWriteBuffer());
///       reader.advance(n);
///       while (reader.nextMessage()) |msg| {
///           processMessage(msg);
///       }
///   }
pub const FrameReader = struct {
    buf: [MAX_MESSAGE_SIZE + HEADER_SIZE]u8 = undefined,
    write_pos: usize = 0,
    read_pos: usize = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Get buffer slice for writing incoming data.
    pub fn getWriteBuffer(self: *Self) []u8 {
        // Compact buffer if we've consumed data
        if (self.read_pos > 0 and self.write_pos > self.read_pos) {
            const remaining = self.write_pos - self.read_pos;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[self.read_pos..self.write_pos]);
            self.write_pos = remaining;
            self.read_pos = 0;
        } else if (self.read_pos > 0 and self.write_pos == self.read_pos) {
            self.write_pos = 0;
            self.read_pos = 0;
        }

        return self.buf[self.write_pos..];
    }

    /// Advance write position after receiving data.
    pub fn advance(self: *Self, bytes_received: usize) void {
        self.write_pos += bytes_received;
    }

    /// Try to extract the next complete message.
    /// Returns null if not enough data available.
    pub fn nextMessage(self: *Self) ?[]const u8 {
        const available = self.write_pos - self.read_pos;

        // Need at least header
        if (available < HEADER_SIZE) return null;

        // Read message length from header
        const len_bytes = self.buf[self.read_pos..][0..4];
        const msg_len = std.mem.readInt(u32, len_bytes, .big);

        // Sanity check
        if (msg_len > MAX_MESSAGE_SIZE) {
            // Protocol error - reset state
            self.write_pos = 0;
            self.read_pos = 0;
            return null;
        }

        // Check if full message available
        const total_needed = HEADER_SIZE + msg_len;
        if (available < total_needed) return null;

        // Extract message
        const msg_start = self.read_pos + HEADER_SIZE;
        const msg_end = msg_start + msg_len;
        const msg = self.buf[msg_start..msg_end];

        // Advance read position
        self.read_pos += total_needed;

        return msg;
    }

    /// Reset reader state.
    pub fn reset(self: *Self) void {
        self.write_pos = 0;
        self.read_pos = 0;
    }

    /// Check if there's pending data.
    pub fn hasPendingData(self: *const Self) bool {
        return self.write_pos > self.read_pos;
    }
};

// ============================================================
// Tests
// ============================================================

test "encode message with length prefix" {
    var buf: [256]u8 = undefined;
    const payload = "Hello";

    const encoded = try encode(payload, &buf);

    // Check length header (big-endian)
    try std.testing.expectEqual(@as(u8, 0), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0), encoded[1]);
    try std.testing.expectEqual(@as(u8, 0), encoded[2]);
    try std.testing.expectEqual(@as(u8, 5), encoded[3]);

    // Check payload
    try std.testing.expectEqualStrings("Hello", encoded[4..9]);
}

test "frame reader single message" {
    var reader = FrameReader.init();

    // Simulate receiving a framed message
    const write_buf = reader.getWriteBuffer();

    // Write length header (5 bytes)
    write_buf[0] = 0;
    write_buf[1] = 0;
    write_buf[2] = 0;
    write_buf[3] = 5;

    // Write payload
    @memcpy(write_buf[4..9], "Hello");

    reader.advance(9);

    // Should extract message
    const msg = reader.nextMessage();
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("Hello", msg.?);

    // No more messages
    try std.testing.expect(reader.nextMessage() == null);
}

test "frame reader partial message" {
    var reader = FrameReader.init();

    // First receive: just the header
    var buf = reader.getWriteBuffer();
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 10;
    reader.advance(4);

    // Should return null (incomplete)
    try std.testing.expect(reader.nextMessage() == null);

    // Second receive: partial payload
    buf = reader.getWriteBuffer();
    @memcpy(buf[0..5], "Hello");
    reader.advance(5);

    // Still incomplete
    try std.testing.expect(reader.nextMessage() == null);

    // Third receive: rest of payload
    buf = reader.getWriteBuffer();
    @memcpy(buf[0..5], "World");
    reader.advance(5);

    // Now complete
    const msg = reader.nextMessage();
    try std.testing.expect(msg != null);
    try std.testing.expectEqualStrings("HelloWorld", msg.?);
}

test "frame reader multiple messages" {
    var reader = FrameReader.init();

    // Write two messages at once
    var buf = reader.getWriteBuffer();

    // Message 1: "Hi"
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 2;
    buf[4] = 'H';
    buf[5] = 'i';

    // Message 2: "Bye"
    buf[6] = 0;
    buf[7] = 0;
    buf[8] = 0;
    buf[9] = 3;
    buf[10] = 'B';
    buf[11] = 'y';
    buf[12] = 'e';

    reader.advance(13);

    // Should extract both messages
    const msg1 = reader.nextMessage();
    try std.testing.expectEqualStrings("Hi", msg1.?);

    const msg2 = reader.nextMessage();
    try std.testing.expectEqualStrings("Bye", msg2.?);

    try std.testing.expect(reader.nextMessage() == null);
}

test "encode message too large" {
    var buf: [100]u8 = undefined;
    var large_payload: [MAX_MESSAGE_SIZE + 1]u8 = undefined;

    try std.testing.expectError(FramingError.MessageTooLarge, encode(&large_payload, &buf));
}
