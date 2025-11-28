//! Lock-free single-producer single-consumer (SPSC) ring buffer.
//!
//! Provides high-performance thread-to-thread communication without locks.
//! Uses cache-line padding to prevent false sharing between producer and
//! consumer indices.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// SPSC ring buffer with cache-line separated head/tail.
///
/// Memory layout (prevents false sharing):
///   [head index + 56 bytes padding]  <- Producer writes here
///   [tail index + 56 bytes padding]  <- Consumer writes here
///   [data buffer]
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    // Capacity must be power of 2 for fast modulo
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("Ring buffer capacity must be a power of 2");
        }
    }

    const mask = capacity - 1;

    return struct {
        // Producer cache line
        head: usize align(types.CACHE_LINE_SIZE) = 0,
        _pad_head: [types.CACHE_LINE_SIZE - @sizeOf(usize)]u8 = undefined,

        // Consumer cache line
        tail: usize align(types.CACHE_LINE_SIZE) = 0,
        _pad_tail: [types.CACHE_LINE_SIZE - @sizeOf(usize)]u8 = undefined,

        // Data buffer
        buffer: [capacity]T = undefined,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        /// Push an item (producer only). Returns false if full.
        pub fn push(self: *Self, item: T) bool {
            const head = self.head;
            const next_head = (head + 1) & mask;

            // Check if full (would overwrite unread data)
            if (next_head == @atomicLoad(usize, &self.tail, .acquire)) {
                return false;
            }

            self.buffer[head] = item;

            // Publish to consumer
            @atomicStore(usize, &self.head, next_head, .release);

            return true;
        }

        /// Pop an item (consumer only). Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const tail = self.tail;

            // Check if empty
            if (tail == @atomicLoad(usize, &self.head, .acquire)) {
                return null;
            }

            const item = self.buffer[tail];
            const next_tail = (tail + 1) & mask;

            // Publish to producer
            @atomicStore(usize, &self.tail, next_tail, .release);

            return item;
        }

        /// Check if empty (approximate - may race)
        pub fn isEmpty(self: *const Self) bool {
            return @atomicLoad(usize, &self.head, .acquire) ==
                @atomicLoad(usize, &self.tail, .acquire);
        }

        /// Check if full (approximate - may race)
        pub fn isFull(self: *const Self) bool {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            return ((head + 1) & mask) == tail;
        }

        /// Get approximate size (may race)
        pub fn len(self: *const Self) usize {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            return (head -% tail) & mask;
        }

        /// Get capacity
        pub fn getCapacity() usize {
            return capacity;
        }
    };
}

// ============================================================
// Pre-defined ring buffers
// ============================================================

/// Message queue for output processing
pub const MessageQueue = RingBuffer(types.OutputMessage, 4096);

// ============================================================
// Tests
// ============================================================

test "ring buffer basic operations" {
    var rb = RingBuffer(u64, 8).init();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(!rb.isFull());

    // Push some items
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    try std.testing.expectEqual(@as(usize, 3), rb.len());

    // Pop items
    try std.testing.expectEqual(@as(u64, 1), rb.pop().?);
    try std.testing.expectEqual(@as(u64, 2), rb.pop().?);
    try std.testing.expectEqual(@as(u64, 3), rb.pop().?);

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(rb.pop() == null);
}

test "ring buffer full" {
    var rb = RingBuffer(u64, 4).init();

    // Fill buffer (capacity - 1 items to avoid head==tail ambiguity)
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    // Should be full now
    try std.testing.expect(rb.isFull());
    try std.testing.expect(!rb.push(4)); // Should fail

    // Pop one and try again
    _ = rb.pop();
    try std.testing.expect(rb.push(4)); // Should succeed now
}

test "ring buffer wrap around" {
    var rb = RingBuffer(u64, 4).init();

    // Fill and drain multiple times to test wrap-around
    for (0..10) |i| {
        try std.testing.expect(rb.push(i));
        try std.testing.expectEqual(i, rb.pop().?);
    }
}

test "ring buffer capacity must be power of 2" {
    // This should compile
    _ = RingBuffer(u64, 4);
    _ = RingBuffer(u64, 8);
    _ = RingBuffer(u64, 1024);

    // These would fail at comptime:
    // _ = RingBuffer(u64, 3);
    // _ = RingBuffer(u64, 0);
}

test "ring buffer cache line separation" {
    const RB = RingBuffer(u64, 8);
    var rb = RB.init();

    // Head and tail should be on different cache lines
    const head_addr = @intFromPtr(&rb.head);
    const tail_addr = @intFromPtr(&rb.tail);
    const diff = if (tail_addr > head_addr) tail_addr - head_addr else head_addr - tail_addr;

    try std.testing.expect(diff >= types.CACHE_LINE_SIZE);
//! Lock-free single-producer single-consumer (SPSC) ring buffer.
//!
//! Provides high-performance thread-to-thread communication without locks.
//! Uses cache-line padding to prevent false sharing between producer and
//! consumer indices.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// SPSC ring buffer with cache-line separated head/tail.
///
/// Memory layout (prevents false sharing):
///   [head index + 56 bytes padding]  <- Producer writes here
///   [tail index + 56 bytes padding]  <- Consumer writes here
///   [data buffer]
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    // Capacity must be power of 2 for fast modulo
    comptime {
        if (capacity == 0 or (capacity & (capacity - 1)) != 0) {
            @compileError("Ring buffer capacity must be a power of 2");
        }
    }

    const mask = capacity - 1;

    return struct {
        // Producer cache line
        head: usize align(types.CACHE_LINE_SIZE) = 0,
        _pad_head: [types.CACHE_LINE_SIZE - @sizeOf(usize)]u8 = undefined,

        // Consumer cache line
        tail: usize align(types.CACHE_LINE_SIZE) = 0,
        _pad_tail: [types.CACHE_LINE_SIZE - @sizeOf(usize)]u8 = undefined,

        // Data buffer
        buffer: [capacity]T = undefined,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }

        /// Push an item (producer only). Returns false if full.
        pub fn push(self: *Self, item: T) bool {
            const head = self.head;
            const next_head = (head + 1) & mask;

            // Check if full (would overwrite unread data)
            if (next_head == @atomicLoad(usize, &self.tail, .acquire)) {
                return false;
            }

            self.buffer[head] = item;

            // Publish to consumer
            @atomicStore(usize, &self.head, next_head, .release);

            return true;
        }

        /// Pop an item (consumer only). Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const tail = self.tail;

            // Check if empty
            if (tail == @atomicLoad(usize, &self.head, .acquire)) {
                return null;
            }

            const item = self.buffer[tail];
            const next_tail = (tail + 1) & mask;

            // Publish to producer
            @atomicStore(usize, &self.tail, next_tail, .release);

            return item;
        }

        /// Check if empty (approximate - may race)
        pub fn isEmpty(self: *const Self) bool {
            return @atomicLoad(usize, &self.head, .acquire) ==
                @atomicLoad(usize, &self.tail, .acquire);
        }

        /// Check if full (approximate - may race)
        pub fn isFull(self: *const Self) bool {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            return ((head + 1) & mask) == tail;
        }

        /// Get approximate size (may race)
        pub fn len(self: *const Self) usize {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);
            return (head -% tail) & mask;
        }

        /// Get capacity
        pub fn getCapacity() usize {
            return capacity;
        }
    };
}

// ============================================================
// Pre-defined ring buffers
// ============================================================

/// Message queue for output processing
pub const MessageQueue = RingBuffer(types.OutputMessage, 4096);

// ============================================================
// Tests
// ============================================================

test "ring buffer basic operations" {
    var rb = RingBuffer(u64, 8).init();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(!rb.isFull());

    // Push some items
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    try std.testing.expectEqual(@as(usize, 3), rb.len());

    // Pop items
    try std.testing.expectEqual(@as(u64, 1), rb.pop().?);
    try std.testing.expectEqual(@as(u64, 2), rb.pop().?);
    try std.testing.expectEqual(@as(u64, 3), rb.pop().?);

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(rb.pop() == null);
}

test "ring buffer full" {
    var rb = RingBuffer(u64, 4).init();

    // Fill buffer (capacity - 1 items to avoid head==tail ambiguity)
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    // Should be full now
    try std.testing.expect(rb.isFull());
    try std.testing.expect(!rb.push(4)); // Should fail

    // Pop one and try again
    _ = rb.pop();
    try std.testing.expect(rb.push(4)); // Should succeed now
}

test "ring buffer wrap around" {
    var rb = RingBuffer(u64, 4).init();

    // Fill and drain multiple times to test wrap-around
    for (0..10) |i| {
        try std.testing.expect(rb.push(i));
        try std.testing.expectEqual(i, rb.pop().?);
    }
}

test "ring buffer capacity must be power of 2" {
    // This should compile
    _ = RingBuffer(u64, 4);
    _ = RingBuffer(u64, 8);
    _ = RingBuffer(u64, 1024);

    // These would fail at comptime:
    // _ = RingBuffer(u64, 3);
    // _ = RingBuffer(u64, 0);
}

test "ring buffer cache line separation" {
    const RB = RingBuffer(u64, 8);
    var rb = RB.init();

    // Head and tail should be on different cache lines
    const head_addr = @intFromPtr(&rb.head);
    const tail_addr = @intFromPtr(&rb.tail);
    const diff = if (tail_addr > head_addr) tail_addr - head_addr else head_addr - tail_addr;

    try std.testing.expect(diff >= types.CACHE_LINE_SIZE);
}}

