//! Simple Order Example
//!
//! Demonstrates basic order submission to the matching engine.

const std = @import("std");
const me = @import("me_client");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Connect using TCP with binary protocol (most common setup)
    try stdout.print("Connecting to matching engine...\n", .{});

    var client = me.connectTcpBinary("127.0.0.1", 12345) catch |err| {
        try stdout.print("Connection failed: {s}\n", .{@errorName(err)});
        try stdout.print("Make sure the matching engine is running.\n", .{});
        return err;
    };
    defer client.deinit();

    try stdout.print("Connected!\n\n", .{});

    // Method 1: Direct API
    try stdout.print("Sending buy order via direct API...\n", .{});
    try client.sendNewOrder(
        1, // user_id
        "IBM", // symbol
        10000, // price ($100.00 in cents)
        50, // quantity
        .buy, // side
        1001, // order_id
    );

    // Wait for acknowledgment
    const ack = try client.recv();
    try stdout.print("Received: {s} order_id={d}\n\n", .{
        @tagName(ack.msg_type),
        ack.order_id,
    });

    // Method 2: Fluent builder API
    try stdout.print("Sending sell order via builder API...\n", .{});
    try me.order()
        .userId(2)
        .sym("IBM")
        .priceDollars(100.50) // Converts to cents automatically
        .qty(25)
        .sell()
        .orderId(2001)
        .send(&client);

    const ack2 = try client.recv();
    try stdout.print("Received: {s} order_id={d}\n\n", .{
        @tagName(ack2.msg_type),
        ack2.order_id,
    });

    // Send a few more orders to potentially get trades
    try stdout.print("Sending matching order to trigger trade...\n", .{});
    try client.sendNewOrder(3, "IBM", 10050, 25, .buy, 3001);

    // Receive responses (might be ack + trade + top-of-book)
    for (0..5) |_| {
        const msg = client.recv() catch break;
        switch (msg.msg_type) {
            .ack => try stdout.print("ACK: order_id={d}\n", .{msg.order_id}),
            .trade => try stdout.print("TRADE: {d} shares @ ${d}.{d:0>2}\n", .{
                msg.quantity,
                msg.price / 100,
                msg.price % 100,
            }),
            .top_of_book => {
                if (msg.price == 0) {
                    try stdout.print("TOB: {s} side EMPTY\n", .{msg.getSymbol()});
                } else {
                    try stdout.print("TOB: {s} {c} {d}@{d}\n", .{
                        msg.getSymbol(),
                        if (msg.side) |s| s.toChar() else '-',
                        msg.quantity,
                        msg.price,
                    });
                }
            },
            .cancel_ack => try stdout.print("CANCEL: order_id={d}\n", .{msg.order_id}),
        }
    }

    try stdout.print("\nDone!\n", .{});
}
