//! Basic Scenarios (1, 2, 3)
//!
//! Interactive scenarios for manual testing and validation.
//! These are stable and rarely need modification.

const std = @import("std");
const config = @import("config.zig");
const helpers = @import("helpers.zig");
const drain = @import("drain.zig");

const EngineClient = @import("../client/engine_client.zig").EngineClient;
const timestamp = @import("../util/timestamp.zig");

// ============================================================
// Scenario 1: Simple Orders
// ============================================================

pub fn runScenario1(client: *EngineClient, stderr: std.fs.File) !void {
    try helpers.print(stderr, "=== Scenario 1: Simple Orders ===\n\n", .{});
    const start_time = timestamp.now();

    // Order 1: Buy
    try helpers.print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try drain.recvAndPrint(client, stderr, 5);

    // Order 2: Sell (different price, won't match)
    try helpers.print(stderr, "[SEND] N, IBM, 1, 2, 105, 50, S (New Order: SELL 50 IBM @ 105)\n", .{});
    try client.sendNewOrder(1, "IBM", 105, 50, .sell, 2);
    try drain.recvAndPrint(client, stderr, 5);

    // Flush - need extra patience for cancel acks and final TOB
    try helpers.print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try drain.recvAndPrintPatient(client, stderr, 20);

    const elapsed = timestamp.now() - start_time;
    try helpers.print(stderr, "\n", .{});
    try helpers.printTime(stderr, "Total time: ", elapsed);
}

// ============================================================
// Scenario 2: Matching Trade
// ============================================================

pub fn runScenario2(client: *EngineClient, stderr: std.fs.File) !void {
    try helpers.print(stderr, "=== Scenario 2: Matching Trade ===\n\n", .{});
    const start_time = timestamp.now();

    // Order 1: Buy
    try helpers.print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try drain.recvAndPrint(client, stderr, 5);

    // Order 2: Sell at same price - should match!
    try helpers.print(stderr, "[SEND] N, IBM, 1, 2, 100, 50, S (New Order: SELL 50 IBM @ 100 - SHOULD MATCH)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .sell, 2);
    try drain.recvAndPrint(client, stderr, 5);

    // Flush - need extra patience for final TOB
    try helpers.print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try drain.recvAndPrintPatient(client, stderr, 20);

    const elapsed = timestamp.now() - start_time;
    try helpers.print(stderr, "\n", .{});
    try helpers.printTime(stderr, "Total time: ", elapsed);
}

// ============================================================
// Scenario 3: Cancel Order
// ============================================================

pub fn runScenario3(client: *EngineClient, stderr: std.fs.File) !void {
    try helpers.print(stderr, "=== Scenario 3: Cancel Order ===\n\n", .{});
    const start_time = timestamp.now();

    // Order 1: Buy
    try helpers.print(stderr, "[SEND] N, IBM, 1, 1, 100, 50, B (New Order: BUY 50 IBM @ 100)\n", .{});
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);
    try drain.recvAndPrint(client, stderr, 5);

    // Cancel order 1
    try helpers.print(stderr, "[SEND] C, IBM, 1, 1 (Cancel order 1)\n", .{});
    try client.sendCancel(1, "IBM", 1);
    try drain.recvAndPrint(client, stderr, 5);

    // Flush - need extra patience for final TOB
    try helpers.print(stderr, "\n[SEND] F (Flush - cancel all orders)\n", .{});
    try client.sendFlush();
    try drain.recvAndPrintPatient(client, stderr, 20);

    const elapsed = timestamp.now() - start_time;
    try helpers.print(stderr, "\n", .{});
    try helpers.printTime(stderr, "Total time: ", elapsed);
}
