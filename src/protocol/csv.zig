//! CSV protocol encoder/decoder.
//!
//! Handles the human-readable text format. Useful for debugging and
//! interop with tools like netcat. Format: "N, 1, IBM, 10000, 50, B, 1\n"

const std = @import("std");
const types = @import("types.zig");

pub const ParseError = error{
    EmptyMessage,
    UnknownMessageType,
    MissingFields,
    InvalidNumber,
    InvalidSide,
    BufferTooSmall,
};

// ============================================================
// Input message formatting (client -> server)
// ============================================================

/// Format a new order as CSV. Returns slice of written bytes.
pub fn formatNewOrder(
    buf: []u8,
    user_id: u32,
    symbol: []const u8,
    price: u32,
    quantity: u32,
    side: types.Side,
    order_id: u32,
) ParseError![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.print("N, {d}, {s}, {d}, {d}, {c}, {d}\n", .{
        user_id,
        symbol,
        price,
        quantity,
        side.toChar(),
        order_id,
    }) catch return ParseError.BufferTooSmall;

    return stream.getWritten();
}

/// Format a cancel order as CSV.
pub fn formatCancel(
    buf: []u8,
    user_id: u32,
    order_id: u32,
) ParseError![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.print("C, {d}, {d}\n", .{ user_id, order_id }) catch return ParseError.BufferTooSmall;

    return stream.getWritten();
}

/// Format a flush command as CSV.
pub fn formatFlush(buf: []u8) ParseError![]const u8 {
    if (buf.len < 2) return ParseError.BufferTooSmall;
    buf[0] = 'F';
    buf[1] = '\n';
    return buf[0..2];
}

// ============================================================
// Output message parsing (server -> client)
// ============================================================

/// Parse a CSV output message from the server.
pub fn parseOutput(data: []const u8) ParseError!types.OutputMessage {
    // Trim whitespace and newlines
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return ParseError.EmptyMessage;

    const msg_type = trimmed[0];

    return switch (msg_type) {
        'A' => parseAck(trimmed),
        'C' => parseCancelAck(trimmed),
        'T' => parseTrade(trimmed),
        'B' => parseTopOfBook(trimmed),
        else => ParseError.UnknownMessageType,
    };
}

fn parseAck(data: []const u8) ParseError!types.OutputMessage {
    // Format: A, symbol, user_id, order_id
    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip 'A'

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const user_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const order_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    const user_id = std.fmt.parseInt(u32, user_field, 10) catch return ParseError.InvalidNumber;
    const order_id = std.fmt.parseInt(u32, order_field, 10) catch return ParseError.InvalidNumber;

    var msg = types.OutputMessage{
        .msg_type = .ack,
        .symbol = undefined,
        .symbol_len = @intCast(@min(symbol_field.len, types.MAX_SYMBOL_LEN)),
        .user_id = user_id,
        .order_id = order_id,
    };

    @memset(&msg.symbol, 0);
    @memcpy(msg.symbol[0..msg.symbol_len], symbol_field[0..msg.symbol_len]);

    return msg;
}

fn parseCancelAck(data: []const u8) ParseError!types.OutputMessage {
    // Format: C, symbol, user_id, order_id (same as ack)
    var msg = try parseAck(data);
    msg.msg_type = .cancel_ack;
    return msg;
}

fn parseTrade(data: []const u8) ParseError!types.OutputMessage {
    // Format: T, symbol, buy_user, buy_order, sell_user, sell_order, price, qty
    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip 'T'

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const buy_user = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const buy_order = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const sell_user = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const sell_order = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const price_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const qty_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    var msg = types.OutputMessage{
        .msg_type = .trade,
        .symbol = undefined,
        .symbol_len = @intCast(@min(symbol_field.len, types.MAX_SYMBOL_LEN)),
        .buy_user_id = std.fmt.parseInt(u32, buy_user, 10) catch return ParseError.InvalidNumber,
        .buy_order_id = std.fmt.parseInt(u32, buy_order, 10) catch return ParseError.InvalidNumber,
        .sell_user_id = std.fmt.parseInt(u32, sell_user, 10) catch return ParseError.InvalidNumber,
        .sell_order_id = std.fmt.parseInt(u32, sell_order, 10) catch return ParseError.InvalidNumber,
        .price = std.fmt.parseInt(u32, price_field, 10) catch return ParseError.InvalidNumber,
        .quantity = std.fmt.parseInt(u32, qty_field, 10) catch return ParseError.InvalidNumber,
    };

    @memset(&msg.symbol, 0);
    @memcpy(msg.symbol[0..msg.symbol_len], symbol_field[0..msg.symbol_len]);

    return msg;
}

fn parseTopOfBook(data: []const u8) ParseError!types.OutputMessage {
    // Format: B, symbol, side, price, qty
    // Empty book: B, symbol, side, -, -
    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip 'B'

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const side_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const price_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const qty_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    const side = if (side_field.len > 0) types.Side.fromChar(side_field[0]) else null;

    // Handle empty book (price and qty are "-")
    const price = if (std.mem.eql(u8, price_field, "-"))
        0
    else
        std.fmt.parseInt(u32, price_field, 10) catch return ParseError.InvalidNumber;

    const qty = if (std.mem.eql(u8, qty_field, "-"))
        0
    else
        std.fmt.parseInt(u32, qty_field, 10) catch return ParseError.InvalidNumber;

    var msg = types.OutputMessage{
        .msg_type = .top_of_book,
        .symbol = undefined,
        .symbol_len = @intCast(@min(symbol_field.len, types.MAX_SYMBOL_LEN)),
        .side = side,
        .price = price,
        .quantity = qty,
    };

    @memset(&msg.symbol, 0);
    @memcpy(msg.symbol[0..msg.symbol_len], symbol_field[0..msg.symbol_len]);

    return msg;
}

// ============================================================
// Tests
// ============================================================

test "format new order" {
    var buf: [256]u8 = undefined;
    const result = try formatNewOrder(&buf, 1, "IBM", 10000, 50, .buy, 1001);
    try std.testing.expectEqualStrings("N, 1, IBM, 10000, 50, B, 1001\n", result);
}

test "format cancel" {
    var buf: [256]u8 = undefined;
    const result = try formatCancel(&buf, 42, 1001);
    try std.testing.expectEqualStrings("C, 42, 1001\n", result);
}

test "format flush" {
    var buf: [256]u8 = undefined;
    const result = try formatFlush(&buf);
    try std.testing.expectEqualStrings("F\n", result);
}

test "parse ack" {
    const msg = try parseOutput("A, IBM, 1, 1001");
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.user_id);
    try std.testing.expectEqual(@as(u32, 1001), msg.order_id);
}

test "parse trade" {
    const msg = try parseOutput("T, IBM, 1, 100, 2, 200, 10000, 50");
    try std.testing.expectEqual(types.OutputMsgType.trade, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.buy_user_id);
    try std.testing.expectEqual(@as(u32, 100), msg.buy_order_id);
    try std.testing.expectEqual(@as(u32, 2), msg.sell_user_id);
    try std.testing.expectEqual(@as(u32, 200), msg.sell_order_id);
    try std.testing.expectEqual(@as(u32, 10000), msg.price);
    try std.testing.expectEqual(@as(u32, 50), msg.quantity);
}

test "parse top of book" {
    const msg = try parseOutput("B, IBM, B, 10000, 50");
    try std.testing.expectEqual(types.OutputMsgType.top_of_book, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(types.Side.buy, msg.side.?);
    try std.testing.expectEqual(@as(u32, 10000), msg.price);
    try std.testing.expectEqual(@as(u32, 50), msg.quantity);
}

test "parse empty top of book" {
    const msg = try parseOutput("B, IBM, B, -, -");
    try std.testing.expectEqual(types.OutputMsgType.top_of_book, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 0), msg.price);
    try std.testing.expectEqual(@as(u32, 0), msg.quantity);
}

test "parse with whitespace" {
    const msg = try parseOutput("  A, IBM, 1, 1001  \n");
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
}
