//! Scenario Helpers
//!
//! Utility functions for printing and message parsing.

const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");

// Import protocol modules (these paths will need adjustment for your project)
const binary = @import("../protocol/binary.zig");
const csv = @import("../protocol/csv.zig");
const proto_types = @import("../protocol/types.zig");
const Protocol = @import("../client/engine_client.zig").Protocol;

// ============================================================
// Print Utilities
// ============================================================

pub fn print(file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return error.FormatError;
    try file.writeAll(msg);
}

pub fn printTime(file: std.fs.File, prefix: []const u8, nanos: u64) !void {
    if (nanos >= config.NS_PER_SEC * 60) {
        const mins = nanos / (config.NS_PER_SEC * 60);
        const secs = (nanos % (config.NS_PER_SEC * 60)) / config.NS_PER_SEC;
        try print(file, "{s}{d}m {d}s\n", .{ prefix, mins, secs });
    } else if (nanos >= config.NS_PER_SEC) {
        const secs = nanos / config.NS_PER_SEC;
        const ms = (nanos % config.NS_PER_SEC) / config.NS_PER_MS;
        try print(file, "{s}{d}.{d:0>3} sec\n", .{ prefix, secs, ms });
    } else {
        const ms = nanos / config.NS_PER_MS;
        try print(file, "{s}{d} ms\n", .{ prefix, ms });
    }
}

pub fn printThroughput(file: std.fs.File, prefix: []const u8, per_sec: u64) !void {
    if (per_sec >= 1_000_000) {
        const millions = per_sec / 1_000_000;
        const thousands = (per_sec % 1_000_000) / 1_000;
        try print(file, "{s}{d}.{d:0>1}M/sec\n", .{ prefix, millions, thousands / 100 });
    } else if (per_sec >= 1_000) {
        const thousands = per_sec / 1_000;
        const hundreds = (per_sec % 1_000) / 100;
        try print(file, "{s}{d}.{d}K/sec\n", .{ prefix, thousands, hundreds });
    } else {
        try print(file, "{s}{d}/sec\n", .{ prefix, per_sec });
    }
}

// ============================================================
// Message Parsing
// ============================================================

pub fn parseMessage(raw_data: []const u8, proto: Protocol) ?proto_types.OutputMessage {
    if (proto == .binary) {
        return binary.decodeOutput(raw_data) catch null;
    } else {
        return csv.parseOutput(raw_data) catch null;
    }
}

pub fn countMessage(stats: *types.ResponseStats, msg: proto_types.OutputMessage) void {
    switch (msg.msg_type) {
        .ack => stats.acks += 1,
        .cancel_ack => stats.cancel_acks += 1,
        .trade => stats.trades += 1,
        .top_of_book => stats.top_of_book += 1,
        .reject => stats.rejects += 1,
    }
}

// ============================================================
// Response Printing (for interactive scenarios)
// ============================================================

pub fn printRawResponse(raw_data: []const u8, proto: Protocol, stderr: std.fs.File) !void {
    if (proto == .binary) {
        if (binary.isBinaryProtocol(raw_data)) {
            const msg = binary.decodeOutput(raw_data) catch |err| {
                try print(stderr, "[Parse error: {s}]\n", .{@errorName(err)});
                return;
            };
            try printResponse(msg, stderr);
        } else {
            try print(stderr, "[RECV] {s}\n", .{raw_data});
        }
    } else {
        const msg = csv.parseOutput(raw_data) catch {
            try print(stderr, "[RECV] {s}", .{raw_data});
            if (raw_data.len > 0 and raw_data[raw_data.len - 1] != '\n') {
                try stderr.writeAll("\n");
            }
            return;
        };
        try printResponse(msg, stderr);
    }
}

pub fn printResponse(msg: proto_types.OutputMessage, stderr: std.fs.File) !void {
    const symbol = msg.symbol[0..msg.symbol_len];

    switch (msg.msg_type) {
        .ack => try print(stderr, "[RECV] A, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id }),
        .cancel_ack => try print(stderr, "[RECV] C, {s}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id }),
        .trade => try print(stderr, "[RECV] T, {s}, {d}, {d}, {d}, {d}, {d}.{d:0>2}, {d}\n", .{
            symbol, msg.buy_user_id, msg.buy_order_id, msg.sell_user_id, msg.sell_order_id,
            msg.price / 100, msg.price % 100, msg.quantity,
        }),
        .reject => try print(stderr, "[RECV] R, {s}, {d}, {d}, {d}\n", .{ symbol, msg.user_id, msg.order_id, msg.reject_reason }),
        .top_of_book => {
            const side_char: u8 = if (msg.side) |s| @intFromEnum(s) else '-';
            if (msg.price == 0 and msg.quantity == 0) {
                try print(stderr, "[RECV] B, {s}, {c}, -, -\n", .{ symbol, side_char });
            } else {
                try print(stderr, "[RECV] B, {s}, {c}, {d}, {d}\n", .{ symbol, side_char, msg.price, msg.quantity });
            }
        },
    }
}
