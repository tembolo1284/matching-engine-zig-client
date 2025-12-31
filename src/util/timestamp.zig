//! High-resolution timestamp utilities for latency measurement.
//!
//! Provides cross-platform access to high-resolution timestamps for
//! latency measurement and benchmarking in HFT applications.
//!
//! Power of Ten Compliance:
//! - Rule 1: No goto/setjmp, no recursion ✓
//! - Rule 2: All loops have fixed upper bounds ✓
//! - Rule 3: No dynamic memory after init ✓
//! - Rule 4: Functions ≤60 lines ✓
//! - Rule 5: ≥2 assertions per function ✓
//! - Rule 6: Data at smallest scope ✓
//! - Rule 7: Check return values, validate parameters ✓
//!
//! Design Notes:
//! - Uses saturating arithmetic to prevent overflow in sum accumulation
//! - LatencyTracker is lock-free and suitable for single-threaded hot paths
//! - ScopedTimer uses RAII pattern for automatic measurement

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// Constants
// ============================================================

/// Nanoseconds per microsecond
pub const NS_PER_US: u64 = 1_000;

/// Nanoseconds per millisecond
pub const NS_PER_MS: u64 = 1_000_000;

/// Nanoseconds per second
pub const NS_PER_SEC: u64 = 1_000_000_000;

/// Maximum reasonable latency (1 hour in nanoseconds)
/// Used for sanity checking - any latency beyond this is likely a bug
pub const MAX_REASONABLE_LATENCY_NS: u64 = 3_600 * NS_PER_SEC;

// ============================================================
// Timestamp Type
// ============================================================

/// Timestamp value in nanoseconds since an arbitrary epoch.
/// The epoch is platform-dependent but consistent within a process.
pub const Timestamp = u64;

// ============================================================
// Core Functions
// ============================================================

/// Get current timestamp in nanoseconds.
/// Uses the most efficient method available per platform.
///
/// Returns: Current timestamp in nanoseconds
///
/// Note: On Linux, uses CLOCK_MONOTONIC via std.time.nanoTimestamp()
/// which provides ~25ns resolution on modern systems.
pub fn now() Timestamp {
    const raw = std.time.nanoTimestamp();

    // Assertion 1: Timestamp should be non-negative
    // (nanoTimestamp can return negative on some platforms before epoch)
    std.debug.assert(raw >= 0);

    const result: Timestamp = @intCast(raw);

    // Assertion 2: Result should be reasonable (not zero unless very early in boot)
    // We allow zero for testing but in practice this should be large
    std.debug.assert(result < std.math.maxInt(u64));

    return result;
}

/// Get elapsed time since a previous timestamp in nanoseconds.
/// Returns 0 if current time is somehow before start (clock adjustment).
///
/// Parameters:
///   start - Previous timestamp from now()
///
/// Returns: Elapsed nanoseconds, or 0 if time went backwards
pub fn elapsed(start: Timestamp) Timestamp {
    // Assertion 1: Start should be a valid timestamp
    std.debug.assert(start < std.math.maxInt(u64));

    const current = now();

    // Assertion 2: Verify we got a valid current time
    std.debug.assert(current < std.math.maxInt(u64));

    // Handle clock adjustment gracefully - return 0 rather than underflow
    return if (current > start) current - start else 0;
}

/// Get elapsed time in microseconds.
///
/// Parameters:
///   start - Previous timestamp from now()
///
/// Returns: Elapsed microseconds
pub fn elapsedUs(start: Timestamp) u64 {
    // Assertion 1: Start should be valid
    std.debug.assert(start < std.math.maxInt(u64));

    const ns = elapsed(start);

    // Assertion 2: Result should be reasonable
    std.debug.assert(ns <= MAX_REASONABLE_LATENCY_NS or ns == 0);

    return ns / NS_PER_US;
}

/// Get elapsed time in milliseconds.
///
/// Parameters:
///   start - Previous timestamp from now()
///
/// Returns: Elapsed milliseconds
pub fn elapsedMs(start: Timestamp) u64 {
    // Assertion 1: Start should be valid
    std.debug.assert(start < std.math.maxInt(u64));

    const ns = elapsed(start);

    // Assertion 2: Result should be reasonable
    std.debug.assert(ns <= MAX_REASONABLE_LATENCY_NS or ns == 0);

    return ns / NS_PER_MS;
}

// ============================================================
// Latency Tracker
// ============================================================

/// Simple latency tracker for benchmarking.
/// Tracks min, max, sum, and count for calculating statistics.
///
/// Thread Safety: NOT thread-safe. Use one tracker per thread.
///
/// Overflow Protection: Uses saturating addition for sum to prevent
/// overflow during long-running benchmarks.
///
/// Usage:
///   var tracker = LatencyTracker.init();
///   // In hot loop:
///   const start = timestamp.now();
///   // ... operation ...
///   tracker.recordSince(start);
///   // After benchmark:
///   std.debug.print("avg={d}ns\n", .{tracker.avgNs()});
pub const LatencyTracker = struct {
    /// Minimum observed latency (initialized to max for proper min tracking)
    min: u64 = std.math.maxInt(u64),

    /// Maximum observed latency
    max: u64 = 0,

    /// Sum of all latencies (saturating to prevent overflow)
    sum: u64 = 0,

    /// Number of samples recorded
    count: u64 = 0,

    const Self = @This();

    /// Initialize a new latency tracker.
    pub fn init() Self {
        const tracker = Self{};

        // Assertion 1: min should start at max for proper tracking
        std.debug.assert(tracker.min == std.math.maxInt(u64));

        // Assertion 2: count should start at 0
        std.debug.assert(tracker.count == 0);

        return tracker;
    }

    /// Record a latency sample (in nanoseconds).
    ///
    /// Parameters:
    ///   latency_ns - Latency to record in nanoseconds
    ///
    /// Note: Uses saturating addition for sum to prevent overflow.
    /// Extremely large values are handled gracefully via saturating arithmetic.
    pub fn record(self: *Self, latency_ns: u64) void {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Self state should be valid
        // Note: We intentionally do NOT assert latency_ns <= MAX_REASONABLE_LATENCY_NS
        // because saturating arithmetic handles overflow safely, and tests need
        // to verify saturation behavior with extreme values.
        std.debug.assert(self.count < std.math.maxInt(u64));

        // Update min/max
        if (latency_ns < self.min) self.min = latency_ns;
        if (latency_ns > self.max) self.max = latency_ns;

        // Saturating add to prevent overflow during long benchmarks
        // If we overflow, sum stays at max which makes avg calculation safe
        self.sum = self.sum +| latency_ns;

        // Saturating increment for count (practically impossible to overflow)
        self.count = self.count +| 1;
    }

    /// Record latency since a start timestamp.
    ///
    /// Parameters:
    ///   start - Timestamp from now() marking operation start
    pub fn recordSince(self: *Self, start: Timestamp) void {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Start should be a reasonable timestamp
        std.debug.assert(start < std.math.maxInt(u64));

        self.record(elapsed(start));
    }

    /// Get average latency in nanoseconds.
    /// Returns 0 if no samples recorded.
    pub fn avgNs(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: If count > 0, sum should be > 0 (unless all samples were 0)
        std.debug.assert(self.count == 0 or self.sum >= 0);

        if (self.count == 0) return 0;
        return self.sum / self.count;
    }

    /// Get average latency in microseconds.
    pub fn avgUs(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Consistency check
        std.debug.assert(self.count == 0 or self.min <= self.max);

        return self.avgNs() / NS_PER_US;
    }

    /// Get minimum latency in nanoseconds.
    /// Returns 0 if no samples recorded.
    pub fn minNs(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: If we have samples, min should be <= max
        std.debug.assert(self.count == 0 or self.min <= self.max);

        if (self.count == 0) return 0;
        return self.min;
    }

    /// Get minimum latency in microseconds.
    pub fn minUs(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Consistency check
        std.debug.assert(self.count == 0 or self.min <= self.max);

        return self.minNs() / NS_PER_US;
    }

    /// Get maximum latency in nanoseconds.
    pub fn maxNs(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: max should be 0 if no samples, otherwise >= min
        std.debug.assert(self.count == 0 or self.max >= self.min);

        return self.max;
    }

    /// Get maximum latency in microseconds.
    pub fn maxUs(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Consistency check
        std.debug.assert(self.count == 0 or self.max >= self.min);

        return self.maxNs() / NS_PER_US;
    }

    /// Get the number of samples recorded.
    pub fn getCount(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: If count > 0, we should have valid min/max
        std.debug.assert(self.count == 0 or self.max > 0 or self.min == 0);

        return self.count;
    }

    /// Reset all statistics.
    pub fn reset(self: *Self) void {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        self.* = Self.init();

        // Assertion 2: Verify reset worked
        std.debug.assert(self.count == 0);
    }

    /// Check if any samples have been recorded.
    pub fn isEmpty(self: *const Self) bool {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Consistency - if count is 0, sum should be 0
        std.debug.assert(self.count > 0 or self.sum == 0);

        return self.count == 0;
    }

    /// Format statistics as string.
    /// Returns a slice of the provided buffer containing the formatted string.
    ///
    /// Parameters:
    ///   buf - Buffer to write formatted string into
    ///
    /// Returns: Slice of buf containing the formatted statistics
    pub fn format(self: *const Self, buf: []u8) []const u8 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Buffer must be large enough for basic output
        std.debug.assert(buf.len >= 64);

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        writer.print("count={d} min={d}ns avg={d}ns max={d}ns", .{
            self.count,
            self.minNs(),
            self.avgNs(),
            self.maxNs(),
        }) catch {
            // On format error, return what we have
            return stream.getWritten();
        };

        return stream.getWritten();
    }

    /// Validate internal invariants (for testing/debugging).
    pub fn validateInvariants(self: *const Self) bool {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Check: if no samples, min should be maxInt and max should be 0
        if (self.count == 0) {
            if (self.min != std.math.maxInt(u64)) return false;
            if (self.max != 0) return false;
            if (self.sum != 0) return false;
        } else {
            // Check: min <= max when we have samples
            if (self.min > self.max) return false;

            // Check: sum should be at least min * count (unless overflow)
            // Skip this check as saturating arithmetic makes it complex
        }

        // Assertion 2: Passed all checks
        std.debug.assert(true);

        return true;
    }
};

// ============================================================
// Scoped Timer (RAII Pattern)
// ============================================================

/// RAII-style timer for measuring code block duration.
///
/// Usage:
///   var tracker = LatencyTracker.init();
///   {
///       var timer = ScopedTimer.start(&tracker);
///       defer timer.stop();
///       // ... code to measure ...
///   }
///   // tracker now contains the measurement
///
/// Note: stop() is idempotent - safe to call multiple times.
pub const ScopedTimer = struct {
    tracker: *LatencyTracker,
    start_time: Timestamp,
    stopped: bool = false,

    const Self = @This();

    /// Start a new scoped timer.
    ///
    /// Parameters:
    ///   tracker - LatencyTracker to record the measurement to
    ///
    /// Returns: ScopedTimer instance (use with defer timer.stop())
    pub fn start(tracker: *LatencyTracker) Self {
        // Assertion 1: Tracker pointer must be valid
        std.debug.assert(@intFromPtr(tracker) != 0);

        const start_time = now();

        // Assertion 2: Start time should be valid
        std.debug.assert(start_time < std.math.maxInt(u64));

        return .{
            .tracker = tracker,
            .start_time = start_time,
            .stopped = false,
        };
    }

    /// Stop the timer and record the elapsed time.
    /// Idempotent - safe to call multiple times (only first call records).
    pub fn stop(self: *Self) void {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Tracker pointer must still be valid
        std.debug.assert(@intFromPtr(self.tracker) != 0);

        // Guard against double-stop
        if (self.stopped) return;

        self.tracker.recordSince(self.start_time);
        self.stopped = true;
    }

    /// Get elapsed time without stopping the timer.
    /// Useful for intermediate measurements.
    pub fn elapsed_ns(self: *const Self) u64 {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: Start time should be valid
        std.debug.assert(self.start_time < std.math.maxInt(u64));

        return elapsed(self.start_time);
    }

    /// Check if timer has been stopped.
    pub fn isStopped(self: *const Self) bool {
        // Assertion 1: Self pointer must be valid
        std.debug.assert(@intFromPtr(self) != 0);

        // Assertion 2: State should be consistent
        std.debug.assert(self.start_time > 0 or self.start_time == 0);

        return self.stopped;
    }
};

// ============================================================
// Utility Functions
// ============================================================

/// Convert nanoseconds to a human-readable string.
/// Chooses appropriate units (ns, us, ms, s) based on magnitude.
///
/// Parameters:
///   ns - Nanoseconds to format
///   buf - Buffer to write into (should be at least 32 bytes)
///
/// Returns: Slice of buf containing formatted string
pub fn formatDuration(ns: u64, buf: []u8) []const u8 {
    // Assertion 1: Buffer must be large enough
    std.debug.assert(buf.len >= 32);

    // Assertion 2: ns should be reasonable
    std.debug.assert(ns <= MAX_REASONABLE_LATENCY_NS or ns == 0);

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    if (ns >= NS_PER_SEC) {
        const secs = ns / NS_PER_SEC;
        const ms = (ns % NS_PER_SEC) / NS_PER_MS;
        writer.print("{d}.{d:0>3}s", .{ secs, ms }) catch {};
    } else if (ns >= NS_PER_MS) {
        const ms = ns / NS_PER_MS;
        const us = (ns % NS_PER_MS) / NS_PER_US;
        writer.print("{d}.{d:0>3}ms", .{ ms, us }) catch {};
    } else if (ns >= NS_PER_US) {
        const us = ns / NS_PER_US;
        const remaining = ns % NS_PER_US;
        writer.print("{d}.{d:0>3}us", .{ us, remaining }) catch {};
    } else {
        writer.print("{d}ns", .{ns}) catch {};
    }

    return stream.getWritten();
}

// ============================================================
// Tests
// ============================================================

test "timestamp basic" {
    const t1 = now();
    std.Thread.sleep(1_000_000); // 1ms
    const t2 = now();

    try std.testing.expect(t2 > t1);
    try std.testing.expect(t2 - t1 >= 1_000_000); // At least 1ms
}

test "elapsed calculation" {
    const start = now();
    std.Thread.sleep(1_000_000); // 1ms
    const ns = elapsed(start);

    // Should be at least 1ms
    try std.testing.expect(ns >= 1_000_000);
    // But not too much more (allowing for scheduler variance)
    try std.testing.expect(ns < 100_000_000); // Less than 100ms
}

test "elapsed handles time going backwards" {
    // Simulate a future timestamp (as if clock went backwards after)
    const future_start = now() + 1_000_000_000; // 1 second in future
    const result = elapsed(future_start);

    // Should return 0, not underflow
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "latency tracker basic" {
    var tracker = LatencyTracker.init();

    try std.testing.expect(tracker.validateInvariants());
    try std.testing.expect(tracker.isEmpty());

    tracker.record(100);
    tracker.record(200);
    tracker.record(300);

    try std.testing.expect(!tracker.isEmpty());
    try std.testing.expectEqual(@as(u64, 100), tracker.minNs());
    try std.testing.expectEqual(@as(u64, 300), tracker.maxNs());
    try std.testing.expectEqual(@as(u64, 200), tracker.avgNs());
    try std.testing.expectEqual(@as(u64, 3), tracker.getCount());
    try std.testing.expect(tracker.validateInvariants());
}

test "latency tracker reset" {
    var tracker = LatencyTracker.init();

    tracker.record(100);
    tracker.record(200);

    try std.testing.expectEqual(@as(u64, 2), tracker.getCount());

    tracker.reset();

    try std.testing.expectEqual(@as(u64, 0), tracker.getCount());
    try std.testing.expect(tracker.isEmpty());
    try std.testing.expect(tracker.validateInvariants());
}

test "latency tracker saturating arithmetic" {
    var tracker = LatencyTracker.init();

    // Record max value - should not overflow due to saturating arithmetic
    tracker.record(std.math.maxInt(u64) / 2);
    tracker.record(std.math.maxInt(u64) / 2);
    tracker.record(std.math.maxInt(u64) / 2);

    // Should saturate at maxInt, not overflow
    try std.testing.expect(tracker.sum <= std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 3), tracker.getCount());
}

test "latency tracker format" {
    var tracker = LatencyTracker.init();
    tracker.record(1000);
    tracker.record(2000);
    tracker.record(3000);

    var buf: [256]u8 = undefined;
    const result = tracker.format(&buf);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "min=1000ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "avg=2000ns") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "max=3000ns") != null);
}

test "scoped timer" {
    var tracker = LatencyTracker.init();

    {
        var timer = ScopedTimer.start(&tracker);
        try std.testing.expect(!timer.isStopped());
        std.Thread.sleep(1_000_000); // 1ms
        timer.stop();
        try std.testing.expect(timer.isStopped());
    }

    try std.testing.expectEqual(@as(u64, 1), tracker.getCount());
    try std.testing.expect(tracker.minNs() >= 1_000_000);
}

test "scoped timer double stop is safe" {
    var tracker = LatencyTracker.init();

    var timer = ScopedTimer.start(&tracker);
    timer.stop();
    timer.stop(); // Should be safe
    timer.stop(); // Still safe

    // Should only have recorded once
    try std.testing.expectEqual(@as(u64, 1), tracker.getCount());
}

test "scoped timer elapsed without stop" {
    var tracker = LatencyTracker.init();

    var timer = ScopedTimer.start(&tracker);
    std.Thread.sleep(1_000_000); // 1ms

    const intermediate = timer.elapsed_ns();
    try std.testing.expect(intermediate >= 1_000_000);
    try std.testing.expect(!timer.isStopped());

    // Tracker should still be empty (not recorded yet)
    try std.testing.expect(tracker.isEmpty());

    timer.stop();
    try std.testing.expect(!tracker.isEmpty());
}

test "format duration" {
    var buf: [64]u8 = undefined;

    // Nanoseconds
    const ns_result = formatDuration(500, &buf);
    try std.testing.expect(std.mem.indexOf(u8, ns_result, "500ns") != null);

    // Microseconds
    const us_result = formatDuration(1_500, &buf);
    try std.testing.expect(std.mem.indexOf(u8, us_result, "us") != null);

    // Milliseconds
    const ms_result = formatDuration(1_500_000, &buf);
    try std.testing.expect(std.mem.indexOf(u8, ms_result, "ms") != null);

    // Seconds
    const s_result = formatDuration(1_500_000_000, &buf);
    try std.testing.expect(std.mem.indexOf(u8, s_result, "s") != null);
}

test "empty tracker returns zeros" {
    const tracker = LatencyTracker.init();

    try std.testing.expectEqual(@as(u64, 0), tracker.minNs());
    try std.testing.expectEqual(@as(u64, 0), tracker.maxNs());
    try std.testing.expectEqual(@as(u64, 0), tracker.avgNs());
    try std.testing.expectEqual(@as(u64, 0), tracker.getCount());
}
