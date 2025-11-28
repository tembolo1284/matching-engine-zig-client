//! Fixed-size memory pool for zero-allocation hot path.
//!
//! Pre-allocates all memory at startup and provides O(1) allocation/deallocation.
//! This follows the HFT principle: "Run-time allocations in the hot path are
//! a sign of mediocre software."
//!
//! The pool uses a free-list stack for O(1) operations and cache-line alignment
//! to prevent false sharing between adjacent items.

const std = @import("std");
const types = @import("../protocol/types.zig");

/// Generic fixed-size pool with compile-time known capacity.
/// Items are aligned to cache lines to prevent false sharing.
pub fn Pool(comptime T: type, comptime capacity: usize) type {
    // Ensure items are cache-line aligned
    const AlignedT = struct {
        data: T,
        _padding: [types.CACHE_LINE_SIZE - (@sizeOf(T) % types.CACHE_LINE_SIZE)]u8 = undefined,

        comptime {
            // Verify alignment math is correct
            if (@sizeOf(@This()) % types.CACHE_LINE_SIZE != 0) {
                @compileError("AlignedT size must be multiple of cache line");
            }
        }
    };

    return struct {
        items: [capacity]AlignedT = undefined,
        free_stack: [capacity]u32 = undefined,
        free_count: u32 = capacity,

        // Statistics for monitoring
        allocations: u64 = 0,
        deallocations: u64 = 0,
        peak_usage: u32 = 0,

        const Self = @This();

        pub fn init() Self {
            var pool = Self{};

            // Initialize free stack with all indices
            for (0..capacity) |i| {
                pool.free_stack[i] = @intCast(i);
            }

            return pool;
        }

        /// Allocate an item from the pool. Returns null if pool exhausted.
        pub fn alloc(self: *Self) ?*T {
            if (self.free_count == 0) return null;

            self.free_count -= 1;
            const idx = self.free_stack[self.free_count];

            self.allocations += 1;
            const usage = capacity - self.free_count;
            if (usage > self.peak_usage) {
                self.peak_usage = @intCast(usage);
            }

            return &self.items[idx].data;
        }

        /// Return an item to the pool
        pub fn free(self: *Self, ptr: *T) void {
            // Calculate index from pointer
            const base = @intFromPtr(&self.items[0].data);
            const item_ptr = @intFromPtr(ptr);
            const offset = item_ptr - base;
            const idx = offset / @sizeOf(AlignedT);

            std.debug.assert(idx < capacity);
            std.debug.assert(self.free_count < capacity);

            self.free_stack[self.free_count] = @intCast(idx);
            self.free_count += 1;
            self.deallocations += 1;
        }

        /// Get current usage statistics
        pub fn getStats(self: *const Self) struct {
            capacity: usize,
            used: usize,
            available: usize,
            allocations: u64,
            deallocations: u64,
            peak: u32,
        } {
            return .{
                .capacity = capacity,
                .used = capacity - self.free_count,
                .available = self.free_count,
                .allocations = self.allocations,
                .deallocations = self.deallocations,
                .peak = self.peak_usage,
            };
        }

        /// Check if pool is empty
        pub fn isEmpty(self: *const Self) bool {
            return self.free_count == capacity;
        }

        /// Check if pool is full
        pub fn isFull(self: *const Self) bool {
            return self.free_count == 0;
        }
    };
}

// ============================================================
// Pre-defined pools for common use cases
// ============================================================

/// Pool for output messages (aligned to cache line)
pub const MessagePool = Pool(types.OutputMessage, 1024);

// ============================================================
// Tests
// ============================================================

test "pool basic operations" {
    const TestItem = struct {
        value: u64,
    };

    var pool = Pool(TestItem, 10).init();

    // Allocate some items
    const item1 = pool.alloc().?;
    item1.value = 42;

    const item2 = pool.alloc().?;
    item2.value = 123;

    try std.testing.expectEqual(@as(u64, 42), item1.value);
    try std.testing.expectEqual(@as(u64, 123), item2.value);

    // Check stats
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.used);
    try std.testing.expectEqual(@as(usize, 8), stats.available);

    // Free one
    pool.free(item1);
    try std.testing.expectEqual(@as(usize, 1), pool.getStats().used);

    // Allocate again
    const item3 = pool.alloc().?;
    item3.value = 999;
    try std.testing.expectEqual(@as(usize, 2), pool.getStats().used);
}

test "pool exhaustion" {
    var pool = Pool(u64, 2).init();

    _ = pool.alloc().?;
    _ = pool.alloc().?;

    // Pool should be exhausted
    try std.testing.expect(pool.alloc() == null);
    try std.testing.expect(pool.isFull());
}

test "pool cache alignment" {
    const TestItem = struct { x: u32 };

    // Items should be separated by at least cache line size
    var pool = Pool(TestItem, 4).init();

    const item1 = pool.alloc().?;
    const item2 = pool.alloc().?;

    const addr1 = @intFromPtr(item1);
    const addr2 = @intFromPtr(item2);
    const diff = if (addr2 > addr1) addr2 - addr1 else addr1 - addr2;

    try std.testing.expect(diff >= types.CACHE_LINE_SIZE);
}
