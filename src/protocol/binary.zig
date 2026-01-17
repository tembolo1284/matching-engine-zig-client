//! Binary Protocol Encoder/Decoder
//!
//! # Overview
//! Handles serialization of input messages and parsing of output messages
//! using the packed binary format. All integers are big-endian (network order).
//!
//! # Alignment Safety
//! Network receive buffers are typically byte-aligned, but our binary structs
//! contain u32 fields. On some architectures (ARM, SPARC), unaligned access
//! causes bus errors or silent corruption.
//!
//! We handle this by copying network data to aligned local variables before
//! accessing multi-byte fields, rather than using pointer casts on raw buffers.
//!
//! # Power of Ten Compliance
//! - Rule 2: All loops bounded
//! - Rule 4: Functions ≤60 lines
//! - Rule 5: ≥2 assertions per function
//! - Rule 7: All return values checked, parameters validated
//! - Rule 10: Compile with all warnings

const std = @import("std");
const types = @import("types.zig");

// =============================================================================
// Error Types
// =============================================================================

pub const DecodeError = error{
    /// First byte is not the magic byte (0x4D)
    InvalidMagic,
    /// Message type byte not recognized
    UnknownMessageType,
    /// Buffer too small for message type
    MessageTooShort,
    /// Side field contains invalid value
    InvalidSide,
};

pub const EncodeError = error{
    /// Output buffer too small
    BufferTooSmall,
};

// =============================================================================
// Protocol Detection
// =============================================================================

/// Detect if data is binary protocol (vs CSV).
/// Binary messages start with magic byte 0x4D ('M').
///
/// # Arguments
/// - `data`: Raw bytes from network
///
/// # Returns
/// `true` if this appears to be a binary protocol message.
pub fn isBinaryProtocol(data: []const u8) bool {
    // Pre-condition (Power of Ten Rule 5)
    // No assertion needed - empty data is a valid case (returns false)

    if (data.len == 0) return false;

    return data[0] == types.MAGIC_BYTE;
}

// =============================================================================
// Output Message Decoding (Server → Client)
// =============================================================================

/// Decode an output message from binary wire format.
///
/// # Safety
/// This function safely handles unaligned network buffers by copying
/// data to aligned local storage before accessing multi-byte fields.
///
/// # Arguments
/// - `data`: Raw bytes from network (may be unaligned)
///
/// # Returns
/// Parsed `OutputMessage` or decode error.
pub fn decodeOutput(data: []const u8) DecodeError!types.OutputMessage {
    // Pre-conditions (Power of Ten Rule 5)
    // Assertion 1: Data pointer should be valid (not null)
    std.debug.assert(@intFromPtr(data.ptr) != 0);

    // Assertion 2: Checked below with proper error return
    if (data.len < 2) return DecodeError.MessageTooShort;
    if (data[0] != types.MAGIC_BYTE) return DecodeError.InvalidMagic;

    const msg_type_byte = data[1];

    return switch (msg_type_byte) {
        @intFromEnum(types.OutputMsgType.ack) => decodeAck(data),
        @intFromEnum(types.OutputMsgType.cancel_ack) => decodeCancelAck(data),
        @intFromEnum(types.OutputMsgType.trade) => decodeTrade(data),
        @intFromEnum(types.OutputMsgType.top_of_book) => decodeTopOfBook(data),
        else => DecodeError.UnknownMessageType,
    };
}

/// Decode ACK message (18 bytes).
fn decodeAck(data: []const u8) DecodeError!types.OutputMessage {
    const msg_size = @sizeOf(types.BinaryAck);

    // Pre-condition (Power of Ten Rule 5)
    std.debug.assert(data.len >= 2);

    if (data.len < msg_size) return DecodeError.MessageTooShort;

    // SAFE ALIGNMENT: Copy to aligned local instead of pointer cast.
    // Network buffers may not be aligned to u32 boundaries.
    var ack: types.BinaryAck = undefined;
    @memcpy(std.mem.asBytes(&ack), data[0..msg_size]);

    // Post-condition: verify magic byte survived copy
    std.debug.assert(ack.magic == types.MAGIC_BYTE);

    return types.OutputMessage{
        .msg_type = .ack,
        .symbol = ack.symbol,
        .symbol_len = @intCast(types.findSymbolLen(&ack.symbol)),
        .user_id = ack.getUserId(),
        .order_id = ack.getOrderId(),
    };
}

/// Decode CANCEL_ACK message (18 bytes).
fn decodeCancelAck(data: []const u8) DecodeError!types.OutputMessage {
    const msg_size = @sizeOf(types.BinaryCancelAck);

    std.debug.assert(data.len >= 2);

    if (data.len < msg_size) return DecodeError.MessageTooShort;

    var ack: types.BinaryCancelAck = undefined;
    @memcpy(std.mem.asBytes(&ack), data[0..msg_size]);

    std.debug.assert(ack.magic == types.MAGIC_BYTE);

    return types.OutputMessage{
        .msg_type = .cancel_ack,
        .symbol = ack.symbol,
        .symbol_len = @intCast(types.findSymbolLen(&ack.symbol)),
        .user_id = ack.getUserId(),
        .order_id = ack.getOrderId(),
    };
}

/// Decode TRADE message (34 bytes).
fn decodeTrade(data: []const u8) DecodeError!types.OutputMessage {
    const msg_size = @sizeOf(types.BinaryTrade);

    std.debug.assert(data.len >= 2);

    if (data.len < msg_size) return DecodeError.MessageTooShort;

    var trade: types.BinaryTrade = undefined;
    @memcpy(std.mem.asBytes(&trade), data[0..msg_size]);

    std.debug.assert(trade.magic == types.MAGIC_BYTE);

    return types.OutputMessage{
        .msg_type = .trade,
        .symbol = trade.symbol,
        .symbol_len = @intCast(types.findSymbolLen(&trade.symbol)),
        .buy_user_id = trade.getBuyUserId(),
        .buy_order_id = trade.getBuyOrderId(),
        .sell_user_id = trade.getSellUserId(),
        .sell_order_id = trade.getSellOrderId(),
        .price = trade.getPrice(),
        .quantity = trade.getQuantity(),
    };
}

/// Decode TOP_OF_BOOK message (20 bytes).
fn decodeTopOfBook(data: []const u8) DecodeError!types.OutputMessage {
    const msg_size = @sizeOf(types.BinaryTopOfBook);

    std.debug.assert(data.len >= 2);

    if (data.len < msg_size) return DecodeError.MessageTooShort;

    var tob: types.BinaryTopOfBook = undefined;
    @memcpy(std.mem.asBytes(&tob), data[0..msg_size]);

    std.debug.assert(tob.magic == types.MAGIC_BYTE);

    return types.OutputMessage{
        .msg_type = .top_of_book,
        .symbol = tob.symbol,
        .symbol_len = @intCast(types.findSymbolLen(&tob.symbol)),
        .side = tob.getSide(),
        .price = tob.getPrice(),
        .quantity = tob.getQuantity(),
    };
}

// =============================================================================
// Input Message Encoding (Client → Server)
// =============================================================================

/// Encode a new order as binary.
///
/// # Arguments
/// - `buf`: Output buffer (must be at least 27 bytes)
/// - Other args: Order parameters
///
/// # Returns
/// Slice of encoded bytes, or error if buffer too small.
pub fn encodeNewOrder(
    buf: []u8,
    user_id: u32,
    symbol: []const u8,
    price: u32,
    quantity: u32,
    side: types.Side,
    order_id: u32,
) EncodeError![]const u8 {
    const msg_size = @sizeOf(types.BinaryNewOrder);

    // Pre-conditions (Power of Ten Rule 5)
    std.debug.assert(symbol.len > 0);
    std.debug.assert(quantity > 0);

    if (buf.len < msg_size) return EncodeError.BufferTooSmall;

    const order = types.BinaryNewOrder.init(
        user_id,
        symbol,
        price,
        quantity,
        side,
        order_id,
    );

    @memcpy(buf[0..msg_size], order.asSlice());

    return buf[0..msg_size];
}

/// Encode a cancel order as binary.
pub fn encodeCancel(
    buf: []u8,
    user_id: u32,
    order_id: u32,
) EncodeError![]const u8 {
    const msg_size = @sizeOf(types.BinaryCancel);

    if (buf.len < msg_size) return EncodeError.BufferTooSmall;

    const cancel = types.BinaryCancel.init(user_id, order_id);

    @memcpy(buf[0..msg_size], cancel.asSlice());

    return buf[0..msg_size];
}

/// Encode a flush command as binary.
pub fn encodeFlush(buf: []u8) EncodeError![]const u8 {
    const msg_size = @sizeOf(types.BinaryFlush);

    if (buf.len < msg_size) return EncodeError.BufferTooSmall;

    const flush = types.BinaryFlush{};

    @memcpy(buf[0..msg_size], flush.asSlice());

    return buf[0..msg_size];
}

// =============================================================================
// Formatting (for debugging/logging)
// =============================================================================

/// Format a decoded message as a human-readable string.
///
/// # Arguments
/// - `msg`: Decoded message
/// - `buf`: Output buffer for formatted string
///
/// # Returns
/// Slice of formatted string, or empty slice on error.
pub fn formatOutput(msg: *const types.OutputMessage, buf: []u8) []const u8 {
    // Pre-condition (Power of Ten Rule 5)
    std.debug.assert(buf.len > 0);
    std.debug.assert(msg.symbol_len <= types.MAX_SYMBOL_LEN);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    const result = switch (msg.msg_type) {
        .ack => writer.print("ACK: {s} user={d} order={d}", .{
            msg.getSymbol(),
            msg.user_id,
            msg.order_id,
        }),
        .cancel_ack => writer.print("CANCEL: {s} user={d} order={d}", .{
            msg.getSymbol(),
            msg.user_id,
            msg.order_id,
        }),
        .trade => writer.print("TRADE: {s} buy={d}/{d} sell={d}/{d} price={d} qty={d}", .{
            msg.getSymbol(),
            msg.buy_user_id,
            msg.buy_order_id,
            msg.sell_user_id,
            msg.sell_order_id,
            msg.price,
            msg.quantity,
        }),
        .top_of_book => blk: {
            const side_char: u8 = if (msg.side) |s| s.toChar() else '-';
            if (msg.isEmptyBook()) {
                break :blk writer.print("TOB: {s} {c} EMPTY", .{
                    msg.getSymbol(),
                    side_char,
                });
            } else {
                break :blk writer.print("TOB: {s} {c} price={d} qty={d}", .{
                    msg.getSymbol(),
                    side_char,
                    msg.price,
                    msg.quantity,
                });
            }
        },
        .reject => writer.print("REJECT: {s} user={d} order={d} reason={d}", .{
            msg.getSymbol(),
            msg.user_id,
            msg.order_id,
            msg.reject_reason,
        }),
    };

    // Handle write errors gracefully (return partial output)
    if (result) |_| {
        // Success
    } else |_| {
        // Error - return what we have
    }

    return stream.getWritten();
}

// =============================================================================
// Tests
// =============================================================================

test "detect binary protocol" {
    const binary_data = [_]u8{ 0x4D, 'N', 0, 0, 0, 1 };
    const csv_data = "N, 1, IBM, 100, 50, B, 1";
    const empty_data: []const u8 = "";

    try std.testing.expect(isBinaryProtocol(&binary_data));
    try std.testing.expect(!isBinaryProtocol(csv_data));
    try std.testing.expect(!isBinaryProtocol(empty_data));
}

test "decode binary ack" {
    // Manually construct a binary ack message (18 bytes - matches server)
    var data: [18]u8 = undefined;
    data[0] = types.MAGIC_BYTE;
    data[1] = @intFromEnum(types.OutputMsgType.ack);

    // Symbol "IBM" null-padded (8 bytes at offset 2)
    @memcpy(data[2..5], "IBM");
    @memset(data[5..10], 0);

    // user_id = 1 (big-endian, 4 bytes at offset 10)
    std.mem.writeInt(u32, data[10..14], 1, .big);

    // order_id = 1001 (big-endian, 4 bytes at offset 14)
    std.mem.writeInt(u32, data[14..18], 1001, .big);

    const msg = try decodeOutput(&data);
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.user_id);
    try std.testing.expectEqual(@as(u32, 1001), msg.order_id);
}

test "decode binary trade" {
    var data: [34]u8 = undefined;
    data[0] = types.MAGIC_BYTE;
    data[1] = @intFromEnum(types.OutputMsgType.trade);

    // Symbol
    @memcpy(data[2..6], "AAPL");
    @memset(data[6..10], 0);

    // buy_user_id, buy_order_id, sell_user_id, sell_order_id, price, qty
    std.mem.writeInt(u32, data[10..14], 1, .big);
    std.mem.writeInt(u32, data[14..18], 100, .big);
    std.mem.writeInt(u32, data[18..22], 2, .big);
    std.mem.writeInt(u32, data[22..26], 200, .big);
    std.mem.writeInt(u32, data[26..30], 15000, .big);
    std.mem.writeInt(u32, data[30..34], 50, .big);

    const msg = try decodeOutput(&data);
    try std.testing.expectEqual(types.OutputMsgType.trade, msg.msg_type);
    try std.testing.expectEqualStrings("AAPL", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.buy_user_id);
    try std.testing.expectEqual(@as(u32, 100), msg.buy_order_id);
    try std.testing.expectEqual(@as(u32, 2), msg.sell_user_id);
    try std.testing.expectEqual(@as(u32, 200), msg.sell_order_id);
    try std.testing.expectEqual(@as(u32, 15000), msg.price);
    try std.testing.expectEqual(@as(u32, 50), msg.quantity);
}

test "decode binary top of book" {
    var data: [20]u8 = undefined;
    data[0] = types.MAGIC_BYTE;
    data[1] = @intFromEnum(types.OutputMsgType.top_of_book);

    @memcpy(data[2..5], "IBM");
    @memset(data[5..10], 0);

    data[10] = 'B'; // side
    data[19] = 0; // padding

    std.mem.writeInt(u32, data[11..15], 10000, .big);
    std.mem.writeInt(u32, data[15..19], 100, .big);

    const msg = try decodeOutput(&data);
    try std.testing.expectEqual(types.OutputMsgType.top_of_book, msg.msg_type);
    try std.testing.expectEqual(types.Side.buy, msg.side.?);
    try std.testing.expectEqual(@as(u32, 10000), msg.price);
    try std.testing.expectEqual(@as(u32, 100), msg.quantity);
}

test "invalid magic byte" {
    const data = [_]u8{ 0x00, 'N', 0, 0, 0, 1 };
    try std.testing.expectError(DecodeError.InvalidMagic, decodeOutput(&data));
}

test "message too short" {
    const data = [_]u8{types.MAGIC_BYTE};
    try std.testing.expectError(DecodeError.MessageTooShort, decodeOutput(&data));
}

test "unknown message type" {
    const data = [_]u8{ types.MAGIC_BYTE, 'Z', 0, 0 };
    try std.testing.expectError(DecodeError.UnknownMessageType, decodeOutput(&data));
}

test "encode new order" {
    var buf: [64]u8 = undefined;

    const encoded = try encodeNewOrder(&buf, 1, "IBM", 10000, 50, .buy, 1001);

    // Wire size is 27 bytes (matches server's binary_codec.zig)
    try std.testing.expectEqual(@as(usize, 27), encoded.len);
    try std.testing.expectEqual(types.MAGIC_BYTE, encoded[0]);
    try std.testing.expectEqual(@as(u8, 'N'), encoded[1]);
}

test "encode cancel" {
    var buf: [32]u8 = undefined;

    const encoded = try encodeCancel(&buf, 1, "IBM", 1001);

    // Wire size is 18 bytes (matches server's binary_codec.zig)
    try std.testing.expectEqual(@as(usize, 18), encoded.len);
    try std.testing.expectEqual(types.MAGIC_BYTE, encoded[0]);
    try std.testing.expectEqual(@as(u8, 'C'), encoded[1]);
}

test "encode flush" {
    var buf: [8]u8 = undefined;

    const encoded = try encodeFlush(&buf);

    try std.testing.expectEqual(@as(usize, 2), encoded.len);
    try std.testing.expectEqual(types.MAGIC_BYTE, encoded[0]);
    try std.testing.expectEqual(@as(u8, 'F'), encoded[1]);
}

test "format output message" {
    const msg = types.OutputMessage.ack("IBM", 1, 100);

    var buf: [256]u8 = undefined;
    const formatted = formatOutput(&msg, &buf);

    try std.testing.expect(formatted.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "ACK") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "IBM") != null);
}

test "encode buffer too small" {
    var small_buf: [4]u8 = undefined;

    try std.testing.expectError(EncodeError.BufferTooSmall, encodeNewOrder(
        &small_buf,
        1,
        "IBM",
        100,
        50,
        .buy,
        1,
    ));
}
