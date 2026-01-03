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

    const tcp_ptr = &(client.tcp_client orelse return stats);

    var drain_count: u32 = 0;
    while (drain_count < config.QUICK_DRAIN_LIMIT) : (drain_count += 1) {
        const maybe_data = tcp_ptr.tryRecv(config.QUICK_DRAIN_POLL_MS) catch |err| {
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

    const tcp_ptr = &(client.tcp_client orelse return stats);

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

        const maybe_data = tcp_ptr.tryRecv(config.PATIENT_DRAIN_POLL_MS) catch |err| {
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

    return stats;
}

// ============================================================
// Balanced Drain (For synchronized send/recv)
// ============================================================

/// Drain a specific number of expected responses with moderate patience.
/// Use this in batch-synchronized mode where we send N, then drain N.
pub fn drainBatch(
    tcp_ptr: *TcpClient,
    proto: anytype,
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

// ============================================================
// Flush Helper
// ============================================================

/// Send flush and drain any remaining responses
pub fn flushAndDrain(client: *EngineClient, drain_timeout_ms: u64) !types.ResponseStats {
    try client.sendFlush();
    std.Thread.sleep(200 * config.NS_PER_MS);
    return drainWithPatience(client, 10000, drain_timeout_ms);
}
