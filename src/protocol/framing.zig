//! TCP Length-Prefix Framing Protocol
//!
//! # Overview
//! TCP is a stream protocol with no message boundaries. We use a simple
//! 4-byte big-endian length prefix to delimit messages:
//!
//! ```
//! ┌────────────────────┬──────────────────────────────────────┐
//! │ Length (4B BE)     │ Payload (N bytes)                    │
//! └────────────────────┴──────────────────────────────────────┘
//! ```
//!
//! This matches the C server's TCP framing exactly.
//!
//! # Frame Reader State Machine
//! ```
//!                     ┌─────────────────┐
//!                     │      IDLE       │
//!                     └────────┬────────┘
//!                              │ recv()
//!                              ▼
//!                     ┌─────────────────┐
//!          ┌──────────│ READING_HEADER  │◄─────────┐
//!          │          └────────┬────────┘          │
//!          │                   │                   │
//!          │ < 4 bytes         │ >= 4 bytes        │
//!          │                   ▼                   │
//!          │          ┌─────────────────┐          │
//!          │          │ READING_PAYLOAD │          │
//!          │          └────────┬────────┘          │
//!          │                   │                   │
//!          │ < len bytes       │ >= len bytes      │
//!          │                   ▼                   │
//!          │          ┌─────────────────┐          │
//!          └─────────►│ MESSAGE_READY   ├──────────┘
//!                     └─────────────────┘
//!                              │
//!                              ▼
//!                       Return message
//! ```
//!
//! # Power of Ten Compliance
//! - Rule 2: All loops bounded
//! - Rule 3: No dynamic allocation (fixed buffer)
//! - Rule 4: Functions ≤60 lines
//! - Rule 5: ≥2 assertions per function
//! - Rule 7: All return values checked

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Size of the length prefix header (4 bytes, big-endian).
pub const HEADER_SIZE: usize = 4;

/// Maximum allowed message size (16KB).
/// Messages larger than this are rejected as protocol errors.
/// This prevents memory exhaustion from malformed/malicious frames.
pub const MAX_MESSAGE_SIZE: usize = 16384;

/// Total buffer size needed: header + max payload.
pub const BUFFER_SIZE: usize = HEADER_SIZE + MAX_MESSAGE_SIZE;

// =============================================================================
// Error Types
// =============================================================================

pub const FramingError = error{
    /// Message payload exceeds MAX_MESSAGE_SIZE
    MessageTooLarge,
    /// Header indicates more bytes than available
    IncompleteHeader,
    /// Payload not fully received yet
    IncompletePayload,
    /// Output buffer too small for framed message
    BufferTooSmall,
    /// Length field is zero (invalid frame)
    ZeroLengthMessage,
    /// Internal buffer corruption detected
    BufferCorruption,
};

// =============================================================================
// Frame Encoding
// =============================================================================

/// Encode a message with length prefix into buffer.
///
/// # Arguments
/// - `payload`: Message bytes to frame
/// - `buf`: Output buffer (must be at least HEADER_SIZE + payload.len)
///
/// # Returns
/// Slice containing `[length_header][payload]`.
///
/// # Wire Format
/// ```
/// ┌──────────────┬─────────────────────────────────────────────┐
/// │ 00 00 00 1E  │ <payload bytes>                             │
/// │ (length=30)  │                                             │
/// └──────────────┴─────────────────────────────────────────────┘
/// ```
pub fn encode(payload: []const u8, buf: []u8) FramingError![]const u8 {
    // Pre-conditions (Power of Ten Rule 5)
    std.debug.assert(buf.len > 0);

    if (payload.len > MAX_MESSAGE_SIZE) return FramingError.MessageTooLarge;
    if (payload.len == 0) return FramingError.ZeroLengthMessage;

    const total_size = HEADER_SIZE + payload.len;
    if (buf.len < total_size) return FramingError.BufferTooSmall;

    // Write 4-byte big-endian length header
    const len_u32: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, buf[0..4], len_u32, .big);

    // Copy payload
    @memcpy(buf[HEADER_SIZE..total_size], payload);

    // Post-condition: verify header
    std.debug.assert(std.mem.readInt(u32, buf[0..4], .big) == payload.len);

    return buf[0..total_size];
}

/// Calculate the framed size of a payload.
/// Useful for pre-allocating exact buffer sizes.
pub fn framedSize(payload_len: usize) ?usize {
    if (payload_len > MAX_MESSAGE_SIZE) return null;
    if (payload_len == 0) return null;
    return HEADER_SIZE + payload_len;
}

// =============================================================================
// Frame Reader (State Machine)
// =============================================================================

/// Frame reader state machine for parsing length-prefixed messages from a stream.
///
/// # Usage
/// ```zig
/// var reader = FrameReader.init();
///
/// while (true) {
///     // Get writable portion of internal buffer
///     const write_buf = reader.getWriteBuffer();
///     if (write_buf.len == 0) {
///         // Buffer full - should not happen in normal operation
///         reader.reset();
///         continue;
///     }
///
///     // Receive data from socket
///     const n = socket.recv(write_buf);
///     if (n == 0) break; // Connection closed
///
///     // Advance write position
///     reader.advance(n);
///
///     // Extract all complete messages
///     while (reader.nextMessage()) |msg| {
///         processMessage(msg);
///     }
/// }
/// ```
///
/// # Thread Safety
/// NOT thread-safe. Use from a single thread only.
pub const FrameReader = struct {
    /// Internal buffer for accumulating partial frames.
    buf: [BUFFER_SIZE]u8 = undefined,

    /// Current write position (end of received data).
    write_pos: usize = 0,

    /// Current read position (start of unprocessed data).
    read_pos: usize = 0,

    /// Count of protocol errors (for monitoring).
    error_count: u64 = 0,

    /// Count of messages successfully parsed.
    message_count: u64 = 0,

    const Self = @This();

    /// Initialize a new frame reader.
    pub fn init() Self {
        return .{};
    }

    /// Get buffer slice for writing incoming data.
    ///
    /// This performs buffer compaction if needed to maximize available space.
    ///
    /// # Returns
    /// Writable slice at end of buffer. May be empty if buffer is full.
    pub fn getWriteBuffer(self: *Self) []u8 {
        // Pre-conditions (Power of Ten Rule 5)
        std.debug.assert(self.write_pos <= BUFFER_SIZE);
        std.debug.assert(self.read_pos <= self.write_pos);

        // Compact buffer if we've consumed data and need space
        if (self.read_pos > 0) {
            const remaining = self.write_pos - self.read_pos;

            if (remaining > 0) {
                // Move unprocessed data to start of buffer
                std.mem.copyForwards(
                    u8,
                    self.buf[0..remaining],
                    self.buf[self.read_pos..self.write_pos],
                );
            }

            self.write_pos = remaining;
            self.read_pos = 0;
        }

        // Post-condition: read_pos is now 0
        std.debug.assert(self.read_pos == 0);

        return self.buf[self.write_pos..];
    }

    /// Advance write position after receiving data.
    ///
    /// # Arguments
    /// - `bytes_received`: Number of bytes written to buffer from getWriteBuffer()
    pub fn advance(self: *Self, bytes_received: usize) void {
        // Pre-conditions (Power of Ten Rule 5)
        std.debug.assert(self.write_pos + bytes_received <= BUFFER_SIZE);
        std.debug.assert(bytes_received > 0 or self.write_pos < BUFFER_SIZE);

        self.write_pos += bytes_received;

        // Post-condition
        std.debug.assert(self.write_pos <= BUFFER_SIZE);
    }

    /// Try to extract the next complete message.
    ///
    /// Call this in a loop after each `advance()` to extract all available messages.
    ///
    /// # Returns
    /// - Message payload slice if a complete message is available
    /// - `null` if not enough data yet
    ///
    /// # Errors
    /// Returns `null` and increments `error_count` if a protocol error is detected
    /// (e.g., message too large). The buffer is reset on protocol errors.
    pub fn nextMessage(self: *Self) ?[]const u8 {
        // Pre-conditions (Power of Ten Rule 5)
        std.debug.assert(self.read_pos <= self.write_pos);
        std.debug.assert(self.write_pos <= BUFFER_SIZE);

        const available = self.write_pos - self.read_pos;

        // Need at least header to determine message length
        if (available < HEADER_SIZE) return null;

        // Read message length from header
        const header_bytes = self.buf[self.read_pos..][0..HEADER_SIZE];
        const msg_len = std.mem.readInt(u32, header_bytes, .big);

        // Validate message length
        if (msg_len == 0) {
            // Zero-length message is a protocol error
            self.error_count += 1;
            self.reset();
            return null;
        }

        if (msg_len > MAX_MESSAGE_SIZE) {
            // Message too large - protocol error or corruption
            self.error_count += 1;
            self.reset();
            return null;
        }

        // Check if full message is available
        const total_needed = HEADER_SIZE + msg_len;
        if (available < total_needed) return null;

        // Extract message payload (skip header)
        const msg_start = self.read_pos + HEADER_SIZE;
        const msg_end = msg_start + msg_len;
        const msg = self.buf[msg_start..msg_end];

        // Advance read position past this message
        self.read_pos += total_needed;
        self.message_count += 1;

        // Post-condition
        std.debug.assert(self.read_pos <= self.write_pos);

        return msg;
    }

    /// Reset reader state, discarding any buffered data.
    ///
    /// Call this on connection reset or after protocol errors.
    pub fn reset(self: *Self) void {
        self.write_pos = 0;
        self.read_pos = 0;

        // Post-condition
        std.debug.assert(!self.hasPendingData());
    }

    /// Check if there's unprocessed data in the buffer.
    pub fn hasPendingData(self: *const Self) bool {
        return self.write_pos > self.read_pos;
    }

    /// Get number of bytes waiting to be processed.
    pub fn pendingBytes(self: *const Self) usize {
        std.debug.assert(self.write_pos >= self.read_pos);
        return self.write_pos - self.read_pos;
    }

    /// Get statistics for monitoring.
    pub const Stats = struct {
        messages_parsed: u64,
        protocol_errors: u64,
        pending_bytes: usize,
        buffer_utilization: f32,
    };

    pub fn getStats(self: *const Self) Stats {
        return .{
            .messages_parsed = self.message_count,
            .protocol_errors = self.error_count,
            .pending_bytes = self.pendingBytes(),
            .buffer_utilization = @as(f32, @floatFromInt(self.write_pos)) /
                @as(f32, @floatFromInt(BUFFER_SIZE)),
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

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

    // Check total length
    try std.testing.expectEqual(@as(usize, 9), encoded.len);
}

test "encode message too large" {
    var buf: [100]u8 = undefined;
    var large_payload: [MAX_MESSAGE_SIZE + 1]u8 = undefined;
    @memset(&large_payload, 'X');

    try std.testing.expectError(FramingError.MessageTooLarge, encode(&large_payload, &buf));
}

test "encode zero length message" {
    var buf: [100]u8 = undefined;
    const empty: []const u8 = "";

    try std.testing.expectError(FramingError.ZeroLengthMessage, encode(empty, &buf));
}

test "encode buffer too small" {
    var small_buf: [6]u8 = undefined;
    const payload = "Hello"; // 5 bytes + 4 header = 9 needed

    try std.testing.expectError(FramingError.BufferTooSmall, encode(payload, &small_buf));
}

test "framedSize" {
    try std.testing.expectEqual(@as(?usize, 9), framedSize(5));
    try std.testing.expectEqual(@as(?usize, HEADER_SIZE + 100), framedSize(100));
    try std.testing.expectEqual(@as(?usize, null), framedSize(0));
    try std.testing.expectEqual(@as(?usize, null), framedSize(MAX_MESSAGE_SIZE + 1));
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
    try std.testing.expect(!reader.hasPendingData());
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
    try std.testing.expect(reader.hasPendingData());

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

    // Message 1: "Hi" (2 bytes)
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 2;
    buf[4] = 'H';
    buf[5] = 'i';

    // Message 2: "Bye" (3 bytes)
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
    try std.testing.expectEqual(@as(u64, 2), reader.message_count);
}

test "frame reader handles oversized message" {
    var reader = FrameReader.init();

    var buf = reader.getWriteBuffer();

    // Write a header claiming a too-large message
    const fake_len: u32 = MAX_MESSAGE_SIZE + 1;
    std.mem.writeInt(u32, buf[0..4], fake_len, .big);
    reader.advance(4);

    // Should return null and increment error count
    try std.testing.expect(reader.nextMessage() == null);
    try std.testing.expectEqual(@as(u64, 1), reader.error_count);

    // Buffer should be reset
    try std.testing.expect(!reader.hasPendingData());
}

test "frame reader handles zero length message" {
    var reader = FrameReader.init();

    var buf = reader.getWriteBuffer();

    // Write header with zero length
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 0;
    reader.advance(4);

    // Should return null and increment error count
    try std.testing.expect(reader.nextMessage() == null);
    try std.testing.expectEqual(@as(u64, 1), reader.error_count);
}

test "frame reader buffer compaction" {
    var reader = FrameReader.init();

    // Fill buffer with a message
    var buf = reader.getWriteBuffer();
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 4;
    @memcpy(buf[4..8], "Test");
    reader.advance(8);

    // Consume the message
    _ = reader.nextMessage();

    // Get write buffer again - should compact
    buf = reader.getWriteBuffer();

    // Should have full buffer available now
    try std.testing.expectEqual(BUFFER_SIZE, buf.len);
}

test "frame reader statistics" {
    var reader = FrameReader.init();

    // Parse a message
    var buf = reader.getWriteBuffer();
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 3;
    @memcpy(buf[4..7], "ABC");
    reader.advance(7);

    _ = reader.nextMessage();

    const stats = reader.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats.messages_parsed);
    try std.testing.expectEqual(@as(u64, 0), stats.protocol_errors);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_bytes);
}

test "frame reader reset" {
    var reader = FrameReader.init();

    // Add some data
    var buf = reader.getWriteBuffer();
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 0;
    buf[3] = 100; // Partial message
    reader.advance(4);

    try std.testing.expect(reader.hasPendingData());

    // Reset
    reader.reset();

    try std.testing.expect(!reader.hasPendingData());
    try std.testing.expectEqual(@as(usize, 0), reader.pendingBytes());
}
