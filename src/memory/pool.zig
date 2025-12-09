//! Fixed-Size Memory Pool for Zero-Allocation Hot Path
//!
//! # Overview
//! Pre-allocates all memory at startup and provides O(1) allocation/deallocation.
//! This follows the HFT principle: "Run-time allocations in the hot path are
//! a sign of mediocre software." (Roman Bansal, NanoConda)
//!
//! # Cache-Line Alignment (Why It Matters)
//! Modern CPUs cache memory in 64-byte "cache lines". When two cores write to
//! different variables on the SAME cache line, the hardware must ping-pong the
//! entire line between cores (MESI protocol invalidation). This "false sharing"
//! can add 50-100 cycles per access—enough to lose the race in HFT.
//!
//! By aligning each pool item to 64 bytes, we guarantee that adjacent items
//! never share a cache line, eliminating this contention entirely.
//!
//! # Power of Ten Compliance
//! This module follows NASA JPL's Power of Ten rules for safety-critical code:
//! - Rule 2: All loops have fixed upper bounds (comptime capacity)
//! - Rule 3: No dynamic memory allocation after initialization
//! - Rule 4: Functions are ≤60 lines
//! - Rule 5: ≥2 assertions per function (in debug builds)
//! - Rule 6: Data declared at smallest scope
//! - Rule 7: All return values checked, all parameters validated
//!
//! # Thread Safety
//! This pool is NOT thread-safe. For multi-threaded use:
//! - Create one pool per thread (recommended), OR
//! - Add external synchronization (mutex/spinlock)
//!
//! # Usage Example
//! ```zig
//! const OrderPool = Pool(Order, 1024);
//! var pool = OrderPool.init();
//!
//! // Hot path - O(1), no syscalls, no allocator
//! const order = pool.alloc() orelse return error.PoolExhausted;
//! order.* = .{ .price = 100, .qty = 50 };
//!
//! // Return to pool when done
//! pool.free(order);
//! ```

const std = @import("std");
const types = @import("../protocol/types.zig");

// =============================================================================
// Compile-Time Configuration
// =============================================================================

/// Cache line size for the target architecture.
/// 64 bytes is standard for x86-64, ARM64, and most modern processors.
/// Verify with: `getconf LEVEL1_DCACHE_LINESIZE` on Linux.
const CACHE_LINE_SIZE = types.CACHE_LINE_SIZE;

// =============================================================================
// Pool Implementation
// =============================================================================

/// Generic fixed-size pool with compile-time known capacity.
///
/// Items are aligned to cache lines to prevent false sharing between adjacent
/// items when accessed from different threads or when the pool is used alongside
/// other hot data structures.
///
/// # Type Parameters
/// - `T`: The type of items to store. Can be any size.
/// - `capacity`: Maximum number of items. Must fit in u32 (< 4 billion).
///
/// # Memory Layout
/// ```
/// ┌─────────────────────────────────────────────────────────────────────┐
/// │ items[0]: │ data (T) │ padding to 64B │   ← Cache line 0           │
/// │ items[1]: │ data (T) │ padding to 64B │   ← Cache line 1 (or more) │
/// │ items[2]: │ data (T) │ padding to 64B │   ← Cache line 2 (or more) │
/// │ ...                                                                 │
/// ├─────────────────────────────────────────────────────────────────────┤
/// │ free_stack: [capacity]u32   ← Indices of available items            │
/// │ free_count: u32             ← Stack pointer (number of free items)  │
/// ├─────────────────────────────────────────────────────────────────────┤
/// │ Statistics: allocations, deallocations, peak_usage                  │
/// └─────────────────────────────────────────────────────────────────────┘
/// ```
pub fn Pool(comptime T: type, comptime capacity: usize) type {
    // =========================================================================
    // Compile-Time Validation (Power of Ten: catch bugs before runtime)
    // =========================================================================
    comptime {
        if (capacity == 0) {
            @compileError("Pool capacity must be greater than 0");
        }
        if (capacity > std.math.maxInt(u32)) {
            @compileError("Pool capacity exceeds u32 index range (max 4,294,967,295)");
        }
    }

    // =========================================================================
    // Cache-Aligned Item Wrapper
    // =========================================================================
    // Calculate padding needed to reach next cache line boundary.
    // If T is already a multiple of CACHE_LINE_SIZE, no padding needed.
    const remainder = @sizeOf(T) % CACHE_LINE_SIZE;
    const padding_size = if (remainder == 0) 0 else CACHE_LINE_SIZE - remainder;

    const AlignedT = struct {
        data: T,
        // Padding ensures each item starts on a cache line boundary.
        // Zero-length arrays are valid in Zig when padding_size == 0.
        _padding: [padding_size]u8 align(1) = undefined,

        comptime {
            // Verify our math: size must be multiple of cache line
            const size = @sizeOf(@This());
            if (size % CACHE_LINE_SIZE != 0) {
                @compileError("AlignedT size must be multiple of cache line size");
            }
        }
    };

    // Compute aligned item size at comptime for documentation/debugging
    const aligned_item_size = @sizeOf(AlignedT);

    return struct {
        // =====================================================================
        // Data Members
        // =====================================================================

        /// Storage for pool items, each cache-line aligned.
        items: [capacity]AlignedT align(CACHE_LINE_SIZE) = undefined,

        /// Free-list implemented as a stack for O(1) push/pop.
        /// Contains indices of available items.
        free_stack: [capacity]u32 = undefined,

        /// Number of items currently in the free stack (available for allocation).
        /// Invariant: 0 <= free_count <= capacity
        free_count: u32 = capacity,

        // =====================================================================
        // Statistics (for monitoring and debugging)
        // =====================================================================

        /// Total number of successful allocations since init.
        allocations: u64 = 0,

        /// Total number of deallocations since init.
        deallocations: u64 = 0,

        /// High-water mark: maximum concurrent items ever allocated.
        peak_usage: u32 = 0,

        const Self = @This();

        // =====================================================================
        // Compile-Time Accessors
        // =====================================================================

        /// Returns the maximum number of items this pool can hold.
        pub fn getCapacity() usize {
            return capacity;
        }

        /// Returns the size of each item including cache-line padding.
        /// Useful for memory budgeting.
        pub fn getAlignedItemSize() usize {
            return aligned_item_size;
        }

        /// Returns total memory footprint of the pool in bytes.
        pub fn getTotalMemorySize() usize {
            return @sizeOf(Self);
        }

        // =====================================================================
        // Initialization
        // =====================================================================

        /// Initialize a new pool with all items available.
        ///
        /// # Complexity
        /// O(capacity) - must initialize free stack.
        ///
        /// # When To Call
        /// Call once at program startup, before entering the hot path.
        pub fn init() Self {
            var pool = Self{};

            // Initialize free stack with all indices (0 to capacity-1).
            // After init, free_stack = [0, 1, 2, ..., capacity-1]
            // and free_count = capacity (all items available).
            //
            // Loop bound: fixed at comptime (Power of Ten Rule 2)
            for (0..capacity) |i| {
                pool.free_stack[i] = @intCast(i);
            }

            // Post-condition assertions (Power of Ten Rule 5)
            std.debug.assert(pool.free_count == capacity);
            std.debug.assert(pool.allocations == 0);
            std.debug.assert(pool.deallocations == 0);

            return pool;
        }

        // =====================================================================
        // Allocation (Hot Path)
        // =====================================================================

        /// Allocate an item from the pool.
        ///
        /// # Returns
        /// - Pointer to uninitialized memory of type T, or
        /// - `null` if pool is exhausted
        ///
        /// # Complexity
        /// O(1) - single stack pop, no syscalls, no locks.
        ///
        /// # Thread Safety
        /// NOT thread-safe. Use one pool per thread or add external sync.
        ///
        /// # Example
        /// ```zig
        /// const item = pool.alloc() orelse return error.PoolExhausted;
        /// item.* = MyStruct{ .field = value };
        /// ```
        pub fn alloc(self: *Self) ?*T {
            // Pre-condition: invariant check (Power of Ten Rule 5)
            std.debug.assert(self.free_count <= capacity);

            // Check for exhaustion
            if (self.free_count == 0) {
                return null;
            }

            // Pop index from free stack
            self.free_count -= 1;
            const idx = self.free_stack[self.free_count];

            // Assertion: index must be valid (Power of Ten Rule 5)
            std.debug.assert(idx < capacity);

            // Update statistics
            self.allocations += 1;
            const current_usage: u32 = @intCast(capacity - self.free_count);
            if (current_usage > self.peak_usage) {
                self.peak_usage = current_usage;
            }

            // Post-condition: we return a valid pointer
            const ptr = &self.items[idx].data;
            std.debug.assert(@intFromPtr(ptr) != 0);

            return ptr;
        }

        // =====================================================================
        // Deallocation (Hot Path)
        // =====================================================================

        /// Return an item to the pool.
        ///
        /// # Safety
        /// - `ptr` MUST have been returned by `alloc()` on THIS pool instance
        /// - `ptr` MUST NOT have already been freed (double-free)
        /// - `ptr` MUST NOT be used after this call (use-after-free)
        ///
        /// # Complexity
        /// O(1) in release builds.
        /// O(n) in debug builds due to double-free detection.
        ///
        /// # Panics (Debug Builds Only)
        /// - If `ptr` is not from this pool
        /// - If `ptr` has already been freed (double-free)
        /// - If pool is in invalid state
        pub fn free(self: *Self, ptr: *T) void {
            // Pre-condition: pool not already full (Power of Ten Rule 5)
            std.debug.assert(self.free_count < capacity);

            // Calculate base address and bounds of our item array
            const base_addr = @intFromPtr(&self.items[0].data);
            const end_addr = base_addr + (capacity * aligned_item_size);
            const ptr_addr = @intFromPtr(ptr);

            // Assertion: pointer is within pool bounds (Power of Ten Rule 5)
            std.debug.assert(ptr_addr >= base_addr);
            std.debug.assert(ptr_addr < end_addr);

            // Calculate offset from base
            const offset = ptr_addr - base_addr;

            // Assertion: pointer is properly aligned to item boundary
            // This catches pointers into the middle of items or padding
            std.debug.assert(offset % aligned_item_size == 0);

            const idx: u32 = @intCast(offset / aligned_item_size);

            // Assertion: calculated index is valid (redundant but explicit)
            std.debug.assert(idx < capacity);

            // Double-free detection (debug builds only)
            // This is O(n) but only runs in debug/safe builds.
            // In release builds, this entire block is compiled out.
            if (std.debug.runtime_safety) {
                for (self.free_stack[0..self.free_count]) |free_idx| {
                    if (free_idx == idx) {
                        // DOUBLE-FREE DETECTED!
                        // This is a critical bug - the same pointer was freed twice.
                        // In a real trading system, this could cause:
                        // - Two orders sharing the same memory
                        // - Data corruption
                        // - Undefined behavior
                        std.debug.panic(
                            "DOUBLE-FREE DETECTED: index {} freed twice. " ++
                                "Allocations: {}, Deallocations: {}, Free count: {}",
                            .{ idx, self.allocations, self.deallocations, self.free_count },
                        );
                    }
                }
            }

            // Push index back onto free stack
            self.free_stack[self.free_count] = idx;
            self.free_count += 1;
            self.deallocations += 1;

            // Post-condition: invariant maintained
            std.debug.assert(self.free_count <= capacity);
        }

        // =====================================================================
        // Statistics and Monitoring
        // =====================================================================

        /// Statistics snapshot for monitoring dashboards.
        pub const Stats = struct {
            /// Maximum items the pool can hold
            capacity: usize,
            /// Currently allocated items
            used: usize,
            /// Items available for allocation
            available: usize,
            /// Total allocations since init
            allocations: u64,
            /// Total deallocations since init
            deallocations: u64,
            /// Maximum concurrent allocations ever observed
            peak: u32,
            /// Memory used per item (including alignment padding)
            bytes_per_item: usize,
            /// Total memory footprint of pool
            total_bytes: usize,
        };

        /// Get current usage statistics.
        ///
        /// # Thread Safety
        /// Safe to call from any thread (reads only).
        /// Values may be slightly stale in multi-threaded context.
        pub fn getStats(self: *const Self) Stats {
            // Pre-condition assertions (Power of Ten Rule 5)
            std.debug.assert(self.free_count <= capacity);
            std.debug.assert(self.deallocations <= self.allocations);

            return .{
                .capacity = capacity,
                .used = capacity - self.free_count,
                .available = self.free_count,
                .allocations = self.allocations,
                .deallocations = self.deallocations,
                .peak = self.peak_usage,
                .bytes_per_item = aligned_item_size,
                .total_bytes = @sizeOf(Self),
            };
        }

        /// Check if pool has no allocated items.
        pub fn isEmpty(self: *const Self) bool {
            std.debug.assert(self.free_count <= capacity);
            return self.free_count == capacity;
        }

        /// Check if pool has no available items.
        pub fn isFull(self: *const Self) bool {
            std.debug.assert(self.free_count <= capacity);
            return self.free_count == 0;
        }

        /// Get number of currently allocated items.
        pub fn usedCount(self: *const Self) usize {
            std.debug.assert(self.free_count <= capacity);
            return capacity - self.free_count;
        }

        /// Get number of available items.
        pub fn availableCount(self: *const Self) usize {
            std.debug.assert(self.free_count <= capacity);
            return self.free_count;
        }

        // =====================================================================
        // Debug Utilities
        // =====================================================================

        /// Validate pool invariants. Call periodically in debug builds.
        ///
        /// # Returns
        /// `true` if all invariants hold, `false` otherwise.
        ///
        /// # Checked Invariants
        /// 1. free_count <= capacity
        /// 2. All indices in free_stack are < capacity
        /// 3. No duplicate indices in free_stack
        /// 4. deallocations <= allocations
        pub fn validateInvariants(self: *const Self) bool {
            // Invariant 1: free_count in valid range
            if (self.free_count > capacity) return false;

            // Invariant 2: all free indices are valid
            for (self.free_stack[0..self.free_count]) |idx| {
                if (idx >= capacity) return false;
            }

            // Invariant 3: no duplicate indices in free stack
            // O(n²) but only for debugging
            for (0..self.free_count) |i| {
                for (i + 1..self.free_count) |j| {
                    if (self.free_stack[i] == self.free_stack[j]) return false;
                }
            }

            // Invariant 4: can't have more deallocations than allocations
            if (self.deallocations > self.allocations) return false;

            return true;
        }

        /// Reset pool to initial state. All allocated items become invalid.
        ///
        /// # Warning
        /// Any pointers returned by previous `alloc()` calls become INVALID.
        /// Using them after reset is undefined behavior.
        ///
        /// # Use Case
        /// Useful for recycling a pool between test runs or trading sessions.
        pub fn reset(self: *Self) void {
            // Reinitialize free stack
            for (0..capacity) |i| {
                self.free_stack[i] = @intCast(i);
            }
            self.free_count = capacity;

            // Reset statistics
            self.allocations = 0;
            self.deallocations = 0;
            self.peak_usage = 0;

            // Post-condition
            std.debug.assert(self.validateInvariants());
        }
    };
}

// =============================================================================
// Pre-defined Pools for Common Use Cases
// =============================================================================

/// Pool for output messages (aligned to cache line).
/// Capacity: 1024 messages, suitable for typical order flow.
pub const MessagePool = Pool(types.OutputMessage, 1024);

// =============================================================================
// Tests
// =============================================================================

test "pool basic operations" {
    const TestItem = struct {
        value: u64,
        name: [8]u8,
    };

    var pool = Pool(TestItem, 10).init();

    // Verify initial state
    try std.testing.expect(pool.isEmpty());
    try std.testing.expect(!pool.isFull());
    try std.testing.expect(pool.validateInvariants());

    // Allocate some items
    const item1 = pool.alloc().?;
    item1.value = 42;
    item1.name = "ORDER001".*;

    const item2 = pool.alloc().?;
    item2.value = 123;
    item2.name = "ORDER002".*;

    try std.testing.expectEqual(@as(u64, 42), item1.value);
    try std.testing.expectEqual(@as(u64, 123), item2.value);

    // Check stats
    const stats = pool.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.used);
    try std.testing.expectEqual(@as(usize, 8), stats.available);
    try std.testing.expectEqual(@as(u64, 2), stats.allocations);
    try std.testing.expectEqual(@as(u64, 0), stats.deallocations);

    // Free one
    pool.free(item1);
    try std.testing.expectEqual(@as(usize, 1), pool.getStats().used);
    try std.testing.expectEqual(@as(u64, 1), pool.getStats().deallocations);

    // Allocate again - should reuse freed slot
    const item3 = pool.alloc().?;
    item3.value = 999;
    try std.testing.expectEqual(@as(usize, 2), pool.getStats().used);

    // Validate invariants
    try std.testing.expect(pool.validateInvariants());
}

test "pool exhaustion" {
    var pool = Pool(u64, 2).init();

    const item1 = pool.alloc().?;
    const item2 = pool.alloc().?;
    item1.* = 1;
    item2.* = 2;

    // Pool should be exhausted
    try std.testing.expect(pool.alloc() == null);
    try std.testing.expect(pool.isFull());
    try std.testing.expectEqual(@as(usize, 2), pool.usedCount());
    try std.testing.expectEqual(@as(usize, 0), pool.availableCount());

    // Free one and retry
    pool.free(item1);
    try std.testing.expect(!pool.isFull());

    const item3 = pool.alloc();
    try std.testing.expect(item3 != null);
}

test "pool cache alignment" {
    const TestItem = struct { x: u32 };

    var pool = Pool(TestItem, 4).init();

    const item1 = pool.alloc().?;
    const item2 = pool.alloc().?;

    const addr1 = @intFromPtr(item1);
    const addr2 = @intFromPtr(item2);

    // Items must be on different cache lines
    const diff = if (addr2 > addr1) addr2 - addr1 else addr1 - addr2;
    try std.testing.expect(diff >= types.CACHE_LINE_SIZE);

    // Addresses should be cache-line aligned
    try std.testing.expect(addr1 % types.CACHE_LINE_SIZE == 0);
    try std.testing.expect(addr2 % types.CACHE_LINE_SIZE == 0);
}

test "pool handles types larger than cache line" {
    const BigItem = struct {
        data: [128]u8, // 2 cache lines worth
        id: u64,
    };

    var pool = Pool(BigItem, 4).init();

    const item1 = pool.alloc().?;
    const item2 = pool.alloc().?;

    const addr1 = @intFromPtr(item1);
    const addr2 = @intFromPtr(item2);

    // Items should be properly separated
    const diff = if (addr2 > addr1) addr2 - addr1 else addr1 - addr2;

    // Should be at least the size of BigItem rounded up to cache line
    const expected_min = ((@sizeOf(BigItem) + types.CACHE_LINE_SIZE - 1) /
        types.CACHE_LINE_SIZE) * types.CACHE_LINE_SIZE;
    try std.testing.expect(diff >= expected_min);
}

test "pool handles cache-line sized types efficiently" {
    // Type that's exactly one cache line - should have NO padding waste
    const ExactCacheLine = struct {
        data: [types.CACHE_LINE_SIZE]u8,
    };

    const PoolType = Pool(ExactCacheLine, 4);

    // Verify no wasted padding
    try std.testing.expectEqual(types.CACHE_LINE_SIZE, PoolType.getAlignedItemSize());
}

test "pool reset" {
    var pool = Pool(u64, 4).init();

    // Allocate all
    _ = pool.alloc().?;
    _ = pool.alloc().?;
    _ = pool.alloc().?;
    _ = pool.alloc().?;

    try std.testing.expect(pool.isFull());
    try std.testing.expectEqual(@as(u64, 4), pool.getStats().allocations);

    // Reset
    pool.reset();

    try std.testing.expect(pool.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), pool.getStats().allocations);
    try std.testing.expect(pool.validateInvariants());

    // Should be able to allocate again
    const item = pool.alloc();
    try std.testing.expect(item != null);
}

test "pool statistics tracking" {
    var pool = Pool(u32, 8).init();

    // Track peak usage
    var items: [8]?*u32 = .{null} ** 8;

    // Allocate 5 items
    for (0..5) |i| {
        items[i] = pool.alloc();
    }
    try std.testing.expectEqual(@as(u32, 5), pool.getStats().peak);

    // Free 3 items
    for (0..3) |i| {
        pool.free(items[i].?);
    }
    try std.testing.expectEqual(@as(u32, 5), pool.getStats().peak); // Peak unchanged

    // Allocate 6 more (total 8)
    for (0..6) |i| {
        items[i] = pool.alloc();
    }
    try std.testing.expectEqual(@as(u32, 8), pool.getStats().peak);
}

test "pool invariant validation" {
    var pool = Pool(u64, 4).init();

    // Should pass initially
    try std.testing.expect(pool.validateInvariants());

    // Allocate and free some items
    const item1 = pool.alloc().?;
    const item2 = pool.alloc().?;
    pool.free(item1);
    _ = pool.alloc();
    pool.free(item2);

    // Should still pass
    try std.testing.expect(pool.validateInvariants());
}
