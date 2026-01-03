//! Scenario Configuration
//!
//! Tunable parameters for stress tests. Adjust these to balance
//! throughput vs reliability based on your server's capacity.

/// Global quiet mode flag
pub var quiet: bool = false;

pub fn setQuiet(q: bool) void {
    quiet = q;
}

// ============================================================
// Drain Parameters
// ============================================================

/// Poll timeout for drainAllAvailable() - 0 = immediate return
pub const QUICK_DRAIN_POLL_MS: i32 = 0;

/// Poll timeout for drainWithPatience()
pub const PATIENT_DRAIN_POLL_MS: i32 = 10;

/// Max consecutive empty polls before giving up in patient drain
pub const MAX_CONSECUTIVE_EMPTY: u32 = 500;

/// Safety limit for quick drain iterations
pub const QUICK_DRAIN_LIMIT: u32 = 10000;

/// Default timeout for patient drain (ms)
pub const DEFAULT_DRAIN_TIMEOUT_MS: u64 = 10000;

// ============================================================
// Batch Parameters
// ============================================================

/// Pairs per batch for matching stress tests
/// Smaller = more responsive but slower
/// Larger = faster but risk buffer overflow
pub const MATCHING_BATCH_SIZE: u64 = 100;

/// Pairs per batch for dual-processor tests
pub const DUAL_PROC_BATCH_SIZE: u64 = 100;

/// Orders per drain cycle in unmatched stress
pub const UNMATCHED_DRAIN_INTERVAL: u64 = 1000;

// ============================================================
// Interactive Scenario Parameters
// ============================================================

/// Poll timeout for interactive recv (ms)
pub const INTERACTIVE_POLL_MS: i32 = 10;

/// Max consecutive empty polls for interactive scenarios
pub const INTERACTIVE_MAX_EMPTY: u32 = 10;

// ============================================================
// Timing Constants
// ============================================================

pub const NS_PER_MS: u64 = 1_000_000;
pub const NS_PER_SEC: u64 = 1_000_000_000;

// ============================================================
// Expected Messages
// ============================================================

/// Messages generated per matching pair: 2 ACKs + 1 Trade + 2 TOB
pub const MSGS_PER_MATCHING_PAIR: u64 = 5;

/// Messages generated per unmatched order: 1 ACK + 1 TOB
pub const MSGS_PER_UNMATCHED_ORDER: u64 = 2;
