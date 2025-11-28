//! Fluent order builder for ergonomic order construction.
//!
//! Provides a builder pattern API for constructing orders with validation.
//! Useful when order parameters come from multiple sources or need
//! transformation before sending.

const std = @import("std");
const types = @import("../protocol/types.zig");
const EngineClient = @import("engine_client.zig").EngineClient;

pub const OrderBuilder = struct {
    user_id: ?u32 = null,
    symbol: ?[]const u8 = null,
    price: ?u32 = null,
    quantity: ?u32 = null,
    side: ?types.Side = null,
    order_id: ?u32 = null,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn userId(self: Self, id: u32) Self {
        var copy = self;
        copy.user_id = id;
        return copy;
    }

    pub fn sym(self: Self, s: []const u8) Self {
        var copy = self;
        copy.symbol = s;
        return copy;
    }

    /// Set price in cents (e.g., 10000 = $100.00)
    pub fn priceRaw(self: Self, p: u32) Self {
        var copy = self;
        copy.price = p;
        return copy;
    }

    /// Set price from dollars (converts to cents)
    pub fn priceDollars(self: Self, dollars: f64) Self {
        var copy = self;
        copy.price = @intFromFloat(dollars * 100.0);
        return copy;
    }

    pub fn qty(self: Self, q: u32) Self {
        var copy = self;
        copy.quantity = q;
        return copy;
    }

    pub fn buy(self: Self) Self {
        var copy = self;
        copy.side = .buy;
        return copy;
    }

    pub fn sell(self: Self) Self {
        var copy = self;
        copy.side = .sell;
        return copy;
    }

    pub fn orderId(self: Self, id: u32) Self {
        var copy = self;
        copy.order_id = id;
        return copy;
    }

    /// Validate and send the order
    pub fn send(self: Self, client: *EngineClient) !void {
        // Validate all required fields are set
        const uid = self.user_id orelse return error.MissingUserId;
        const s = self.symbol orelse return error.MissingSymbol;
        const p = self.price orelse return error.MissingPrice;
        const q = self.quantity orelse return error.MissingQuantity;
        const sd = self.side orelse return error.MissingSide;
        const oid = self.order_id orelse return error.MissingOrderId;

        // Validate constraints
        if (s.len == 0 or s.len > types.MAX_SYMBOL_LEN) return error.InvalidSymbol;
        if (q == 0) return error.InvalidQuantity;

        try client.sendNewOrder(uid, s, p, q, sd, oid);
    }

    /// Build binary message without sending (for testing/inspection)
    pub fn buildBinary(self: Self) !types.BinaryNewOrder {
        const uid = self.user_id orelse return error.MissingUserId;
        const s = self.symbol orelse return error.MissingSymbol;
        const p = self.price orelse return error.MissingPrice;
        const q = self.quantity orelse return error.MissingQuantity;
        const sd = self.side orelse return error.MissingSide;
        const oid = self.order_id orelse return error.MissingOrderId;

        return types.BinaryNewOrder.init(uid, s, p, q, sd, oid);
    }
};

/// Start building an order
pub fn order() OrderBuilder {
    return OrderBuilder.init();
}

// ============================================================
// Tests
// ============================================================

test "order builder validation" {
    // Missing fields should error
    const incomplete = order().userId(1).sym("IBM");
    try std.testing.expectError(error.MissingPrice, incomplete.buildBinary());
}

test "order builder complete" {
    const msg = try order()
        .userId(1)
        .sym("IBM")
        .priceDollars(100.0)
        .qty(50)
        .buy()
        .orderId(1001)
        .buildBinary();

    try std.testing.expectEqual(@as(u8, 0x4D), msg.magic);
    try std.testing.expectEqual(@as(u8, 'N'), msg.msg_type);
}

test "price conversion" {
    const builder = order().priceDollars(123.45);
    try std.testing.expectEqual(@as(u32, 12345), builder.price.?);
}
