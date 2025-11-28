//! High-resolution timestamp utilities.
//!
//! Provides cross-platform access to high-resolution timestamps for
//! latency measurement and benchmarking.

const std = @import("std");
const builtin = @import("builtin");

/// Timestamp value in nanoseconds
pub const Timestamp = u64;

/// Get current timestamp in nanoseconds.
/// Uses the most efficient method available per platform.
pub fn now() Timestamp {
    const ts = std.time.Instant.now() catch return 0;
    return @intCast(ts.timestamp);
}

/// Get elapsed time since a previous timestamp in nanoseconds.
pub fn elapsed(start: Timestamp) Timestamp {
    const current = now();
    return if (current > start) current - start else 0;
}

/// Get elapsed time in microseconds.
pub fn elapsedUs(start: Timestamp) u64 {
    return elapsed(start) / 1000;
}

/// Get elapsed time in milliseconds.
pub fn elapsedMs(start: Timestamp) u64 {
    return elapsed(start) / 1_000_000;
}

/// Simple latency tracker for benchmarking.
/// Tracks min, max, sum, and count for calculating statistics.
pub const LatencyTracker = struct {
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    sum: u64 = 0,
    count: u64 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Record a latency sample (in nanoseconds)
    pub fn record(self: *Self, latency_ns: u64) void {
        if (latency_ns < self.min) self.min = latency_ns;
        if (latency_ns > self.max) self.max = latency_ns;
        self.sum += latency_ns;
        self.count += 1;
    }

    /// Record latency since a start timestamp
    pub fn recordSince(self: *Self, start: Timestamp) void {
        self.record(elapsed(start));
    }

    /// Get average latency in nanoseconds
    pub fn avgNs(self: *const Self) u64 {
        if (self.count == 0) return 0;
        return self.sum / self.count;
    }

    /// Get average latency in microseconds
    pub fn avgUs(self: *const Self) u64 {
        return self.avgNs() / 1000;
    }

    /// Get minimum latency in nanoseconds
    pub fn minNs(self: *const Self) u64 {
        if (self.count == 0) return 0;
        return self.min;
    }

    /// Get maximum latency in nanoseconds
    pub fn maxNs(self: *const Self) u64 {
        return self.max;
    }

    /// Reset all statistics
    pub fn reset(self: *Self) void {
        self.* = Self.init();
    }

    /// Format statistics as string
    pub fn format(self: *const Self, buf: []u8) []const u8 {
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.print("count={d} min={d}ns avg={d}ns max={d}ns", .{
            self.count,
            self.minNs(),
            self.avgNs(),
            self.maxNs(),
        }) catch {};

        return stream.getWritten();
    }
};

/// RAII-style timer for measuring code block duration.
/// Usage:
///   var timer = ScopedTimer.start(&tracker);
///   defer timer.stop();
///   // ... code to measure ...
pub const ScopedTimer = struct {
    tracker: *LatencyTracker,
    start_time: Timestamp,

    pub fn start(tracker: *LatencyTracker) ScopedTimer {
        return .{
            .tracker = tracker,
            .start_time = now(),
        };
    }

    pub fn stop(self: *ScopedTimer) void {
        self.tracker.recordSince(self.start_time);
    }
};

// ============================================================
// Tests
// ============================================================

test "timestamp basic" {
    const t1 = now();
    std.time.sleep(1_000_000); // 1ms
    const t2 = now();

    try std.testing.expect(t2 > t1);
}

test "elapsed calculation" {
    const start = now();
    std.time.sleep(1_000_000); // 1ms
    const ns = elapsed(start);

    // Should be at least 1ms
    try std.testing.expect(ns >= 1_000_000);
    // But not too much more (allowing for scheduler variance)
    try std.testing.expect(ns < 100_000_000); // Less than 100ms
}

test "latency tracker" {
    var tracker = LatencyTracker.init();

    tracker.record(100);
    tracker.record(200);
    tracker.record(300);

    try std.testing.expectEqual(@as(u64, 100), tracker.minNs());
    try std.testing.expectEqual(@as(u64, 300), tracker.maxNs());
    try std.testing.expectEqual(@as(u64, 200), tracker.avgNs());
    try std.testing.expectEqual(@as(u64, 3), tracker.count);
}

test "scoped timer" {
    var tracker = LatencyTracker.init();

    {
        var timer = ScopedTimer.start(&tracker);
        std.time.sleep(1_000_000); // 1ms
        timer.stop();
    }

    try std.testing.expectEqual(@as(u64, 1), tracker.count);
    try std.testing.expect(tracker.minNs() >= 1_000_000);
}
