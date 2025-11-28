//! Core protocol types for the matching engine client.
//!
//! All structures are carefully sized and aligned to prevent false sharing
//! and maximize cache efficiency. Binary protocol structs match the C server's
//! wire format exactly - see ARCHITECTURE.md for layout details.

const std = @import("std");

/// Cache line size on modern x86-64 and ARM64 processors.
/// All hot-path structures should be aligned to this boundary.
pub const CACHE_LINE_SIZE = 64;

/// Magic byte indicating binary protocol (vs CSV text).
/// First byte of every binary message must be this value.
pub const MAGIC_BYTE: u8 = 0x4D; // 'M'

/// Maximum symbol length (null-padded in binary protocol)
pub const MAX_SYMBOL_LEN = 8;

/// Maximum CSV message length
pub const MAX_CSV_LEN = 256;

// ============================================================
// Enums (packed as u8 to save space - 1 byte vs 4 byte int)
// ============================================================

pub const Side = enum(u8) {
    buy = 'B',
    sell = 'S',

    pub fn toChar(self: Side) u8 {
        return @intFromEnum(self);
    }

    pub fn fromChar(c: u8) ?Side {
        return switch (c) {
            'B', 'b' => .buy,
            'S', 's' => .sell,
            else => null,
        };
    }
};

pub const InputMsgType = enum(u8) {
    new_order = 'N',
    cancel = 'C',
    flush = 'F',
};

pub const OutputMsgType = enum(u8) {
    ack = 'A',
    cancel_ack = 'X',
    trade = 'T',
    top_of_book = 'B',
};

// ============================================================
// Binary Protocol Input Messages
// These structs are packed and match the C server wire format
// ============================================================

/// Binary new order message - 30 bytes on wire.
/// Layout:
///   [0]     magic (0x4D)
///   [1]     msg_type ('N')
///   [2-5]   user_id (big-endian)
///   [6-13]  symbol (null-padded)
///   [14-17] price (big-endian)
///   [18-21] quantity (big-endian)
///   [22]    side ('B' or 'S')
///   [23-26] user_order_id (big-endian)
///   [27-29] padding
pub const BinaryNewOrder = extern struct {
    magic: u8 = MAGIC_BYTE,
    msg_type: u8 = @intFromEnum(InputMsgType.new_order),
    user_id: u32 align(1),
    symbol: [MAX_SYMBOL_LEN]u8,
    price: u32 align(1),
    quantity: u32 align(1),
    side: u8,
    user_order_id: u32 align(1),
    _pad: [3]u8 = .{ 0, 0, 0 },

    // Compile-time size verification - catches layout bugs immediately
    comptime {
        if (@sizeOf(BinaryNewOrder) != 30) {
            @compileError("BinaryNewOrder must be exactly 30 bytes");
        }
    }

    pub fn init(
        user_id: u32,
        symbol: []const u8,
        price: u32,
        quantity: u32,
        side: Side,
        order_id: u32,
    ) BinaryNewOrder {
        var sym: [MAX_SYMBOL_LEN]u8 = .{0} ** MAX_SYMBOL_LEN;
        const len = @min(symbol.len, MAX_SYMBOL_LEN);
        @memcpy(sym[0..len], symbol[0..len]);

        return .{
            .user_id = std.mem.nativeToBig(u32, user_id),
            .symbol = sym,
            .price = std.mem.nativeToBig(u32, price),
            .quantity = std.mem.nativeToBig(u32, quantity),
            .side = side.toChar(),
            .user_order_id = std.mem.nativeToBig(u32, order_id),
        };
    }

    pub fn asBytes(self: *const BinaryNewOrder) []const u8 {
        return std.mem.asBytes(self);
    }
};

/// Binary cancel order message - 11 bytes on wire.
pub const BinaryCancel = extern struct {
    magic: u8 = MAGIC_BYTE,
    msg_type: u8 = @intFromEnum(InputMsgType.cancel),
    user_id: u32 align(1),
    user_order_id: u32 align(1),
    _pad: u8 = 0,

    comptime {
        if (@sizeOf(BinaryCancel) != 11) {
            @compileError("BinaryCancel must be exactly 11 bytes");
        }
    }

    pub fn init(user_id: u32, order_id: u32) BinaryCancel {
        return .{
            .user_id = std.mem.nativeToBig(u32, user_id),
            .user_order_id = std.mem.nativeToBig(u32, order_id),
        };
    }

    pub fn asBytes(self: *const BinaryCancel) []const u8 {
        return std.mem.asBytes(self);
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

    pub fn asBytes(self: *const BinaryFlush) []const u8 {
        return std.mem.asBytes(self);
    }
};

// ============================================================
// Binary Protocol Output Messages
// ============================================================

/// Binary acknowledgement - 19 bytes on wire.
pub const BinaryAck = extern struct {
    magic: u8,
    msg_type: u8,
    symbol: [MAX_SYMBOL_LEN]u8,
    user_id: u32 align(1),
    user_order_id: u32 align(1),
    _pad: u8 = 0,

    comptime {
        if (@sizeOf(BinaryAck) != 19) {
            @compileError("BinaryAck must be exactly 19 bytes");
        }
    }

    pub fn getUserId(self: *const BinaryAck) u32 {
        return std.mem.bigToNative(u32, self.user_id);
    }

    pub fn getOrderId(self: *const BinaryAck) u32 {
        return std.mem.bigToNative(u32, self.user_order_id);
    }

    pub fn getSymbol(self: *const BinaryAck) []const u8 {
        // Find null terminator or return full length
        for (self.symbol, 0..) |c, i| {
            if (c == 0) return self.symbol[0..i];
        }
        return &self.symbol;
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

    pub fn getSellUserId(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.sell_user_id);
    }

    pub fn getPrice(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.price);
    }

    pub fn getQuantity(self: *const BinaryTrade) u32 {
        return std.mem.bigToNative(u32, self.quantity);
    }

    pub fn getSymbol(self: *const BinaryTrade) []const u8 {
        for (self.symbol, 0..) |c, i| {
            if (c == 0) return self.symbol[0..i];
        }
        return &self.symbol;
    }
};

/// Binary top-of-book update - 20 bytes on wire.
pub const BinaryTopOfBook = extern struct {
    magic: u8,
    msg_type: u8,
    symbol: [MAX_SYMBOL_LEN]u8,
    side: u8,
    _pad: u8 = 0,
    price: u32 align(1),
    quantity: u32 align(1),

    comptime {
        if (@sizeOf(BinaryTopOfBook) != 20) {
            @compileError("BinaryTopOfBook must be exactly 20 bytes");
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
        for (self.symbol, 0..) |c, i| {
            if (c == 0) return self.symbol[0..i];
        }
        return &self.symbol;
    }
};

// ============================================================
// High-level parsed output message (cache-line aligned)
// ============================================================

/// Parsed output message - aligned to cache line to prevent false sharing
/// when processing messages in parallel or across thread boundaries.
pub const OutputMessage = struct {
    msg_type: OutputMsgType,        // 1 byte
    symbol: [MAX_SYMBOL_LEN]u8,     // 8 bytes
    symbol_len: u8,                 // 1 byte
    side: ?Side = null,             // 2 bytes (tag + value)
    
    // Group u32 fields together for natural alignment
    user_id: u32 = 0,               // 4 bytes
    order_id: u32 = 0,              // 4 bytes
    buy_user_id: u32 = 0,           // 4 bytes
    buy_order_id: u32 = 0,          // 4 bytes
    sell_user_id: u32 = 0,          // 4 bytes
    sell_order_id: u32 = 0,         // 4 bytes
    price: u32 = 0,                 // 4 bytes
    quantity: u32 = 0,              // 4 bytes
    // Total so far: 1+8+1+2+4*8 = 44 bytes
    
    // Padding to reach 64 bytes
    _padding: [20]u8 = undefined,

    pub fn getSymbol(self: *const OutputMessage) []const u8 {
        return self.symbol[0..self.symbol_len];
    }
};

// ============================================================
// Tests
// ============================================================

test "BinaryNewOrder layout and encoding" {
    const order = BinaryNewOrder.init(
        1, // user_id
        "IBM",
        10000, // price ($100.00)
        50, // quantity
        .buy,
        1001, // order_id
    );

    const bytes = order.asBytes();

    // Verify magic and type
    try std.testing.expectEqual(@as(u8, 0x4D), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'N'), bytes[1]);

    // Verify size
    try std.testing.expectEqual(@as(usize, 30), bytes.len);

    // Verify symbol null-padded
    try std.testing.expectEqualStrings("IBM", bytes[6..9]);
    try std.testing.expectEqual(@as(u8, 0), bytes[9]);
}

test "BinaryCancel layout" {
    const cancel = BinaryCancel.init(42, 1001);
    const bytes = cancel.asBytes();

    try std.testing.expectEqual(@as(u8, 0x4D), bytes[0]);
    try std.testing.expectEqual(@as(u8, 'C'), bytes[1]);
    try std.testing.expectEqual(@as(usize, 11), bytes.len);
}

test "Side enum conversion" {
    try std.testing.expectEqual(Side.buy, Side.fromChar('B').?);
    try std.testing.expectEqual(Side.sell, Side.fromChar('S').?);
    try std.testing.expectEqual(Side.buy, Side.fromChar('b').?);
    try std.testing.expectEqual(@as(?Side, null), Side.fromChar('X'));
}

test "OutputMessage is cache-line sized" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(OutputMessage));
}
