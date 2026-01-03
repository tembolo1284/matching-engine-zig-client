//! Scenario Types
//!
//! Data structures used across all scenarios.

const std = @import("std");
const helpers = @import("helpers.zig");

// ============================================================
// Response Statistics
// ============================================================

pub const ResponseStats = struct {
    acks: u64 = 0,
    cancel_acks: u64 = 0,
    trades: u64 = 0,
    top_of_book: u64 = 0,
    rejects: u64 = 0,
    parse_errors: u64 = 0,
    packets_received: u64 = 0,

    const Self = @This();

    pub fn total(self: Self) u64 {
        return self.acks + self.cancel_acks + self.trades + self.top_of_book + self.rejects;
    }

    pub fn add(self: *Self, other: Self) void {
        self.acks += other.acks;
        self.cancel_acks += other.cancel_acks;
        self.trades += other.trades;
        self.top_of_book += other.top_of_book;
        self.rejects += other.rejects;
        self.parse_errors += other.parse_errors;
        self.packets_received += other.packets_received;
    }

    pub fn reset(self: *Self) void {
        self.* = Self{};
    }

    pub fn printStats(self: Self, stderr: std.fs.File) !void {
        try helpers.print(stderr, "\n=== Server Response Summary ===\n", .{});
        try helpers.print(stderr, "ACKs:            {d}\n", .{self.acks});
        if (self.cancel_acks > 0) try helpers.print(stderr, "Cancel ACKs:     {d}\n", .{self.cancel_acks});
        if (self.trades > 0) try helpers.print(stderr, "Trades:          {d}\n", .{self.trades});
        try helpers.print(stderr, "Top of Book:     {d}\n", .{self.top_of_book});
        if (self.rejects > 0) try helpers.print(stderr, "Rejects:         {d}\n", .{self.rejects});
        if (self.parse_errors > 0) try helpers.print(stderr, "Parse errors:    {d}\n", .{self.parse_errors});
        try helpers.print(stderr, "Total messages:  {d}\n", .{self.total()});
    }

    pub fn printValidation(self: Self, expected_acks: u64, expected_trades: u64, stderr: std.fs.File) !void {
        try self.printStats(stderr);
        try helpers.print(stderr, "\n=== Validation ===\n", .{});

        if (self.acks >= expected_acks) {
            try helpers.print(stderr, "ACKs:            {d}/{d} ✓ PASS\n", .{ self.acks, expected_acks });
        } else {
            const pct = if (expected_acks > 0) (self.acks * 100) / expected_acks else 0;
            try helpers.print(stderr, "ACKs:            {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                self.acks, expected_acks, pct, expected_acks - self.acks,
            });
        }

        if (expected_trades > 0) {
            if (self.trades >= expected_trades) {
                try helpers.print(stderr, "Trades:          {d}/{d} ✓ PASS\n", .{ self.trades, expected_trades });
            } else {
                const pct = if (expected_trades > 0) (self.trades * 100) / expected_trades else 0;
                try helpers.print(stderr, "Trades:          {d}/{d} ({d}%%) ✗ MISSING {d}\n", .{
                    self.trades, expected_trades, pct, expected_trades - self.trades,
                });
            }
        }

        const passed = (self.acks >= expected_acks) and (self.trades >= expected_trades or expected_trades == 0);
        if (passed and self.rejects == 0) {
            try helpers.print(stderr, "\n*** TEST PASSED ***\n", .{});
        } else if (self.rejects > 0) {
            try helpers.print(stderr, "\n*** TEST FAILED - {d} REJECTS ***\n", .{self.rejects});
        } else {
            try helpers.print(stderr, "\n*** TEST FAILED - MISSING RESPONSES ***\n", .{});
        }
    }
};
