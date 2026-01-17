//! Drain Functions
//!
//! Functions for draining responses from the server.
//! These are the most performance-sensitive functions and
//! the most likely to need tuning.
const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");
const helpers = @import("helpers.zig");
const EngineClient = @import("../client/engine_client.zig").EngineClient;
const Protocol = @import("../client/engine_client.zig").Protocol;
const TcpClient = @import("../transport/tcp.zig").TcpClient;
const timestamp = @import("../util/timestamp.zig");

// ============================================================
// Quick Drain (Non-blocking)
// ============================================================

/// Drain ALL immediately available responses (non-blocking)
/// Returns as soon as there's nothing ready - doesn't wait.
/// Use this during send loops to prevent buffer overflow.
pub fn drainAllAvailable(client: *EngineClient) !types.ResponseStats {
    var stats = types.ResponseStats{};
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        var drain_count: u32 = 0;
        while (drain_count < config.QUICK_DRAIN_LIMIT) : (drain_count += 1) {
            const maybe_data = tcp_client.tryRecv(config.QUICK_DRAIN_POLL_MS) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    break;
                }
                return err;
            };

            if (maybe_data) |raw_data| {
                if (helpers.parseMessage(raw_data, proto)) |m| {
                    helpers.countMessage(&stats, m);
                }
            } else {
                break;
            }
        }
    }

    return stats;
}

// ============================================================
// Patient Drain (With timeout)
// ============================================================

/// Drain with patience - wait for expected_count messages or timeout.
/// Use this at the end of tests to collect remaining responses.
pub fn drainWithPatience(client: *EngineClient, expected_count: u64, timeout_ms: u64) !types.ResponseStats {
    var stats = types.ResponseStats{};
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        const start_time = timestamp.now();
        const timeout_ns = timeout_ms * config.NS_PER_MS;
        var consecutive_empty: u32 = 0;

        while (stats.total() < expected_count) {
            if (timestamp.now() - start_time > timeout_ns) {
                break;
            }

            if (consecutive_empty >= config.MAX_CONSECUTIVE_EMPTY) {
                break;
            }

            const maybe_data = tcp_client.tryRecv(config.PATIENT_DRAIN_POLL_MS) catch |err| {
                if (err == error.WouldBlock or err == error.Timeout) {
                    consecutive_empty += 1;
                    continue;
                }
                return err;
            };

            if (maybe_data) |raw_data| {
                if (helpers.parseMessage(raw_data, proto)) |m| {
                    helpers.countMessage(&stats, m);
                    consecutive_empty = 0;
                }
            } else {
                consecutive_empty += 1;
            }
        }
    }

    return stats;
}

// ============================================================
// Adaptive Drain (Stall-based timeout)
// ============================================================

/// Drain until target trade count reached or stalled too long.
/// This is the key to adaptive pacing - wait for actual results, not arbitrary timeouts.
/// Only gives up after max_stall_ms of NO NEW TRADES (not just no data).
pub fn drainUntilTrades(
    client: *EngineClient,
    stats: *types.ResponseStats,
    target_trades: u64,
    max_stall_ms: u64,
) !void {
    const proto = client.getProtocol();
    const tcp_client = &(client.tcp_client orelse return);

    var last_trade_count: u64 = stats.trades;
    var stall_start: u64 = 0;
    var stalling = false;

    while (stats.trades < target_trades) {
        const maybe_data = tcp_client.tryRecv(20) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                // No data - check stall
                if (stats.trades != last_trade_count) {
                    // Got new trades since last check, reset
                    last_trade_count = stats.trades;
                    stalling = false;
                } else if (!stalling) {
                    // Start stall timer
                    stalling = true;
                    stall_start = timestamp.now();
                } else {
                    // Check if stalled too long
                    const stall_ns = timestamp.now() - stall_start;
                    if (stall_ns > max_stall_ms * config.NS_PER_MS) {
                        break; // Stalled too long
                    }
                    std.Thread.sleep(5 * config.NS_PER_MS);
                }
                continue;
            }
            return err;
        };

        if (maybe_data) |raw_data| {
            if (helpers.parseMessage(raw_data, proto)) |m| {
                helpers.countMessage(stats, m);
            }
            stalling = false;
        } else {
            // Same stall logic as timeout case
            if (stats.trades != last_trade_count) {
                last_trade_count = stats.trades;
                stalling = false;
            } else if (!stalling) {
                stalling = true;
                stall_start = timestamp.now();
            } else {
                const stall_ns = timestamp.now() - stall_start;
                if (stall_ns > max_stall_ms * config.NS_PER_MS) {
                    break;
                }
                std.Thread.sleep(5 * config.NS_PER_MS);
            }
        }
    }
}

// ============================================================
// Balanced Drain (For synchronized send/recv)
// ============================================================

/// Drain a specific number of expected responses with moderate patience.
/// Use this in batch-synchronized mode where we send N, then drain N.
pub fn drainBatch(
    tcp_ptr: *TcpClient,
    proto: Protocol,
    expected_count: u64,
    max_empty: u32,
    poll_ms: i32,
) !types.ResponseStats {
    var stats = types.ResponseStats{};
    var received: u64 = 0;
    var consecutive_empty: u32 = 0;

    while (received < expected_count and consecutive_empty < max_empty) {
        const maybe_data = tcp_ptr.tryRecv(poll_ms) catch |err| {
            if (err == error.WouldBlock or err == error.Timeout) {
                consecutive_empty += 1;
                continue;
            }
            return err;
        };

        if (maybe_data) |raw_data| {
            if (helpers.parseMessage(raw_data, proto)) |m| {
                helpers.countMessage(&stats, m);
                received += 1;
                consecutive_empty = 0;
            }
        } else {
            consecutive_empty += 1;
        }
    }

    return stats;
}

// ============================================================
// Interactive Drain (For basic scenarios)
// ============================================================

/// Receive and print responses for interactive scenarios.
/// Uses short timeouts and stops after consecutive empty polls.
pub fn recvAndPrint(client: *EngineClient, stderr: std.fs.File, max_responses: u32) !void {
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        var consecutive_empty: u32 = 0;

        while (response_count < max_responses and consecutive_empty < config.INTERACTIVE_MAX_EMPTY) {
            const maybe_data = tcp_client.tryRecv(config.INTERACTIVE_POLL_MS) catch |err| {
                if (err == error.Timeout or err == error.WouldBlock) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                consecutive_empty = 0;
                try helpers.printRawResponse(raw_data, proto, stderr);
                response_count += 1;
            } else {
                consecutive_empty += 1;
            }
        }
    }
}

/// More patient version for after flush - waits longer for stragglers
pub fn recvAndPrintPatient(client: *EngineClient, stderr: std.fs.File, max_responses: u32) !void {
    const proto = client.getProtocol();

    if (client.tcp_client) |*tcp_client| {
        var response_count: u32 = 0;
        var consecutive_empty: u32 = 0;
        const max_empty: u32 = 30; // More patient - 30 * 20ms = 600ms max wait

        while (response_count < max_responses and consecutive_empty < max_empty) {
            const maybe_data = tcp_client.tryRecv(20) catch |err| {
                if (err == error.Timeout or err == error.WouldBlock) {
                    consecutive_empty += 1;
                    continue;
                }
                break;
            };

            if (maybe_data) |raw_data| {
                consecutive_empty = 0;
                try helpers.printRawResponse(raw_data, proto, stderr);
                response_count += 1;
            } else {
                consecutive_empty += 1;
            }
        }
    }
}

// ============================================================
// Flush Helper
// ============================================================

/// Send flush and drain any remaining responses
pub fn flushAndDrain(client: *EngineClient, drain_timeout_ms: u64) !types.ResponseStats {
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);
    return drainWithPatience(client, 10000, drain_timeout_ms);
}
