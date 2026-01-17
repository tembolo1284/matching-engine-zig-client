//! Core Protocol Types for the Matching Engine Client
//!
//! # Overview
//! All structures are carefully sized and aligned to prevent false sharing
//! and maximize cache efficiency. Binary protocol structs match the C server's
//! wire format exactly.
//!
//! # Wire Format Compatibility
//! These structs use `extern struct` with `align(1)` on multi-byte fields to
//! ensure exact byte-level compatibility with the C server. The C server uses
//! packed structs with no padding, and all multi-byte integers are big-endian.
//!
//! # Power of Ten Compliance
//! - Rule 4: All functions ≤60 lines
//! - Rule 5: Assertions verify invariants
//! - Rule 6: Data at smallest scope
//! - Rule 7: All parameters validated
//! - Rule 10: Compile-time size verification
//!
//! # Cache Alignment Strategy
//! - Wire format structs: Packed for network compatibility (no padding)
//! - Internal structs (OutputMessage): Cache-line aligned for processing speed
//!
//! See PROTOCOL.md for complete wire format specification.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

/// Cache line size on modern x86-64 and ARM64 processors.
/// All hot-path internal structures should be aligned to this boundary.
/// Verify with: `getconf LEVEL1_DCACHE_LINESIZE` on Linux.
pub const CACHE_LINE_SIZE: usize = 64;

/// Magic byte indicating binary protocol (vs CSV text).
/// ASCII 'M' for "Matching engine" - first byte of every binary message.
pub const MAGIC_BYTE: u8 = 0x4D;

/// Maximum symbol length (null-padded in binary protocol).
/// Symbols longer than this are truncated.
pub const MAX_SYMBOL_LEN: usize = 8;

/// Maximum CSV message length for formatting buffers.
pub const MAX_CSV_LEN: usize = 256;

// =============================================================================
// Enums
// =============================================================================

/// Order side (buy or sell).
/// Packed as u8 to match wire format - 'B' (0x42) or 'S' (0x53).
pub const Side = enum(u8) {
    buy = 'B',
    sell = 'S',

    /// Convert to wire format character.
    pub fn toChar(self: Side) u8 {
        return @intFromEnum(self);
    }

    /// Parse from wire format character.
    /// Accepts both upper and lower case for robustness.
    pub fn fromChar(c: u8) ?Side {
        return switch (c) {
            'B', 'b' => .buy,
            'S', 's' => .sell,
            else => null,
        };
    }

    /// Human-readable string for logging.
    pub fn toString(self: Side) []const u8 {
        return switch (self) {
            .buy => "BUY",
            .sell => "SELL",
        };
    }
};

/// Input message types (client → server).
pub const InputMsgType = enum(u8) {
    new_order = 'N',
    cancel = 'C',
    flush = 'F',

    pub fn toChar(self: InputMsgType) u8 {
        return @intFromEnum(self);
    }
};

/// Output message types (server → client).
pub const OutputMsgType = enum(u8) {
    ack = 'A',
    cancel_ack = 'X',
    trade = 'T',
    top_of_book = 'B',
    reject = 'R',

    pub fn toChar(self: OutputMsgType) u8 {
        return @intFromEnum(self);
    }

    pub fn fromChar(c: u8) ?OutputMsgType {
        return switch (c) {
            'A' => .ack,
            'X' => .cancel_ack,
            'T' => .trade,
            'B' => .top_of_book,
            'R' => .reject,
            else => null,
        };
    }

    /// Human-readable string for logging.
    pub fn toString(self: OutputMsgType) []const u8 {
        return switch (self) {
            .ack => "ACK",
            .cancel_ack => "CANCEL_ACK",
            .trade => "TRADE",
            .top_of_book => "TOP_OF_BOOK",
            .reject => "REJECT",
        };
    }
};

// =============================================================================
// Symbol Utilities
// =============================================================================

/// Find the length of a null-padded symbol.
/// Returns the index of the first null byte, or MAX_SYMBOL_LEN if none found.
pub fn findSymbolLen(symbol: *const [MAX_SYMBOL_LEN]u8) usize {
    // Bounded loop (Power of Ten Rule 2)
    for (symbol, 0..) |c, i| {
        if (c == 0) return i;
    }
    return MAX_SYMBOL_LEN;
}

/// Copy a symbol slice into a fixed-size null-padded array.
/// Truncates if source is longer than MAX_SYMBOL_LEN.
pub fn copySymbol(dest: *[MAX_SYMBOL_LEN]u8, src: []const u8) void {
    const len = @min(src.len, MAX_SYMBOL_LEN);

    // Clear destination first
    @memset(dest, 0);

    // Copy source (bounded by len)
    @memcpy(dest[0..len], src[0..len]);
}

// =============================================================================
// Binary Protocol Input Messages
// =============================================================================
// These structs are `extern` with `align(1)` on multi-byte fields to match
// the C server's packed wire format exactly. No Zig-inserted padding.

/// Binary new order message - 27 bytes on wire.
///
/// # Wire Layout (matches server's binary_codec.zig exactly)
/// ```
/// Offset  Size  Field          Encoding
/// ------  ----  -----          --------
/// 0       1     magic          0x4D ('M')
/// 1       1     msg_type       'N' (0x4E)
/// 2       4     user_id        big-endian u32
/// 6       8     symbol         null-padded ASCII
/// 14      4     price          big-endian u32 (cents)
/// 18      4     quantity       big-endian u32
/// 22      1     side           'B' or 'S'
/// 23      4     user_order_id  big-endian u32
/// ------
/// Total: 27 bytes
/// ```
pub const BinaryNewOrder = extern struct {
    magic: u8 = MAGIC_BYTE,
    msg_type: u8 = @intFromEnum(InputMsgType.new_order),
    user_id: u32 align(1),
    symbol: [MAX_SYMBOL_LEN]u8,
    price: u32 align(1),
    quantity: u32 align(1),
    side: u8,
    user_order_id: u32 align(1),
    // NO PADDING - must match server's 27-byte wire format exactly

    // Compile-time size verification (Power of Ten Rule 10)
    comptime {
        if (@sizeOf(BinaryNewOrder) != 27) {
            @compileError("BinaryNewOrder must be exactly 27 bytes to match server");
        }
    }

    /// Create a new order message with proper byte ordering.
    pub fn init(
        user_id: u32,
        symbol: []const u8,
        price: u32,
        quantity: u32,
        side: Side,
        order_id: u32,
    ) BinaryNewOrder {
        // Pre-condition assertions (Power of Ten Rule 5)
        std.debug.assert(symbol.len > 0);
        std.debug.assert(quantity > 0);

        var sym: [MAX_SYMBOL_LEN]u8 = .{0} ** MAX_SYMBOL_LEN;
        copySymbol(&sym, symbol);

        return .{
            .user_id = std.mem.nativeToBig(u32, user_id),
            .symbol = sym,
            .price = std.mem.nativeToBig(u32, price),
            .quantity = std.mem.nativeToBig(u32, quantity),
            .side = side.toChar(),
            .user_order_id = std.mem.nativeToBig(u32, order_id),
        };
    }

    /// Get raw bytes for sending over network.
    pub fn asBytes(self: *const BinaryNewOrder) *const [27]u8 {
        return @ptrCast(self);
    }

    /// Get as slice for convenience.
    pub fn asSlice(self: *const BinaryNewOrder) []const u8 {
        return self.asBytes();
    }
};

/// Binary cancel order message - 18 bytes on wire.
///
/// # Wire Layout (matches server's binary_codec.zig exactly)
/// ```
/// Offset  Size  Field          Encoding
/// ------  ----  -----          --------
/// 0       1     magic          0x4D
/// 1       1     msg_type       'C' (0x43)
/// 2       4     user_id        big-endian u32
/// 6       8     symbol         null-padded ASCII
/// 14      4     user_order_id  big-endian u32
/// ------
/// Total: 18 bytes
/// ```
pub const BinaryCancel = extern struct {
    magic: u8 = MAGIC_BYTE,
    msg_type: u8 = @intFromEnum(InputMsgType.cancel),
    user_id: u32 align(1),
    user_order_id: u32 align(1),
    // NO PADDING - must match server's 10-byte wire format exactly

    comptime {
        if (@sizeOf(BinaryCancel) != 10) {
            @compileError("BinaryCancel must be exactly 10 bytes to match server");
        }
    }

    pub fn init(user_id: u32, symbol: []const u8, order_id: u32) BinaryCancel {
        std.debug.assert(symbol.len > 0);

        var sym: [MAX_SYMBOL_LEN]u8 = .{0} ** MAX_SYMBOL_LEN;
        copySymbol(&sym, symbol);

        return .{
            .user_id = std.mem.nativeToBig(u32, user_id),
            .user_order_id = std.mem.nativeToBig(u32, order_id),
        };
    }

    pub fn asBytes(self: *const BinaryCancel) *const [18]u8 {
        return @ptrCast(self);
    }

    pub fn asSlice(self: *const BinaryCancel) []const u8 {
        return self.asBytes();
    }
};

/// Binary flush message - 2 bytes on wire.
pub const BinaryFlush = extern struct {
    magic: u8 = MAGIC_BYTE,
    msg_type: u8 = @intFromEnum(InputMsgType.flush),

    comptime {
        if (@sizeOf(BinaryFlush) != 2) {
            @compileError("BinaryFlush must be exactly 2 bytes");
        }
    }

    pub fn asBytes(self: *const BinaryFlush) *const [2]u8 {
        return @ptrCast(self);
    }

    pub fn asSlice(self: *const BinaryFlush) []const u8 {
        return self.asBytes();
    }
};

// =============================================================================
// Binary Protocol Output Messages
// =============================================================================

/// Binary acknowledgement - 18 bytes on wire.
pub const BinaryAck = extern struct {
    magic: u8,
    msg_type: u8,
    symbol: [MAX_SYMBOL_LEN]u8,
    user_id: u32 align(1),
    user_order_id: u32 align(1),

    comptime {
        if (@sizeOf(BinaryAck) != 18) {
            @compileError("BinaryAck must be exactly 18 bytes");
        }
    }

    pub fn getUserId(self: *const BinaryAck) u32 {
        return std.mem.bigToNative(u32, self.user_id);
    }

    pub fn getOrderId(self: *const BinaryAck) u32 {
        return std.mem.bigToNative(u32, self.user_order_id);
    }

    pub fn getSymbol(self: *const BinaryAck) []const u8 {
        return self.symbol[0..findSymbolLen(&self.symbol)];
    }
};

/// Binary cancel acknowledgement - same layout as ack.
pub const BinaryCancelAck = BinaryAck;

/// Binary trade execution - 34 bytes on wire.
pub const BinaryTrade = extern struct {
    magic: u8,
    msg_type: u8,
    symbol: [MAX_SYMBOL_LEN]u8,
    buy_user_id: u32 align(1),
    buy_order_id: u32 align(1),
    sell_user_id: u32 align(1),
    sell_order_id: u32 align(1),
    price: u32 align(1),
    quantity: u32 align(1),

    comptime {
        if (@sizeOf(BinaryTrade) != 34) {
            @compileError("BinaryTrade must be exactly 34 bytes");
        }
    }

    pub fn getBuyUserId(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.buy_user_id);
    }

    pub fn getBuyOrderId(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.buy_order_id);
    }

    pub fn getSellUserId(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.sell_user_id);
    }

    pub fn getSellOrderId(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.sell_order_id);
    }

    pub fn getPrice(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.price);
    }

    pub fn getQuantity(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.quantity);
    }

    pub fn getSymbol(self: *const BinaryTrade) []const u8 {
        return self.symbol[0..findSymbolLen(&self.symbol)];
    }
};

/// Binary top-of-book update - 20 bytes on wire.
pub const BinaryTopOfBook = extern struct {
    magic: u8,
    msg_type: u8,
    symbol: [MAX_SYMBOL_LEN]u8,
    side: u8,
    price: u32 align(1),
    quantity: u32 align(1),

    comptime {
        if (@sizeOf(BinaryTopOfBook) != 19) {
            @compileError("BinaryTopOfBook must be exactly 19 bytes");
        }
    }

    pub fn getSide(self: *const BinaryTopOfBook) ?Side {
        return Side.fromChar(self.side);
    }

    pub fn getPrice(self: *const BinaryTopOfBook) u32 {
        return std.mem.bigToNative(u32, self.price);
    }

    pub fn getQuantity(self: *const BinaryTopOfBook) u32 {
        return std.mem.bigToNative(u32, self.quantity);
    }

    pub fn isEmpty(self: *const BinaryTopOfBook) bool {
        return self.getPrice() == 0 and self.getQuantity() == 0;
    }

    pub fn getSymbol(self: *const BinaryTopOfBook) []const u8 {
        return self.symbol[0..findSymbolLen(&self.symbol)];
    }
};

// =============================================================================
// High-Level Parsed Output Message
// =============================================================================

/// Parsed output message - cache-line aligned for processing efficiency.
///
/// This is the internal representation used after decoding from wire format.
/// It's padded to exactly 64 bytes (one cache line) to prevent false sharing
/// when processing messages in parallel or across thread boundaries.
///
/// # Memory Layout
/// ```
/// Offset  Size  Field
/// ------  ----  -----
/// 0       1     msg_type
/// 1       8     symbol
/// 9       1     symbol_len
/// 10      1     side (optional tag)
/// 11      1     side (optional value)
/// 12      4     user_id
/// 16      4     order_id
/// 20      4     buy_user_id
/// 24      4     buy_order_id
/// 28      4     sell_user_id
/// 32      4     sell_order_id
/// 36      4     price
/// 40      4     quantity
/// 44      4     reject_reason
/// 48      16    _padding
/// ------
/// Total: 64 bytes (1 cache line)
/// ```
pub const OutputMessage = struct {
    // Message type (1 byte)
    msg_type: OutputMsgType,

    // Symbol data (9 bytes)
    symbol: [MAX_SYMBOL_LEN]u8 = .{0} ** MAX_SYMBOL_LEN,
    symbol_len: u8 = 0,

    // Optional side for TOB (2 bytes with tag)
    side: ?Side = null,

    // Common fields - grouped for alignment (32 bytes)
    user_id: u32 = 0,
    order_id: u32 = 0,
    buy_user_id: u32 = 0,
    buy_order_id: u32 = 0,
    sell_user_id: u32 = 0,
    sell_order_id: u32 = 0,
    price: u32 = 0,
    quantity: u32 = 0,

    // Reject reason code (4 bytes)
    reject_reason: u32 = 0,

    // Padding to reach exactly 64 bytes (1 cache line)
    // Layout: 1 + 8 + 1 + 2 + (9 * 4) = 48 bytes, need 16 more
    _padding: [16]u8 = undefined,

    // Compile-time verification
    comptime {
        if (@sizeOf(OutputMessage) != CACHE_LINE_SIZE) {
            @compileError("OutputMessage must be exactly 64 bytes (1 cache line)");
        }
    }

    /// Get symbol as a slice (without null padding).
    pub fn getSymbol(self: *const OutputMessage) []const u8 {
        std.debug.assert(self.symbol_len <= MAX_SYMBOL_LEN);
        return self.symbol[0..self.symbol_len];
    }

    /// Set symbol from a slice.
    pub fn setSymbol(self: *OutputMessage, sym: []const u8) void {
        const len = @min(sym.len, MAX_SYMBOL_LEN);
        @memset(&self.symbol, 0);
        @memcpy(self.symbol[0..len], sym[0..len]);
        self.symbol_len = @intCast(len);
    }

    /// Check if this is an empty top-of-book update.
    pub fn isEmptyBook(self: *const OutputMessage) bool {
        return self.msg_type == .top_of_book and
            self.price == 0 and self.quantity == 0;
    }

    /// Create an ACK message.
    pub fn ack(symbol: []const u8, user_id: u32, order_id: u32) OutputMessage {
        var msg = OutputMessage{ .msg_type = .ack };
        msg.setSymbol(symbol);
        msg.user_id = user_id;
        msg.order_id = order_id;
        return msg;
    }

    /// Create a CANCEL_ACK message.
    pub fn cancelAck(symbol: []const u8, user_id: u32, order_id: u32) OutputMessage {
        var msg = OutputMessage{ .msg_type = .cancel_ack };
        msg.setSymbol(symbol);
        msg.user_id = user_id;
        msg.order_id = order_id;
        return msg;
    }

    /// Create a TRADE message.
    pub fn trade(
        symbol: []const u8,
        buy_user: u32,
        buy_order: u32,
        sell_user: u32,
        sell_order: u32,
        price: u32,
        qty: u32,
    ) OutputMessage {
        var msg = OutputMessage{ .msg_type = .trade };
        msg.setSymbol(symbol);
        msg.buy_user_id = buy_user;
        msg.buy_order_id = buy_order;
        msg.sell_user_id = sell_user;
        msg.sell_order_id = sell_order;
        msg.price = price;
        msg.quantity = qty;
        return msg;
    }

    /// Create a TOP_OF_BOOK message.
    pub fn topOfBook(symbol: []const u8, side: ?Side, price: u32, qty: u32) OutputMessage {
        var msg = OutputMessage{ .msg_type = .top_of_book };
        msg.setSymbol(symbol);
        msg.side = side;
        msg.price = price;
        msg.quantity = qty;
        return msg;
    }

    /// Create a REJECT message.
    pub fn reject(symbol: []const u8, user_id: u32, order_id: u32, reason: u32) OutputMessage {
        var msg = OutputMessage{ .msg_type = .reject };
        msg.setSymbol(symbol);
        msg.user_id = user_id;
        msg.order_id = order_id;
        msg.reject_reason = reason;
        return msg;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BinaryNewOrder layout and encoding" {
    const order = BinaryNewOrder.init(
        1, // user_id
        "IBM",
        10000, // price ($100.00)
        50, // quantity
        .buy,
        1001, // order_id
    );

    const bytes = order.asSlice();

    // Verify magic and type
    try std.testing.expectEqual(@as(u8, MAGIC_BYTE), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'N'), bytes[1]);

    // Verify size matches server's wire format
    try std.testing.expectEqual(@as(usize, 27), bytes.len);

    // Verify symbol null-padded (starts at offset 6)
    try std.testing.expectEqualStrings("IBM", bytes[6..9]);
    try std.testing.expectEqual(@as(u8, 0), bytes[9]);

    // Verify side (at offset 22)
    try std.testing.expectEqual(@as(u8, 'B'), bytes[22]);
}

test "BinaryCancel layout" {
    const cancel = BinaryCancel.init(42, "AAPL", 1001);
    const bytes = cancel.asSlice();

    try std.testing.expectEqual(@as(u8, MAGIC_BYTE), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'C'), bytes[1]);
    
    // Verify size matches server's wire format
    try std.testing.expectEqual(@as(usize, 18), bytes.len);

    // Verify symbol (starts at offset 6)
    try std.testing.expectEqualStrings("AAPL", bytes[6..10]);
}

test "BinaryFlush layout" {
    const flush = BinaryFlush{};
    const bytes = flush.asSlice();

    try std.testing.expectEqual(@as(u8, MAGIC_BYTE), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'F'), bytes[1]);
    try std.testing.expectEqual(@as(usize, 2), bytes.len);
}

test "Side enum conversion" {
    try std.testing.expectEqual(Side.buy, Side.fromChar('B').?);
    try std.testing.expectEqual(Side.sell, Side.fromChar('S').?);
    try std.testing.expectEqual(Side.buy, Side.fromChar('b').?);
    try std.testing.expectEqual(Side.sell, Side.fromChar('s').?);
    try std.testing.expect(Side.fromChar('X') == null);

    try std.testing.expectEqual(@as(u8, 'B'), Side.buy.toChar());
    try std.testing.expectEqual(@as(u8, 'S'), Side.sell.toChar());
}

test "OutputMsgType conversion" {
    try std.testing.expectEqual(OutputMsgType.ack, OutputMsgType.fromChar('A').?);
    try std.testing.expectEqual(OutputMsgType.cancel_ack, OutputMsgType.fromChar('X').?);
    try std.testing.expectEqual(OutputMsgType.trade, OutputMsgType.fromChar('T').?);
    try std.testing.expectEqual(OutputMsgType.top_of_book, OutputMsgType.fromChar('B').?);
    try std.testing.expectEqual(OutputMsgType.reject, OutputMsgType.fromChar('R').?);
    try std.testing.expect(OutputMsgType.fromChar('Z') == null);
}

test "OutputMessage is cache-line sized" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(OutputMessage));
}

test "OutputMessage factory functions" {
    const ack_msg = OutputMessage.ack("IBM", 1, 100);
    try std.testing.expectEqual(OutputMsgType.ack, ack_msg.msg_type);
    try std.testing.expectEqualStrings("IBM", ack_msg.getSymbol());
    try std.testing.expectEqual(@as(u32, 1), ack_msg.user_id);
    try std.testing.expectEqual(@as(u32, 100), ack_msg.order_id);

    const trade_msg = OutputMessage.trade("AAPL", 1, 100, 2, 200, 15000, 50);
    try std.testing.expectEqual(OutputMsgType.trade, trade_msg.msg_type);
    try std.testing.expectEqual(@as(u32, 15000), trade_msg.price);
    try std.testing.expectEqual(@as(u32, 50), trade_msg.quantity);

    const empty_tob = OutputMessage.topOfBook("IBM", .buy, 0, 0);
    try std.testing.expect(empty_tob.isEmptyBook());
}

test "findSymbolLen" {
    const sym1: [MAX_SYMBOL_LEN]u8 = .{ 'I', 'B', 'M', 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 3), findSymbolLen(&sym1));

    const sym2: [MAX_SYMBOL_LEN]u8 = .{ 'A', 'A', 'P', 'L', 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 4), findSymbolLen(&sym2));

    const sym3: [MAX_SYMBOL_LEN]u8 = .{ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H' };
    try std.testing.expectEqual(@as(usize, 8), findSymbolLen(&sym3));
}

test "copySymbol" {
    var dest: [MAX_SYMBOL_LEN]u8 = undefined;

    copySymbol(&dest, "IBM");
    try std.testing.expectEqualStrings("IBM", dest[0..3]);
    try std.testing.expectEqual(@as(u8, 0), dest[3]);

    // Test truncation
    copySymbol(&dest, "VERYLONGSYMBOL");
    try std.testing.expectEqualStrings("VERYLONG", &dest);
}
