//! Lock-Free Single-Producer Single-Consumer (SPSC) Ring Buffer
//!
//! # Overview
//! Provides high-performance thread-to-thread communication without locks.
//! Essential for decoupling producers (e.g., network I/O) from consumers
//! (e.g., strategy logic) in low-latency trading systems.
//!
//! # Why Lock-Free?
//! "Locking any thread is a performance killer. If you must lock, use a spinlock.
//! For thread-to-thread messaging, use a lock-free SPSC queue."
//! — Roman Bansal, NanoConda
//!
//! Traditional mutexes involve:
//! 1. System calls (context switch overhead: ~1000+ cycles)
//! 2. Memory barriers
//! 3. Potential priority inversion
//! 4. Unbounded wait times
//!
//! This SPSC queue uses only atomic operations with acquire/release semantics,
//! avoiding all of the above.
//!
//! # False Sharing Prevention
//! The head (producer) and tail (consumer) indices are placed on SEPARATE
//! cache lines (64 bytes apart). Without this separation:
//!
//! ```
//! PROBLEM: Both indices on same cache line
//! ┌─────────────────────────────────────────────────────────────────┐
//! │ head (8B) │ tail (8B) │ ...unused...                           │
//! └─────────────────────────────────────────────────────────────────┘
//!      ▲            ▲
//!      │            │
//!   Producer     Consumer      → MESI invalidation ping-pong
//!   writes       writes          (50-100 cycles per access)
//! ```
//!
//! ```
//! SOLUTION: Indices on separate cache lines
//! Cache Line 1:                    Cache Line 2:
//! ┌────────────────────────────┐   ┌────────────────────────────┐
//! │ head (8B) │ padding (56B)  │   │ tail (8B) │ padding (56B)  │
//! └────────────────────────────┘   └────────────────────────────┘
//!      ▲                                ▲
//!   Producer                         Consumer    → No contention!
//!   (isolated)                       (isolated)
//! ```
//!
//! # Memory Ordering (Why acquire/release?)
//!
//! ## Producer (push):
//! 1. Write data to buffer[head]
//! 2. RELEASE store to head (publishes the write)
//!
//! Release semantics guarantee: the buffer write is visible to other threads
//! BEFORE they see the updated head. This is a "store-store" barrier.
//!
//! ## Consumer (pop):
//! 1. ACQUIRE load of head (synchronizes with producer's release)
//! 2. Read data from buffer[tail]
//! 3. RELEASE store to tail (publishes consumption)
//!
//! Acquire semantics guarantee: we see the buffer contents that were written
//! BEFORE the producer updated head. This is a "load-load" barrier.
//!
//! # Capacity Note
//! Due to the head==tail empty detection scheme, the usable capacity is
//! `capacity - 1`. For example, `RingBuffer(T, 1024)` can hold 1023 items.
//! Use `maxItems()` to get the actual usable capacity.
//!
//! # Power of Ten Compliance
//! - Rule 1: No recursion
//! - Rule 2: All loops bounded (none in hot path)
//! - Rule 3: No dynamic allocation
//! - Rule 4: Functions ≤60 lines
//! - Rule 5: ≥2 assertions per function
//! - Rule 6: Smallest scope for variables
//! - Rule 7: All parameters validated
//!
//! # Thread Safety
//! - Exactly ONE producer thread may call `push()`
//! - Exactly ONE consumer thread may call `pop()`
//! - `isEmpty()`, `isFull()`, `len()` are safe from any thread but approximate
//!
//! # Usage Example
//! ```zig
//! // Shared between threads
//! var queue = RingBuffer(Order, 4096).init();
//!
//! // Producer thread (e.g., network reader)
//! fn producer() void {
//!     while (running) {
//!         const order = receiveOrder();
//!         while (!queue.push(order)) {
//!             // Back-pressure: queue full, spin or yield
//!             std.atomic.spinLoopHint();
//!         }
//!     }
//! }
//!
//! // Consumer thread (e.g., strategy engine)
//! fn consumer() void {
//!     while (running) {
//!         if (queue.pop()) |order| {
//!             processOrder(order);
//!         } else {
//!             // No data, spin or yield
//!             std.atomic.spinLoopHint();
//!         }
//!     }
//! }
//! ```

const std = @import("std");
const types = @import("../protocol/types.zig");

// =============================================================================
// Compile-Time Configuration
// =============================================================================

/// Cache line size for target architecture (64 bytes for x86-64, ARM64).
const CACHE_LINE_SIZE = types.CACHE_LINE_SIZE;

// =============================================================================
// Ring Buffer Implementation
// =============================================================================

/// SPSC ring buffer with cache-line separated head/tail.
///
/// # Type Parameters
/// - `T`: Element type (copied on push/pop, not referenced)
/// - `capacity`: Buffer size, MUST be a power of 2 for fast modulo
///
/// # Effective Capacity
/// Usable capacity is `capacity - 1` due to empty detection scheme.
/// Call `maxItems()` for the actual limit.
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    // =========================================================================
    // Compile-Time Validation
    // =========================================================================
    comptime {
        if (capacity == 0) {
            @compileError("Ring buffer capacity must be greater than 0");
        }
        if (capacity & (capacity - 1) != 0) {
            @compileError("Ring buffer capacity must be a power of 2 for fast modulo via bitmask");
        }
        if (capacity == 1) {
            @compileError("Ring buffer capacity must be > 1 (usable capacity = capacity - 1)");
        }
        if (capacity > std.math.maxInt(usize) / 2) {
            @compileError("Ring buffer capacity too large (would overflow index arithmetic)");
        }
    }

    return struct {
        // Bitmask for fast modulo: index & mask == index % capacity
        const mask = capacity - 1;
        // =====================================================================
        // Cache-Line Separated Indices
        // =====================================================================
        // These MUST be on separate cache lines to prevent false sharing.
        // The producer writes head; the consumer writes tail.
        // Without separation, every push/pop would invalidate the other's cache.

        /// Producer write index. Only modified by producer thread.
        /// Aligned to cache line boundary.
        head: usize align(CACHE_LINE_SIZE) = 0,

        /// Padding to push tail to next cache line.
        /// Size = CACHE_LINE_SIZE - sizeof(usize) = 64 - 8 = 56 bytes.
        _pad_head: [CACHE_LINE_SIZE - @sizeOf(usize)]u8 = undefined,

        /// Consumer read index. Only modified by consumer thread.
        /// Aligned to cache line boundary (after padding).
        tail: usize align(CACHE_LINE_SIZE) = 0,

        /// Padding after tail for symmetry and to prevent false sharing
        /// with any data that might follow the ring buffer in memory.
        _pad_tail: [CACHE_LINE_SIZE - @sizeOf(usize)]u8 = undefined,

        // =====================================================================
        // Data Buffer
        // =====================================================================

        /// Circular buffer storage. Elements are copied, not referenced.
        buffer: [capacity]T = undefined,

        const Self = @This();

        // =====================================================================
        // Compile-Time Accessors
        // =====================================================================

        /// Returns the buffer capacity (power of 2).
        /// Note: Usable capacity is `capacity - 1`. Use `maxItems()`.
        pub fn getCapacity() usize {
            return capacity;
        }

        /// Returns the maximum number of items that can be stored.
        /// This is `capacity - 1` due to the empty detection scheme
        /// (head == tail means empty, so we can't let head catch up to tail).
        pub fn maxItems() usize {
            return capacity - 1;
        }

        /// Returns total memory footprint in bytes.
        pub fn getTotalMemorySize() usize {
            return @sizeOf(Self);
        }

        // =====================================================================
        // Initialization
        // =====================================================================

        /// Initialize an empty ring buffer.
        ///
        /// # Thread Safety
        /// Must be called before spawning producer/consumer threads.
        pub fn init() Self {
            const rb = Self{};

            // Post-condition assertions (Power of Ten Rule 5)
            std.debug.assert(rb.head == 0);
            std.debug.assert(rb.tail == 0);

            return rb;
        }

        // =====================================================================
        // Producer Operations (Single Thread Only)
        // =====================================================================

        /// Push an item to the buffer. Producer thread only.
        ///
        /// # Arguments
        /// - `item`: Value to copy into the buffer
        ///
        /// # Returns
        /// - `true` if item was successfully enqueued
        /// - `false` if buffer is full (back-pressure signal)
        ///
        /// # Memory Ordering
        /// Uses release semantics on head update to ensure the buffer write
        /// is visible to the consumer before they see the new head value.
        ///
        /// # Complexity
        /// O(1), wait-free (never blocks, never allocates)
        pub fn push(self: *Self, item: T) bool {
            const head = self.head;

            // Pre-condition: head is valid index (Power of Ten Rule 5)
            std.debug.assert(head < capacity);

            const next_head = (head + 1) & mask;

            // Assertion: next_head is also valid (Power of Ten Rule 5)
            std.debug.assert(next_head < capacity);

            // Check if full: would next write overwrite unread data?
            // Acquire load of tail synchronizes with consumer's release store.
            // This ensures we see the most recent tail value.
            const tail = @atomicLoad(usize, &self.tail, .acquire);

            if (next_head == tail) {
                // Buffer full - consumer hasn't caught up
                return false;
            }

            // Write data to buffer BEFORE publishing head.
            // This is critical: consumer must see data before seeing updated head.
            self.buffer[head] = item;

            // Publish to consumer with release semantics.
            // Release ensures: buffer write happens-before head update is visible.
            // Consumer's acquire load will synchronize with this release.
            @atomicStore(usize, &self.head, next_head, .release);

            return true;
        }

        /// Try to push multiple items. Producer thread only.
        ///
        /// # Returns
        /// Number of items successfully pushed (0 to items.len).
        ///
        /// # Use Case
        /// Batch operations for higher throughput when latency allows.
        pub fn pushBatch(self: *Self, items: []const T) usize {
            var pushed: usize = 0;

            // Bounded loop (Power of Ten Rule 2)
            for (items) |item| {
                if (!self.push(item)) break;
                pushed += 1;
            }

            return pushed;
        }

        // =====================================================================
        // Consumer Operations (Single Thread Only)
        // =====================================================================

        /// Pop an item from the buffer. Consumer thread only.
        ///
        /// # Returns
        /// - The oldest item if buffer is non-empty
        /// - `null` if buffer is empty
        ///
        /// # Memory Ordering
        /// Uses acquire semantics on head load to synchronize with producer's
        /// release store, ensuring we see the data written before head update.
        ///
        /// # Complexity
        /// O(1), wait-free
        pub fn pop(self: *Self) ?T {
            const tail = self.tail;

            // Pre-condition: tail is valid index (Power of Ten Rule 5)
            std.debug.assert(tail < capacity);

            // Check if empty: has producer written anything?
            // Acquire load synchronizes with producer's release store of head.
            // This ensures we see buffer contents written before head update.
            const head = @atomicLoad(usize, &self.head, .acquire);

            if (tail == head) {
                // Buffer empty - producer hasn't written anything new
                return null;
            }

            // Read data from buffer BEFORE publishing tail update.
            // This ensures we copy the data before telling producer the slot is free.
            const item = self.buffer[tail];

            const next_tail = (tail + 1) & mask;

            // Assertion: next_tail is valid (Power of Ten Rule 5)
            std.debug.assert(next_tail < capacity);

            // Publish consumption to producer with release semantics.
            // Producer's acquire load of tail will synchronize with this.
            @atomicStore(usize, &self.tail, next_tail, .release);

            return item;
        }

        /// Try to pop multiple items. Consumer thread only.
        ///
        /// # Arguments
        /// - `out`: Slice to write popped items into
        ///
        /// # Returns
        /// Number of items actually popped (0 to out.len).
        pub fn popBatch(self: *Self, out: []T) usize {
            var popped: usize = 0;

            // Bounded loop (Power of Ten Rule 2)
            for (out) |*slot| {
                if (self.pop()) |item| {
                    slot.* = item;
                    popped += 1;
                } else {
                    break;
                }
            }

            return popped;
        }

        /// Peek at the next item without removing it. Consumer thread only.
        ///
        /// # Returns
        /// - Pointer to next item if buffer non-empty
        /// - `null` if buffer is empty
        ///
        /// # Warning
        /// The returned pointer is only valid until the next `pop()` call.
        /// Do not store it across pop operations.
        pub fn peek(self: *Self) ?*const T {
            const tail = self.tail;
            std.debug.assert(tail < capacity);

            const head = @atomicLoad(usize, &self.head, .acquire);

            if (tail == head) {
                return null;
            }

            return &self.buffer[tail];
        }

        // =====================================================================
        // Status Queries (Any Thread - Approximate)
        // =====================================================================

        /// Check if buffer appears empty.
        ///
        /// # Thread Safety
        /// Safe to call from any thread, but result is approximate.
        /// By the time this returns, state may have changed.
        ///
        /// # Use Case
        /// Useful for monitoring/debugging, not for synchronization.
        pub fn isEmpty(self: *const Self) bool {
            // Both loads use acquire to get a consistent-ish view.
            // Note: there's inherent TOCTOU here; this is informational only.
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);

            std.debug.assert(head < capacity);
            std.debug.assert(tail < capacity);

            return head == tail;
        }

        /// Check if buffer appears full.
        ///
        /// # Thread Safety
        /// Safe to call from any thread, but result is approximate.
        pub fn isFull(self: *const Self) bool {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);

            std.debug.assert(head < capacity);
            std.debug.assert(tail < capacity);

            return ((head + 1) & mask) == tail;
        }

        /// Get approximate number of items in buffer.
        ///
        /// # Thread Safety
        /// Safe to call from any thread, but result is approximate.
        ///
        /// # Implementation Note
        /// Uses wrapping subtraction (`-%`) to handle wrap-around correctly.
        /// Example: head=2, tail=6, capacity=8, mask=7
        ///   2 -% 6 = wraps to a large number
        ///   & 7 = 4 (correct: slots 6,7,0,1 = 4 items)
        pub fn len(self: *const Self) usize {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);

            std.debug.assert(head < capacity);
            std.debug.assert(tail < capacity);

            // Wrapping subtraction handles case where head has wrapped but tail hasn't.
            // The mask ensures result is in [0, capacity).
            return (head -% tail) & mask;
        }

        /// Get approximate available space.
        pub fn availableSpace(self: *const Self) usize {
            // Max items is capacity - 1, subtract current length
            return maxItems() - self.len();
        }

        // =====================================================================
        // Debug Utilities
        // =====================================================================

        /// Validate ring buffer invariants. For debugging.
        ///
        /// # Returns
        /// `true` if all invariants hold.
        pub fn validateInvariants(self: *const Self) bool {
            const head = @atomicLoad(usize, &self.head, .acquire);
            const tail = @atomicLoad(usize, &self.tail, .acquire);

            // Invariant 1: indices must be in valid range
            if (head >= capacity) return false;
            if (tail >= capacity) return false;

            // Invariant 2: length must not exceed capacity - 1
            const length = (head -% tail) & mask;
            if (length >= capacity) return false;

            return true;
        }

        /// Reset buffer to empty state.
        ///
        /// # Thread Safety
        /// NOT thread-safe. Only call when no producers or consumers are active.
        ///
        /// # Warning
        /// Any items in the buffer are discarded without processing.
        pub fn reset(self: *Self) void {
            self.head = 0;
            self.tail = 0;

            std.debug.assert(self.validateInvariants());
        }
    };
}

// =============================================================================
// Pre-defined Ring Buffers
// =============================================================================

/// Message queue for output processing.
/// Capacity: 4096 (usable: 4095 messages).
pub const MessageQueue = RingBuffer(types.OutputMessage, 4096);

// =============================================================================
// Tests
// =============================================================================

test "ring buffer basic operations" {
    var rb = RingBuffer(u64, 8).init();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(!rb.isFull());
    try std.testing.expect(rb.validateInvariants());

    // Push some items
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    try std.testing.expectEqual(@as(usize, 3), rb.len());
    try std.testing.expect(!rb.isEmpty());

    // Pop items
    try std.testing.expectEqual(@as(u64, 1), rb.pop().?);
    try std.testing.expectEqual(@as(u64, 2), rb.pop().?);
    try std.testing.expectEqual(@as(u64, 3), rb.pop().?);

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(rb.pop() == null);
    try std.testing.expect(rb.validateInvariants());
}

test "ring buffer full behavior" {
    var rb = RingBuffer(u64, 4).init();

    // Verify max items
    try std.testing.expectEqual(@as(usize, 3), RingBuffer(u64, 4).maxItems());

    // Fill buffer (capacity - 1 items)
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));

    // Should be full now
    try std.testing.expect(rb.isFull());
    try std.testing.expect(!rb.push(4)); // Should fail

    // Pop one and try again
    try std.testing.expectEqual(@as(u64, 1), rb.pop().?);
    try std.testing.expect(!rb.isFull());
    try std.testing.expect(rb.push(4)); // Should succeed now

    try std.testing.expect(rb.validateInvariants());
}

test "ring buffer wrap around" {
    var rb = RingBuffer(u64, 4).init();

    // Fill and drain multiple times to test wrap-around
    for (0..20) |i| {
        try std.testing.expect(rb.push(i));
        try std.testing.expectEqual(i, rb.pop().?);
    }

    try std.testing.expect(rb.isEmpty());
    try std.testing.expect(rb.validateInvariants());
}

test "ring buffer capacity must be power of 2" {
    // These should compile
    _ = RingBuffer(u64, 2);
    _ = RingBuffer(u64, 4);
    _ = RingBuffer(u64, 8);
    _ = RingBuffer(u64, 1024);

    // These would fail at comptime (uncomment to verify):
    // _ = RingBuffer(u64, 0);   // Zero capacity
    // _ = RingBuffer(u64, 1);   // Usable capacity would be 0
    // _ = RingBuffer(u64, 3);   // Not power of 2
    // _ = RingBuffer(u64, 100); // Not power of 2
}

test "ring buffer cache line separation" {
    const RB = RingBuffer(u64, 8);
    var rb = RB.init();

    // Head and tail should be on different cache lines
    const head_addr = @intFromPtr(&rb.head);
    const tail_addr = @intFromPtr(&rb.tail);

    // Tail should be exactly one cache line after head
    try std.testing.expectEqual(CACHE_LINE_SIZE, tail_addr - head_addr);

    // Both should be cache-line aligned
    try std.testing.expect(head_addr % CACHE_LINE_SIZE == 0);
    try std.testing.expect(tail_addr % CACHE_LINE_SIZE == 0);
}

test "ring buffer peek" {
    var rb = RingBuffer(u64, 4).init();

    // Empty peek
    try std.testing.expect(rb.peek() == null);

    // Push and peek
    try std.testing.expect(rb.push(42));
    const peeked = rb.peek().?;
    try std.testing.expectEqual(@as(u64, 42), peeked.*);

    // Peek doesn't consume
    try std.testing.expectEqual(@as(usize, 1), rb.len());

    // Pop should return same value
    try std.testing.expectEqual(@as(u64, 42), rb.pop().?);
    try std.testing.expect(rb.isEmpty());
}

test "ring buffer batch operations" {
    var rb = RingBuffer(u64, 8).init();

    // Batch push
    const items = [_]u64{ 1, 2, 3, 4, 5 };
    const pushed = rb.pushBatch(&items);
    try std.testing.expectEqual(@as(usize, 5), pushed);
    try std.testing.expectEqual(@as(usize, 5), rb.len());

    // Batch pop
    var out: [10]u64 = undefined;
    const popped = rb.popBatch(&out);
    try std.testing.expectEqual(@as(usize, 5), popped);
    try std.testing.expectEqual(@as(u64, 1), out[0]);
    try std.testing.expectEqual(@as(u64, 5), out[4]);

    try std.testing.expect(rb.isEmpty());
}

test "ring buffer batch push overflow" {
    var rb = RingBuffer(u64, 4).init();

    // Try to push more than capacity
    const items = [_]u64{ 1, 2, 3, 4, 5 };
    const pushed = rb.pushBatch(&items);

    // Should only push 3 (max items for capacity 4)
    try std.testing.expectEqual(@as(usize, 3), pushed);
    try std.testing.expect(rb.isFull());
}

test "ring buffer available space" {
    var rb = RingBuffer(u64, 8).init();

    try std.testing.expectEqual(@as(usize, 7), rb.availableSpace());

    _ = rb.push(1);
    try std.testing.expectEqual(@as(usize, 6), rb.availableSpace());

    _ = rb.push(2);
    _ = rb.push(3);
    try std.testing.expectEqual(@as(usize, 4), rb.availableSpace());

    _ = rb.pop();
    try std.testing.expectEqual(@as(usize, 5), rb.availableSpace());
}

test "ring buffer reset" {
    var rb = RingBuffer(u64, 4).init();

    _ = rb.push(1);
    _ = rb.push(2);
    _ = rb.push(3);

    try std.testing.expect(rb.isFull());

    rb.reset();

    try std.testing.expect(rb.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), rb.len());
    try std.testing.expect(rb.validateInvariants());

    // Should be able to use normally after reset
    try std.testing.expect(rb.push(42));
    try std.testing.expectEqual(@as(u64, 42), rb.pop().?);
}

test "ring buffer memory layout size" {
    const RB = RingBuffer(u64, 1024);

    // Verify the struct has expected size:
    // - head: 8 bytes
    // - _pad_head: 56 bytes
    // - tail: 8 bytes (on new cache line)
    // - _pad_tail: 56 bytes
    // - buffer: 1024 * 8 = 8192 bytes
    // Total: 64 + 64 + 8192 = 8320 bytes
    const expected_size = (2 * CACHE_LINE_SIZE) + (1024 * @sizeOf(u64));
    try std.testing.expectEqual(expected_size, RB.getTotalMemorySize());
}
