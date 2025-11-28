//! Binary protocol encoder/decoder.
//!
//! Handles serialization of input messages and parsing of output messages
//! using the packed binary format. All integers are big-endian (network order).

const std = @import("std");
const types = @import("types.zig");

pub const DecodeError = error{
    InvalidMagic,
    UnknownMessageType,
    MessageTooShort,
    InvalidSide,
};

/// Detect if data is binary protocol (vs CSV).
/// Binary messages start with magic byte 0x4D.
pub fn isBinaryProtocol(data: []const u8) bool {
    return data.len > 0 and data[0] == types.MAGIC_BYTE;
}

/// Decode an output message from binary wire format.
pub fn decodeOutput(data: []const u8) DecodeError!types.OutputMessage {
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

fn decodeAck(data: []const u8) DecodeError!types.OutputMessage {
    if (data.len < @sizeOf(types.BinaryAck)) return DecodeError.MessageTooShort;

    const ack: *const types.BinaryAck = @ptrCast(@alignCast(data.ptr));

    var msg = types.OutputMessage{
        .msg_type = .ack,
        .symbol = ack.symbol,
        .symbol_len = @intCast(findSymbolLen(&ack.symbol)),
        .user_id = ack.getUserId(),
        .order_id = ack.getOrderId(),
    };

    return msg;
}

fn decodeCancelAck(data: []const u8) DecodeError!types.OutputMessage {
    if (data.len < @sizeOf(types.BinaryCancelAck)) return DecodeError.MessageTooShort;

    const ack: *const types.BinaryCancelAck = @ptrCast(@alignCast(data.ptr));

    var msg = types.OutputMessage{
        .msg_type = .cancel_ack,
        .symbol = ack.symbol,
        .symbol_len = @intCast(findSymbolLen(&ack.symbol)),
        .user_id = ack.getUserId(),
        .order_id = ack.getOrderId(),
    };

    return msg;
}

fn decodeTrade(data: []const u8) DecodeError!types.OutputMessage {
    if (data.len < @sizeOf(types.BinaryTrade)) return DecodeError.MessageTooShort;

    const trade: *const types.BinaryTrade = @ptrCast(@alignCast(data.ptr));

    var msg = types.OutputMessage{
        .msg_type = .trade,
        .symbol = trade.symbol,
        .symbol_len = @intCast(findSymbolLen(&trade.symbol)),
        .buy_user_id = trade.getBuyUserId(),
        .buy_order_id = std.mem.bigToNative(u32, trade.buy_order_id),
        .sell_user_id = trade.getSellUserId(),
        .sell_order_id = std.mem.bigToNative(u32, trade.sell_order_id),
        .price = trade.getPrice(),
        .quantity = trade.getQuantity(),
    };

    return msg;
}

fn decodeTopOfBook(data: []const u8) DecodeError!types.OutputMessage {
    if (data.len < @sizeOf(types.BinaryTopOfBook)) return DecodeError.MessageTooShort;

    const tob: *const types.BinaryTopOfBook = @ptrCast(@alignCast(data.ptr));

    var msg = types.OutputMessage{
        .msg_type = .top_of_book,
        .symbol = tob.symbol,
        .symbol_len = @intCast(findSymbolLen(&tob.symbol)),
        .side = tob.getSide(),
        .price = tob.getPrice(),
        .quantity = tob.getQuantity(),
    };

    return msg;
}

fn findSymbolLen(symbol: *const [types.MAX_SYMBOL_LEN]u8) usize {
    for (symbol, 0..) |c, i| {
        if (c == 0) return i;
    }
    return types.MAX_SYMBOL_LEN;
}

/// Format a decoded message as a human-readable string (for debugging).
pub fn formatOutput(msg: *const types.OutputMessage, buf: []u8) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (msg.msg_type) {
        .ack => {
            writer.print("ACK: {s} user={d} order={d}", .{
                msg.getSymbol(),
                msg.user_id,
                msg.order_id,
            }) catch {};
        },
        .cancel_ack => {
            writer.print("CANCEL: {s} user={d} order={d}", .{
                msg.getSymbol(),
                msg.user_id,
                msg.order_id,
            }) catch {};
        },
        .trade => {
            writer.print("TRADE: {s} buy={d}/{d} sell={d}/{d} price={d} qty={d}", .{
                msg.getSymbol(),
                msg.buy_user_id,
                msg.buy_order_id,
                msg.sell_user_id,
                msg.sell_order_id,
                msg.price,
                msg.quantity,
            }) catch {};
        },
        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| s.toChar() else '-';
            if (msg.price == 0 and msg.quantity == 0) {
                writer.print("TOB: {s} {c} EMPTY", .{ msg.getSymbol(), side_char }) catch {};
            } else {
                writer.print("TOB: {s} {c} price={d} qty={d}", .{
                    msg.getSymbol(),
                    side_char,
                    msg.price,
                    msg.quantity,
                }) catch {};
            }
        },
    }

    return stream.getWritten();
}

// ============================================================
// Tests
// ============================================================

test "detect binary protocol" {
    const binary_data = [_]u8{ 0x4D, 'N', 0, 0, 0, 1 };
    const csv_data = "N, 1, IBM, 100, 50, B, 1";

    try std.testing.expect(isBinaryProtocol(&binary_data));
    try std.testing.expect(!isBinaryProtocol(csv_data));
}

test "decode binary ack" {
    // Manually construct a binary ack message
    var data: [19]u8 = undefined;
    data[0] = types.MAGIC_BYTE;
    data[1] = @intFromEnum(types.OutputMsgType.ack);

    // Symbol "IBM" null-padded
    @memcpy(data[2..5], "IBM");
    @memset(data[5..10], 0);

    // user_id = 1 (big-endian)
    data[10] = 0;
    data[11] = 0;
    data[12] = 0;
    data[13] = 1;

    // order_id = 1001 (big-endian)
    std.mem.writeInt(u32, data[14..18], 1001, .big);
    data[18] = 0; // padding

    const msg = try decodeOutput(&data);
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.user_id);
    try std.testing.expectEqual(@as(u32, 1001), msg.order_id);
}

test "invalid magic byte" {
    const data = [_]u8{ 0x00, 'N', 0, 0, 0, 1 };
    try std.testing.expectError(DecodeError.InvalidMagic, decodeOutput(&data));
}

test "message too short" {
    const data = [_]u8{0x4D};
    try std.testing.expectError(DecodeError.MessageTooShort, decodeOutput(&data));
}
