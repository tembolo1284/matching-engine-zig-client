//! Protocol codec tests.
//!
//! Tests for binary and CSV encoding/decoding, ensuring wire format
//! compatibility with the C matching engine.

const std = @import("std");
const types = @import("../src/protocol/types.zig");
const binary = @import("../src/protocol/binary.zig");
const csv = @import("../src/protocol/csv.zig");
const framing = @import("../src/protocol/framing.zig");

// ============================================================
// Binary Protocol Tests
// ============================================================

test "binary new order wire format" {
    const order = types.BinaryNewOrder.init(
        1,
        "IBM",
        10000,
        50,
        .buy,
        1001,
    );

    const bytes = order.asBytes();

    // Byte 0: magic
    try std.testing.expectEqual(@as(u8, 0x4D), bytes[0]);

    // Byte 1: message type
    try std.testing.expectEqual(@as(u8, 'N'), bytes[1]);

    // Bytes 2-5: user_id (big-endian)
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 1 }, bytes[2..6].*);

    // Bytes 6-13: symbol (null-padded)
    try std.testing.expectEqual([8]u8{ 'I', 'B', 'M', 0, 0, 0, 0, 0 }, bytes[6..14].*);

    // Bytes 14-17: price (big-endian, 10000 = 0x00002710)
    try std.testing.expectEqual([4]u8{ 0, 0, 0x27, 0x10 }, bytes[14..18].*);

    // Bytes 18-21: quantity (big-endian)
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 50 }, bytes[18..22].*);

    // Byte 22: side
    try std.testing.expectEqual(@as(u8, 'B'), bytes[22]);

    // Bytes 23-26: order_id (big-endian, 1001 = 0x000003E9)
    try std.testing.expectEqual([4]u8{ 0, 0, 0x03, 0xE9 }, bytes[23..27].*);

    // Total size
    try std.testing.expectEqual(@as(usize, 30), bytes.len);
}

test "binary cancel wire format" {
    const cancel = types.BinaryCancel.init(42, 1001);
    const bytes = cancel.asBytes();

    try std.testing.expectEqual(@as(u8, 0x4D), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'C'), bytes[1]);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 42 }, bytes[2..6].*);
    try std.testing.expectEqual([4]u8{ 0, 0, 0x03, 0xE9 }, bytes[6..10].*);
    try std.testing.expectEqual(@as(usize, 11), bytes.len);
}

test "binary flush wire format" {
    const flush = types.BinaryFlush{};
    const bytes = flush.asBytes();

    try std.testing.expectEqual(@as(u8, 0x4D), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'F'), bytes[1]);
    try std.testing.expectEqual(@as(usize, 2), bytes.len);
}

test "binary protocol detection" {
    const binary_msg = [_]u8{ 0x4D, 'N', 0, 0, 0, 1 };
    const csv_msg = "N, 1, IBM, 10000, 50, B, 1";

    try std.testing.expect(binary.isBinaryProtocol(&binary_msg));
    try std.testing.expect(!binary.isBinaryProtocol(csv_msg));
}

// ============================================================
// CSV Protocol Tests
// ============================================================

test "csv new order format" {
    var buf: [256]u8 = undefined;
    const result = try csv.formatNewOrder(&buf, 1, "IBM", 10000, 50, .buy, 1001);
    try std.testing.expectEqualStrings("N, 1, IBM, 10000, 50, B, 1001\n", result);
}

test "csv cancel format" {
    var buf: [256]u8 = undefined;
    const result = try csv.formatCancel(&buf, 42, 1001);
    try std.testing.expectEqualStrings("C, 42, 1001\n", result);
}

test "csv flush format" {
    var buf: [256]u8 = undefined;
    const result = try csv.formatFlush(&buf);
    try std.testing.expectEqualStrings("F\n", result);
}

test "csv parse ack" {
    const msg = try csv.parseOutput("A, IBM, 1, 1001");
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.user_id);
    try std.testing.expectEqual(@as(u32, 1001), msg.order_id);
}

test "csv parse cancel ack" {
    const msg = try csv.parseOutput("C, AAPL, 2, 2002");
    try std.testing.expectEqual(types.OutputMsgType.cancel_ack, msg.msg_type);
    try std.testing.expectEqualStrings("AAPL", msg.getSymbol());
}

test "csv parse trade" {
    const msg = try csv.parseOutput("T, IBM, 1, 100, 2, 200, 10000, 50");
    try std.testing.expectEqual(types.OutputMsgType.trade, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.buy_user_id);
    try std.testing.expectEqual(@as(u32, 100), msg.buy_order_id);
    try std.testing.expectEqual(@as(u32, 2), msg.sell_user_id);
    try std.testing.expectEqual(@as(u32, 200), msg.sell_order_id);
    try std.testing.expectEqual(@as(u32, 10000), msg.price);
    try std.testing.expectEqual(@as(u32, 50), msg.quantity);
}

test "csv parse top of book" {
    const msg = try csv.parseOutput("B, IBM, B, 10000, 500");
    try std.testing.expectEqual(types.OutputMsgType.top_of_book, msg.msg_type);
    try std.testing.expectEqual(types.Side.buy, msg.side.?);
    try std.testing.expectEqual(@as(u32, 10000), msg.price);
    try std.testing.expectEqual(@as(u32, 500), msg.quantity);
}

test "csv parse empty top of book" {
    const msg = try csv.parseOutput("B, IBM, S, -, -");
    try std.testing.expectEqual(types.OutputMsgType.top_of_book, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 0), msg.price);
    try std.testing.expectEqual(@as(u32, 0), msg.quantity);
}

test "csv parse with extra whitespace" {
    const msg = try csv.parseOutput("  A,  IBM ,  1 ,  1001  \r\n");
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
}

test "csv parse invalid message" {
    try std.testing.expectError(csv.ParseError.EmptyMessage, csv.parseOutput(""));
    try std.testing.expectError(csv.ParseError.UnknownMessageType, csv.parseOutput("X, data"));
}

// ============================================================
// Framing Tests
// ============================================================

test "framing encode" {
    var buf: [256]u8 = undefined;
    const encoded = try framing.encode("Hello", &buf);

    // Length header (big-endian)
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 5 }, encoded[0..4].*);

    // Payload
    try std.testing.expectEqualStrings("Hello", encoded[4..9]);

    try std.testing.expectEqual(@as(usize, 9), encoded.len);
}

test "framing round-trip" {
    var encode_buf: [256]u8 = undefined;
    var reader = framing.FrameReader.init();

    const original = "Test message!";
    const encoded = try framing.encode(original, &encode_buf);

    // Simulate receiving the framed message
    const write_buf = reader.getWriteBuffer();
    @memcpy(write_buf[0..encoded.len], encoded);
    reader.advance(encoded.len);

    // Should decode correctly
    const decoded = reader.nextMessage();
    try std.testing.expect(decoded != null);
    try std.testing.expectEqualStrings(original, decoded.?);
}

// ============================================================
// Structure Size Tests (compatibility with C server)
// ============================================================

test "struct sizes match C server" {
    try std.testing.expectEqual(@as(usize, 30), @sizeOf(types.BinaryNewOrder));
    try std.testing.expectEqual(@as(usize, 11), @sizeOf(types.BinaryCancel));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(types.BinaryFlush));
    try std.testing.expectEqual(@as(usize, 19), @sizeOf(types.BinaryAck));
    try std.testing.expectEqual(@as(usize, 34), @sizeOf(types.BinaryTrade));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(types.BinaryTopOfBook));

    // Output message should be cache-line aligned
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(types.OutputMessage));
}

test "side enum is single byte" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(types.Side));
}
