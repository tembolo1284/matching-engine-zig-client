//! Multicast Market Data Subscriber Example
//!
//! Demonstrates subscribing to multicast market data feed from the matching engine.
//! This is how real exchanges distribute market data - one broadcast reaches all subscribers.

const std = @import("std");
const me = @import("me_client");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    const group = "239.255.0.1";
    const port: u16 = 5000;

    try stdout.print("Joining multicast group {s}:{d}...\n", .{ group, port });

    var subscriber = me.MulticastSubscriber.join(group, port) catch |err| {
        try stdout.print("Failed to join multicast group: {s}\n", .{@errorName(err)});
        try stdout.print("\nTroubleshooting:\n", .{});
        try stdout.print("  - Is the matching engine running with --multicast?\n", .{});
        try stdout.print("  - Does your network support multicast?\n", .{});
        try stdout.print("  - Try: ./matching_engine --tcp --multicast 239.255.0.1:5000\n", .{});
        return err;
    };
    defer subscriber.close();

    try stdout.print("Subscribed! Waiting for market data...\n", .{});
    try stdout.print("(Press Ctrl+C to stop)\n\n", .{});

    // Track statistics
    var trade_count: u64 = 0;
    var tob_count: u64 = 0;
    var last_print = std.time.milliTimestamp();

    while (true) {
        const msg = subscriber.recvMessage() catch |err| {
            try stdout.print("Receive error: {s}\n", .{@errorName(err)});
            continue;
        };

        // Format and print message
        switch (msg.msg_type) {
            .ack => {
                try stdout.print("[ACK] {s} user={d} order={d}\n", .{
                    msg.getSymbol(),
                    msg.user_id,
                    msg.order_id,
                });
            },
            .cancel_ack => {
                try stdout.print("[CXL] {s} user={d} order={d}\n", .{
                    msg.getSymbol(),
                    msg.user_id,
                    msg.order_id,
                });
            },
            .trade => {
                trade_count += 1;
                try stdout.print("[TRD] {s} {d}@${d}.{d:0>2} (buy={d}/{d} sell={d}/{d})\n", .{
                    msg.getSymbol(),
                    msg.quantity,
                    msg.price / 100,
                    msg.price % 100,
                    msg.buy_user_id,
                    msg.buy_order_id,
                    msg.sell_user_id,
                    msg.sell_order_id,
                });
            },
            .top_of_book => {
                tob_count += 1;
                const side_char = if (msg.side) |s| s.toChar() else '-';
                if (msg.price == 0 and msg.quantity == 0) {
                    try stdout.print("[TOB] {s} {c} EMPTY\n", .{ msg.getSymbol(), side_char });
                } else {
                    try stdout.print("[TOB] {s} {c} {d}@${d}.{d:0>2}\n", .{
                        msg.getSymbol(),
                        side_char,
                        msg.quantity,
                        msg.price / 100,
                        msg.price % 100,
                    });
                }
            },
        }

        // Print stats every 5 seconds
        const now = std.time.milliTimestamp();
        if (now - last_print > 5000) {
            const stats = subscriber.getStats();
            try stdout.print("\n--- Stats: {d} packets, {d} trades, {d} TOB updates, {d} errors ---\n\n", .{
                stats.packets,
                trade_count,
                tob_count,
                stats.errors,
            });
            last_print = now;
        }
    }
}
