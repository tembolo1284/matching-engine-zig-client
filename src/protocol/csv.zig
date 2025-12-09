//! CSV Protocol Encoder/Decoder
//!
//! # Overview
//! Handles the human-readable text format used for debugging, development,
//! and interoperability with tools like netcat, telnet, and shell scripts.
//!
//! # Format
//! - Messages are single lines terminated by `\n`
//! - Fields are comma-separated with optional whitespace
//! - Numbers are decimal ASCII
//!
//! # Message Types
//! Input (Client → Server):
//! - `N, user_id, symbol, price, qty, side, order_id` (New Order)
//! - `C, user_id, symbol, order_id` (Cancel)
//! - `F` (Flush All)
//!
//! Output (Server → Client):
//! - `A, symbol, user_id, order_id` (Ack)
//! - `C, symbol, user_id, order_id` (Cancel Ack - legacy)
//! - `X, symbol, user_id, order_id` (Cancel Ack - preferred)
//! - `T, symbol, buy_user, buy_oid, sell_user, sell_oid, price, qty` (Trade)
//! - `B, symbol, side, price, qty` (Top of Book)
//! - `R, symbol, user_id, order_id, reason` (Reject)
//!
//! # Power of Ten Compliance
//! - Rule 2: All loops bounded (iterator-based parsing)
//! - Rule 4: Functions ≤60 lines
//! - Rule 5: ≥2 assertions per function
//! - Rule 7: All return values checked

const std = @import("std");
const types = @import("types.zig");

// =============================================================================
// Error Types
// =============================================================================

pub const ParseError = error{
    /// Input is empty or only whitespace
    EmptyMessage,
    /// Message type character not recognized
    UnknownMessageType,
    /// Required field is missing
    MissingFields,
    /// Number field could not be parsed
    InvalidNumber,
    /// Side field is not 'B' or 'S'
    InvalidSide,
    /// Output buffer is too small
    BufferTooSmall,
    /// Symbol is empty
    EmptySymbol,
};

// =============================================================================
// Input Message Formatting (Client → Server)
// =============================================================================

/// Format a new order as CSV.
///
/// # Arguments
/// - `buf`: Output buffer
/// - Order parameters
///
/// # Returns
/// Slice of formatted message including trailing newline.
///
/// # Format
/// `N, <user_id>, <symbol>, <price>, <qty>, <side>, <order_id>\n`
pub fn formatNewOrder(
    buf: []u8,
    user_id: u32,
    symbol: []const u8,
    price: u32,
    quantity: u32,
    side: types.Side,
    order_id: u32,
) ParseError![]const u8 {
    // Pre-conditions (Power of Ten Rule 5)
    std.debug.assert(buf.len > 0);
    std.debug.assert(symbol.len > 0);
    std.debug.assert(quantity > 0);

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

    const written = stream.getWritten();

    // Post-condition: we wrote something
    std.debug.assert(written.len > 0);

    return written;
}

/// Format a cancel order as CSV.
///
/// # Format
/// `C, <user_id>, <symbol>, <order_id>\n`
pub fn formatCancel(
    buf: []u8,
    user_id: u32,
    symbol: []const u8,
    order_id: u32,
) ParseError![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(symbol.len > 0);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    writer.print("C, {d}, {s}, {d}\n", .{
        user_id,
        symbol,
        order_id,
    }) catch return ParseError.BufferTooSmall;

    const written = stream.getWritten();
    std.debug.assert(written.len > 0);

    return written;
}

/// Format a flush command as CSV.
///
/// # Format
/// `F\n`
pub fn formatFlush(buf: []u8) ParseError![]const u8 {
    std.debug.assert(buf.len > 0);

    if (buf.len < 2) return ParseError.BufferTooSmall;

    buf[0] = 'F';
    buf[1] = '\n';

    return buf[0..2];
}

// =============================================================================
// Output Message Parsing (Server → Client)
// =============================================================================

/// Parse a CSV output message from the server.
///
/// # Arguments
/// - `data`: Raw message bytes (may include trailing whitespace/newline)
///
/// # Returns
/// Parsed `OutputMessage` or parse error.
pub fn parseOutput(data: []const u8) ParseError!types.OutputMessage {
    // Pre-condition (Power of Ten Rule 5)
    // Assertion 1: Data pointer should be valid
    std.debug.assert(@intFromPtr(data.ptr) != 0);

    // Trim whitespace and newlines
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0) return ParseError.EmptyMessage;

    const msg_type = trimmed[0];

    // Post-condition check built into switch
    return switch (msg_type) {
        'A' => parseAck(trimmed),
        'C', 'X' => parseCancelAck(trimmed, msg_type),
        'T' => parseTrade(trimmed),
        'B' => parseTopOfBook(trimmed),
        'R' => parseReject(trimmed),
        else => ParseError.UnknownMessageType,
    };
}

/// Parse ACK message: `A, symbol, user_id, order_id`
fn parseAck(data: []const u8) ParseError!types.OutputMessage {
    std.debug.assert(data.len > 0);
    std.debug.assert(data[0] == 'A');

    var it = std.mem.splitScalar(u8, data, ',');

    // Skip message type
    _ = it.next();

    // Parse fields
    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const user_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const order_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    if (symbol_field.len == 0) return ParseError.EmptySymbol;

    const user_id = std.fmt.parseInt(u32, user_field, 10) catch return ParseError.InvalidNumber;
    const order_id = std.fmt.parseInt(u32, order_field, 10) catch return ParseError.InvalidNumber;

    var msg = types.OutputMessage{
        .msg_type = .ack,
        .user_id = user_id,
        .order_id = order_id,
    };
    msg.setSymbol(symbol_field);

    return msg;
}

/// Parse CANCEL_ACK message: `C, symbol, user_id, order_id` or `X, symbol, user_id, order_id`
fn parseCancelAck(data: []const u8, msg_char: u8) ParseError!types.OutputMessage {
    std.debug.assert(data.len > 0);
    std.debug.assert(msg_char == 'C' or msg_char == 'X');

    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip message type

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const user_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const order_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    if (symbol_field.len == 0) return ParseError.EmptySymbol;

    const user_id = std.fmt.parseInt(u32, user_field, 10) catch return ParseError.InvalidNumber;
    const order_id = std.fmt.parseInt(u32, order_field, 10) catch return ParseError.InvalidNumber;

    var msg = types.OutputMessage{
        .msg_type = .cancel_ack,
        .user_id = user_id,
        .order_id = order_id,
    };
    msg.setSymbol(symbol_field);

    return msg;
}

/// Parse TRADE message: `T, symbol, buy_user, buy_order, sell_user, sell_order, price, qty`
fn parseTrade(data: []const u8) ParseError!types.OutputMessage {
    std.debug.assert(data.len > 0);
    std.debug.assert(data[0] == 'T');

    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip 'T'

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const buy_user = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const buy_order = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const sell_user = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const sell_order = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const price_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const qty_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    if (symbol_field.len == 0) return ParseError.EmptySymbol;

    var msg = types.OutputMessage{
        .msg_type = .trade,
        .buy_user_id = std.fmt.parseInt(u32, buy_user, 10) catch return ParseError.InvalidNumber,
        .buy_order_id = std.fmt.parseInt(u32, buy_order, 10) catch return ParseError.InvalidNumber,
        .sell_user_id = std.fmt.parseInt(u32, sell_user, 10) catch return ParseError.InvalidNumber,
        .sell_order_id = std.fmt.parseInt(u32, sell_order, 10) catch return ParseError.InvalidNumber,
        .price = std.fmt.parseInt(u32, price_field, 10) catch return ParseError.InvalidNumber,
        .quantity = std.fmt.parseInt(u32, qty_field, 10) catch return ParseError.InvalidNumber,
    };
    msg.setSymbol(symbol_field);

    return msg;
}

/// Parse TOP_OF_BOOK message: `B, symbol, side, price, qty`
/// Empty book uses `-` for price and quantity.
fn parseTopOfBook(data: []const u8) ParseError!types.OutputMessage {
    std.debug.assert(data.len > 0);
    std.debug.assert(data[0] == 'B');

    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip 'B'

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const side_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const price_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const qty_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");

    if (symbol_field.len == 0) return ParseError.EmptySymbol;

    // Parse side (may be empty for some edge cases)
    const side: ?types.Side = if (side_field.len > 0)
        types.Side.fromChar(side_field[0])
    else
        null;

    // Handle empty book indicator: "-" means no orders on this side
    const price: u32 = if (std.mem.eql(u8, price_field, "-"))
        0
    else
        std.fmt.parseInt(u32, price_field, 10) catch return ParseError.InvalidNumber;

    const qty: u32 = if (std.mem.eql(u8, qty_field, "-"))
        0
    else
        std.fmt.parseInt(u32, qty_field, 10) catch return ParseError.InvalidNumber;

    var msg = types.OutputMessage{
        .msg_type = .top_of_book,
        .side = side,
        .price = price,
        .quantity = qty,
    };
    msg.setSymbol(symbol_field);

    return msg;
}

/// Parse REJECT message: `R, symbol, user_id, order_id, reason`
fn parseReject(data: []const u8) ParseError!types.OutputMessage {
    std.debug.assert(data.len > 0);
    std.debug.assert(data[0] == 'R');

    var it = std.mem.splitScalar(u8, data, ',');

    _ = it.next(); // Skip 'R'

    const symbol_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const user_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const order_field = std.mem.trim(u8, it.next() orelse return ParseError.MissingFields, " ");
    const reason_field = it.next(); // Optional

    if (symbol_field.len == 0) return ParseError.EmptySymbol;

    const user_id = std.fmt.parseInt(u32, user_field, 10) catch return ParseError.InvalidNumber;
    const order_id = std.fmt.parseInt(u32, order_field, 10) catch return ParseError.InvalidNumber;

    // Reason is optional - default to 0 if missing
    const reason: u32 = if (reason_field) |rf|
        std.fmt.parseInt(u32, std.mem.trim(u8, rf, " "), 10) catch 0
    else
        0;

    var msg = types.OutputMessage{
        .msg_type = .reject,
        .user_id = user_id,
        .order_id = order_id,
        .reject_reason = reason,
    };
    msg.setSymbol(symbol_field);

    return msg;
}

// =============================================================================
// Formatting Helpers
// =============================================================================

/// Format an output message as CSV (for logging/debugging).
///
/// # Arguments
/// - `msg`: Message to format
/// - `buf`: Output buffer
///
/// # Returns
/// Formatted string slice.
pub fn formatOutput(msg: *const types.OutputMessage, buf: []u8) ParseError![]const u8 {
    std.debug.assert(buf.len > 0);
    std.debug.assert(msg.symbol_len <= types.MAX_SYMBOL_LEN);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    switch (msg.msg_type) {
        .ack => writer.print("A, {s}, {d}, {d}", .{
            msg.getSymbol(),
            msg.user_id,
            msg.order_id,
        }) catch return ParseError.BufferTooSmall,

        .cancel_ack => writer.print("X, {s}, {d}, {d}", .{
            msg.getSymbol(),
            msg.user_id,
            msg.order_id,
        }) catch return ParseError.BufferTooSmall,

        .trade => writer.print("T, {s}, {d}, {d}, {d}, {d}, {d}, {d}", .{
            msg.getSymbol(),
            msg.buy_user_id,
            msg.buy_order_id,
            msg.sell_user_id,
            msg.sell_order_id,
            msg.price,
            msg.quantity,
        }) catch return ParseError.BufferTooSmall,

        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| s.toChar() else '-';
            if (msg.isEmptyBook()) {
                writer.print("B, {s}, {c}, -, -", .{
                    msg.getSymbol(),
                    side_char,
                }) catch return ParseError.BufferTooSmall;
            } else {
                writer.print("B, {s}, {c}, {d}, {d}", .{
                    msg.getSymbol(),
                    side_char,
                    msg.price,
                    msg.quantity,
                }) catch return ParseError.BufferTooSmall;
            }
        },

        .reject => writer.print("R, {s}, {d}, {d}, {d}", .{
            msg.getSymbol(),
            msg.user_id,
            msg.order_id,
            msg.reject_reason,
        }) catch return ParseError.BufferTooSmall,
    }

    return stream.getWritten();
}

// =============================================================================
// Tests
// =============================================================================

test "format new order" {
    var buf: [256]u8 = undefined;
    const result = try formatNewOrder(&buf, 1, "IBM", 10000, 50, .buy, 1001);
    try std.testing.expectEqualStrings("N, 1, IBM, 10000, 50, B, 1001\n", result);
}

test "format cancel" {
    var buf: [256]u8 = undefined;
    const result = try formatCancel(&buf, 42, "AAPL", 1001);
    try std.testing.expectEqualStrings("C, 42, AAPL, 1001\n", result);
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

test "parse cancel ack C format" {
    const msg = try parseOutput("C, IBM, 1, 1001");
    try std.testing.expectEqual(types.OutputMsgType.cancel_ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
}

test "parse cancel ack X format" {
    const msg = try parseOutput("X, IBM, 1, 1001");
    try std.testing.expectEqual(types.OutputMsgType.cancel_ack, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
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
    const msg = try parseOutput("B, IBM, S, -, -");
    try std.testing.expectEqual(types.OutputMsgType.top_of_book, msg.msg_type);
    try std.testing.expectEqual(types.Side.sell, msg.side.?);
    try std.testing.expectEqual(@as(u32, 0), msg.price);
    try std.testing.expectEqual(@as(u32, 0), msg.quantity);
    try std.testing.expect(msg.isEmptyBook());
}

test "parse reject" {
    const msg = try parseOutput("R, IBM, 1, 1001, 4");
    try std.testing.expectEqual(types.OutputMsgType.reject, msg.msg_type);
    try std.testing.expectEqualStrings("IBM", msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), msg.user_id);
    try std.testing.expectEqual(@as(u32, 1001), msg.order_id);
    try std.testing.expectEqual(@as(u32, 4), msg.reject_reason);
}

test "parse reject without reason" {
    const msg = try parseOutput("R, IBM, 1, 1001");
    try std.testing.expectEqual(types.OutputMsgType.reject, msg.msg_type);
    try std.testing.expectEqual(@as(u32, 0), msg.reject_reason);
}

test "parse with whitespace" {
    const msg = try parseOutput("  A, IBM, 1, 1001  \n");
    try std.testing.expectEqual(types.OutputMsgType.ack, msg.msg_type);
}

test "parse empty message" {
    try std.testing.expectError(ParseError.EmptyMessage, parseOutput(""));
    try std.testing.expectError(ParseError.EmptyMessage, parseOutput("   \n\t  "));
}

test "parse unknown message type" {
    try std.testing.expectError(ParseError.UnknownMessageType, parseOutput("Z, IBM, 1, 2"));
}

test "parse missing fields" {
    try std.testing.expectError(ParseError.MissingFields, parseOutput("A, IBM"));
    try std.testing.expectError(ParseError.MissingFields, parseOutput("T, IBM, 1, 2"));
}

test "parse invalid number" {
    try std.testing.expectError(ParseError.InvalidNumber, parseOutput("A, IBM, abc, 123"));
}

test "format output roundtrip" {
    const original = types.OutputMessage.trade("AAPL", 1, 100, 2, 200, 15000, 50);

    var buf: [256]u8 = undefined;
    const formatted = try formatOutput(&original, &buf);

    const parsed = try parseOutput(formatted);

    try std.testing.expectEqual(original.msg_type, parsed.msg_type);
    try std.testing.expectEqualStrings(original.getSymbol(), parsed.getSymbol());
    try std.testing.expectEqual(original.buy_user_id, parsed.buy_user_id);
    try std.testing.expectEqual(original.price, parsed.price);
}
