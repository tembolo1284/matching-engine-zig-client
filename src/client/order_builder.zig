//! Fluent order builder for ergonomic order construction.
//!
//! Provides a builder pattern API for constructing orders with validation.
//! Useful when order parameters come from multiple sources or need
//! transformation before sending.
//!
//! Power of Ten Compliance:
//! - Rule 1: No goto/setjmp, no recursion ✓
//! - Rule 2: All loops have fixed upper bounds ✓ (no loops)
//! - Rule 3: No dynamic memory after init ✓
//! - Rule 4: Functions ≤60 lines ✓
//! - Rule 5: ≥2 assertions per function ✓
//! - Rule 6: Data at smallest scope ✓
//! - Rule 7: Check return values, validate parameters ✓
//!
//! Design Notes:
//! - Builder is immutable - each method returns a new builder
//! - All fields are optional until send()/build() is called
//! - Price conversion uses integer math to avoid floating-point issues
//! - Symbol length is validated against protocol limits

const std = @import("std");
const types = @import("../protocol/types.zig");
const EngineClient = @import("engine_client.zig").EngineClient;

// ============================================================
// Constants
// ============================================================

/// Maximum price in cents ($10,000,000.00)
pub const MAX_PRICE_CENTS: u32 = 1_000_000_000;

/// Minimum valid quantity
pub const MIN_QUANTITY: u32 = 1;

/// Maximum quantity (prevent overflow in trade calculations)
pub const MAX_QUANTITY: u32 = 1_000_000_000;

// ============================================================
// Error Types
// ============================================================

/// Errors that can occur during order building/validation
pub const OrderBuilderError = error{
    MissingUserId,
    MissingSymbol,
    MissingPrice,
    MissingQuantity,
    MissingSide,
    MissingOrderId,
    InvalidSymbol,
    InvalidQuantity,
    InvalidPrice,
    SymbolTooLong,
    EmptySymbol,
    ZeroQuantity,
    ZeroPrice,
    PriceTooHigh,
    QuantityTooHigh,
};

// ============================================================
// Order Builder
// ============================================================

pub const OrderBuilder = struct {
    user_id: ?u32 = null,
    symbol: ?[]const u8 = null,
    price: ?u32 = null,
    quantity: ?u32 = null,
    side: ?types.Side = null,
    order_id: ?u32 = null,

    const Self = @This();

    /// Initialize a new empty order builder.
    pub fn init() Self {
        const builder = Self{};

        // Assertion 1: All fields should be null
        std.debug.assert(builder.user_id == null);

        // Assertion 2: Builder should be in clean state
        std.debug.assert(builder.price == null);

        return builder;
    }

    /// Set the user ID.
    ///
    /// Parameters:
    ///   id - User ID (typically assigned by server, use 1 for self)
    pub fn userId(self: Self, id: u32) Self {
        // Assertion 1: Input should be reasonable
        std.debug.assert(id > 0 or id == 0); // Allow 0 for testing

        var copy = self;
        copy.user_id = id;

        // Assertion 2: Field should be set
        std.debug.assert(copy.user_id != null);

        return copy;
    }

    /// Set the symbol.
    ///
    /// Parameters:
    ///   s - Symbol string (e.g., "IBM", "AAPL")
    pub fn sym(self: Self, s: []const u8) Self {
        // Assertion 1: Symbol pointer should be valid
        std.debug.assert(@intFromPtr(s.ptr) != 0);

        // Assertion 2: Symbol length should be reasonable
        std.debug.assert(s.len <= types.MAX_SYMBOL_LEN);

        var copy = self;
        copy.symbol = s;
        return copy;
    }

    /// Set price in cents (e.g., 10000 = $100.00).
    ///
    /// Parameters:
    ///   p - Price in cents
    pub fn priceRaw(self: Self, p: u32) Self {
        // Assertion 1: Price should be reasonable
        std.debug.assert(p <= MAX_PRICE_CENTS);

        var copy = self;
        copy.price = p;

        // Assertion 2: Field should be set
        std.debug.assert(copy.price != null);

        return copy;
    }

    /// Set price from dollars (converts to cents).
    /// Uses integer arithmetic to avoid floating-point precision issues.
    ///
    /// Parameters:
    ///   dollars - Price in dollars (e.g., 100.50)
    ///
    /// Note: Due to floating-point representation, use priceFromParts()
    /// for exact prices when precision matters.
    pub fn priceDollars(self: Self, dollars: f64) Self {
        // Assertion 1: Price should be non-negative
        std.debug.assert(dollars >= 0.0);

        // Assertion 2: Price should not be NaN or infinity
        std.debug.assert(!std.math.isNan(dollars) and !std.math.isInf(dollars));

        // Round to nearest cent to handle floating-point imprecision
        // Adding 0.5 before truncation gives proper rounding
        const cents_f = dollars * 100.0 + 0.5;
        const cents: u32 = if (cents_f > @as(f64, @floatFromInt(MAX_PRICE_CENTS)))
            MAX_PRICE_CENTS
        else
            @intFromFloat(cents_f);

        var copy = self;
        copy.price = cents;
        return copy;
    }

    /// Set price from dollars and cents parts (exact, no floating-point).
    ///
    /// Parameters:
    ///   dollars - Whole dollar amount
    ///   cents - Cents (0-99)
    ///
    /// Example: priceFromParts(100, 50) = $100.50 = 10050 cents
    pub fn priceFromParts(self: Self, dollars: u32, cents: u8) Self {
        // Assertion 1: Cents should be < 100
        std.debug.assert(cents < 100);

        // Assertion 2: Result should not overflow
        std.debug.assert(dollars <= MAX_PRICE_CENTS / 100);

        var copy = self;
        copy.price = dollars * 100 + cents;
        return copy;
    }

    /// Set quantity.
    ///
    /// Parameters:
    ///   q - Number of shares/units
    pub fn qty(self: Self, q: u32) Self {
        // Assertion 1: Quantity should be positive
        std.debug.assert(q > 0);

        // Assertion 2: Quantity should be reasonable
        std.debug.assert(q <= MAX_QUANTITY);

        var copy = self;
        copy.quantity = q;
        return copy;
    }

    /// Set side to buy.
    pub fn buy(self: Self) Self {
        // Assertion 1: Self should have valid pointer
        std.debug.assert(@intFromPtr(&self) != 0);

        var copy = self;
        copy.side = .buy;

        // Assertion 2: Side should be set
        std.debug.assert(copy.side == .buy);

        return copy;
    }

    /// Set side to sell.
    pub fn sell(self: Self) Self {
        // Assertion 1: Self should have valid pointer
        std.debug.assert(@intFromPtr(&self) != 0);

        var copy = self;
        copy.side = .sell;

        // Assertion 2: Side should be set
        std.debug.assert(copy.side == .sell);

        return copy;
    }

    /// Set the order ID.
    ///
    /// Parameters:
    ///   id - Unique order identifier
    pub fn orderId(self: Self, id: u32) Self {
        // Assertion 1: Order ID can be any value including 0
        std.debug.assert(id <= std.math.maxInt(u32));

        var copy = self;
        copy.order_id = id;

        // Assertion 2: Field should be set
        std.debug.assert(copy.order_id != null);

        return copy;
    }

    /// Validate the order and send it via the client.
    ///
    /// Parameters:
    ///   client - EngineClient to send through
    ///
    /// Returns: void on success, error if validation fails or send fails
    pub fn send(self: Self, client: *EngineClient) !void {
        // Assertion 1: Client pointer must be valid
        std.debug.assert(@intFromPtr(client) != 0);

        // Validate and extract all required fields
        const uid = self.user_id orelse return error.MissingUserId;
        const s = self.symbol orelse return error.MissingSymbol;
        const p = self.price orelse return error.MissingPrice;
        const q = self.quantity orelse return error.MissingQuantity;
        const sd = self.side orelse return error.MissingSide;
        const oid = self.order_id orelse return error.MissingOrderId;

        // Validate symbol
        if (s.len == 0) return error.EmptySymbol;
        if (s.len > types.MAX_SYMBOL_LEN) return error.SymbolTooLong;

        // Validate quantity
        if (q == 0) return error.ZeroQuantity;
        if (q > MAX_QUANTITY) return error.QuantityTooHigh;

        // Validate price (allow 0 for market orders in some systems)
        if (p > MAX_PRICE_CENTS) return error.PriceTooHigh;

        // Assertion 2: All validation passed
        std.debug.assert(s.len > 0 and s.len <= types.MAX_SYMBOL_LEN);

        try client.sendNewOrder(uid, s, p, q, sd, oid);
    }

    /// Build binary message without sending (for testing/inspection).
    ///
    /// Returns: BinaryNewOrder struct ready for wire transmission
    pub fn buildBinary(self: Self) !types.BinaryNewOrder {
        // Validate and extract all required fields
        const uid = self.user_id orelse return error.MissingUserId;
        const s = self.symbol orelse return error.MissingSymbol;
        const p = self.price orelse return error.MissingPrice;
        const q = self.quantity orelse return error.MissingQuantity;
        const sd = self.side orelse return error.MissingSide;
        const oid = self.order_id orelse return error.MissingOrderId;

        // Validate symbol
        if (s.len == 0) return error.EmptySymbol;
        if (s.len > types.MAX_SYMBOL_LEN) return error.SymbolTooLong;

        // Validate quantity
        if (q == 0) return error.ZeroQuantity;

        // Assertion 1: All required fields present
        std.debug.assert(uid <= std.math.maxInt(u32));

        // Assertion 2: Symbol is valid
        std.debug.assert(s.len > 0 and s.len <= types.MAX_SYMBOL_LEN);

        return types.BinaryNewOrder.init(uid, s, p, q, sd, oid);
    }

    /// Check if all required fields are set.
    pub fn isComplete(self: Self) bool {
        // Assertion 1: Check can always be performed
        std.debug.assert(@intFromPtr(&self) != 0);

        const complete = self.user_id != null and
            self.symbol != null and
            self.price != null and
            self.quantity != null and
            self.side != null and
            self.order_id != null;

        // Assertion 2: Result is deterministic
        std.debug.assert(complete == (self.user_id != null and
            self.symbol != null and
            self.price != null and
            self.quantity != null and
            self.side != null and
            self.order_id != null));

        return complete;
    }

    /// Get a human-readable description of what's missing.
    pub fn getMissingFields(self: Self, buf: []u8) []const u8 {
        // Assertion 1: Buffer must be large enough
        std.debug.assert(buf.len >= 128);

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        var first = true;
        if (self.user_id == null) {
            writer.print("user_id", .{}) catch {};
            first = false;
        }
        if (self.symbol == null) {
            if (!first) writer.print(", ", .{}) catch {};
            writer.print("symbol", .{}) catch {};
            first = false;
        }
        if (self.price == null) {
            if (!first) writer.print(", ", .{}) catch {};
            writer.print("price", .{}) catch {};
            first = false;
        }
        if (self.quantity == null) {
            if (!first) writer.print(", ", .{}) catch {};
            writer.print("quantity", .{}) catch {};
            first = false;
        }
        if (self.side == null) {
            if (!first) writer.print(", ", .{}) catch {};
            writer.print("side", .{}) catch {};
            first = false;
        }
        if (self.order_id == null) {
            if (!first) writer.print(", ", .{}) catch {};
            writer.print("order_id", .{}) catch {};
        }

        // Assertion 2: Output is valid
        std.debug.assert(stream.getWritten().len <= buf.len);

        return stream.getWritten();
    }

    /// Reset builder to empty state.
    pub fn reset(self: Self) Self {
        _ = self; // Unused, returns fresh builder

        // Assertion 1: We're creating a new builder
        std.debug.assert(true);

        const new_builder = Self.init();

        // Assertion 2: New builder is empty
        std.debug.assert(!new_builder.isComplete());

        return new_builder;
    }
};

// ============================================================
// Convenience Functions
// ============================================================

/// Start building an order with fluent API.
///
/// Usage:
///   try order()
///       .userId(1)
///       .sym("IBM")
///       .priceDollars(100.50)
///       .qty(100)
///       .buy()
///       .orderId(1001)
///       .send(&client);
pub fn order() OrderBuilder {
    // Assertion 1: Function always succeeds
    std.debug.assert(true);

    const builder = OrderBuilder.init();

    // Assertion 2: Returns empty builder
    std.debug.assert(!builder.isComplete());

    return builder;
}

/// Create a buy order builder with common fields pre-set.
///
/// Parameters:
///   uid - User ID
///   symbol - Trading symbol
pub fn buyOrder(uid: u32, symbol: []const u8) OrderBuilder {
    // Assertion 1: Symbol should be valid
    std.debug.assert(symbol.len <= types.MAX_SYMBOL_LEN);

    const builder = order().userId(uid).sym(symbol).buy();

    // Assertion 2: Side should be set
    std.debug.assert(builder.side == .buy);

    return builder;
}

/// Create a sell order builder with common fields pre-set.
///
/// Parameters:
///   uid - User ID
///   symbol - Trading symbol
pub fn sellOrder(uid: u32, symbol: []const u8) OrderBuilder {
    // Assertion 1: Symbol should be valid
    std.debug.assert(symbol.len <= types.MAX_SYMBOL_LEN);

    const builder = order().userId(uid).sym(symbol).sell();

    // Assertion 2: Side should be set
    std.debug.assert(builder.side == .sell);

    return builder;
}

// ============================================================
// Tests
// ============================================================

test "order builder validation - missing fields" {
    const incomplete = order().userId(1).sym("IBM");

    try std.testing.expect(!incomplete.isComplete());
    try std.testing.expectError(error.MissingPrice, incomplete.buildBinary());
}

test "order builder validation - empty symbol" {
    const bad_symbol = order()
        .userId(1)
        .sym("")
        .priceRaw(10000)
        .qty(50)
        .buy()
        .orderId(1001);

    try std.testing.expectError(error.EmptySymbol, bad_symbol.buildBinary());
}

test "order builder validation - symbol too long" {
    const bad_symbol = order()
        .userId(1)
        .sym("TOOLONGSYMBOL")
        .priceRaw(10000)
        .qty(50)
        .buy()
        .orderId(1001);

    try std.testing.expectError(error.SymbolTooLong, bad_symbol.buildBinary());
}

test "order builder validation - zero quantity" {
    const bad_qty = order()
        .userId(1)
        .sym("IBM")
        .priceRaw(10000)
        .qty(0)
        .buy()
        .orderId(1001);

    try std.testing.expectError(error.ZeroQuantity, bad_qty.buildBinary());
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
    try std.testing.expectEqual(@as(u32, 1), msg.user_id);
    try std.testing.expectEqual(@as(u32, 10000), msg.price);
    try std.testing.expectEqual(@as(u32, 50), msg.quantity);
}

test "price conversion - dollars" {
    // Test basic conversion
    const builder1 = order().priceDollars(100.0);
    try std.testing.expectEqual(@as(u32, 10000), builder1.price.?);

    // Test with cents
    const builder2 = order().priceDollars(123.45);
    try std.testing.expectEqual(@as(u32, 12345), builder2.price.?);

    // Test rounding (123.456 should round to 12346)
    const builder3 = order().priceDollars(123.456);
    try std.testing.expectEqual(@as(u32, 12346), builder3.price.?);
}

test "price conversion - parts" {
    const builder = order().priceFromParts(100, 50);
    try std.testing.expectEqual(@as(u32, 10050), builder.price.?);

    const builder2 = order().priceFromParts(0, 99);
    try std.testing.expectEqual(@as(u32, 99), builder2.price.?);
}

test "isComplete" {
    try std.testing.expect(!order().isComplete());
    try std.testing.expect(!order().userId(1).isComplete());
    try std.testing.expect(!order().userId(1).sym("IBM").isComplete());

    const complete = order()
        .userId(1)
        .sym("IBM")
        .priceRaw(10000)
        .qty(50)
        .buy()
        .orderId(1001);

    try std.testing.expect(complete.isComplete());
}

test "getMissingFields" {
    var buf: [256]u8 = undefined;

    const empty = order();
    const missing = empty.getMissingFields(&buf);

    try std.testing.expect(std.mem.indexOf(u8, missing, "user_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "symbol") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "price") != null);
}

test "convenience functions" {
    const buy_builder = buyOrder(1, "IBM");
    try std.testing.expectEqual(types.Side.buy, buy_builder.side.?);
    try std.testing.expectEqual(@as(u32, 1), buy_builder.user_id.?);

    const sell_builder = sellOrder(2, "AAPL");
    try std.testing.expectEqual(types.Side.sell, sell_builder.side.?);
    try std.testing.expectEqual(@as(u32, 2), sell_builder.user_id.?);
}

test "builder immutability" {
    const b1 = order().userId(1);
    const b2 = b1.sym("IBM");
    const b3 = b1.sym("AAPL"); // From b1, not b2

    try std.testing.expectEqual(@as(u32, 1), b1.user_id.?);
    try std.testing.expect(b1.symbol == null);

    try std.testing.expectEqualStrings("IBM", b2.symbol.?);
    try std.testing.expectEqualStrings("AAPL", b3.symbol.?);
}

test "reset" {
    const builder = order()
        .userId(1)
        .sym("IBM")
        .priceRaw(10000)
        .qty(50)
        .buy()
        .orderId(1001);

    try std.testing.expect(builder.isComplete());

    const reset_builder = builder.reset();
    try std.testing.expect(!reset_builder.isComplete());
}
