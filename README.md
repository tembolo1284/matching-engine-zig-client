# Matching Engine Zig Client

A high-performance, cross-platform client for the C matching engine, written in Zig with a focus on low-latency trading system principles.

## Features

- **Multiple Transports**: TCP (reliable), UDP (fire-and-forget), Multicast (market data)
- **Multiple Protocols**: Binary (lowest latency) and CSV (human-readable)
- **Cross-Platform**: Linux, macOS, Windows from a single codebase
- **Zero-Allocation Hot Path**: Pre-allocated memory pools, no malloc during trading
- **Cache-Optimized**: 64-byte aligned structures prevent false sharing
- **Interactive Mode**: REPL-style interface like the C tcp_client

## Quick Start

```bash
# Build
zig build

# Connect to server (TCP mode, default)
./zig-out/bin/me-client localhost 1234

# Connect to server (UDP mode)
./zig-out/bin/me-client --udp localhost 1234

# Run test scenario
./zig-out/bin/me-client localhost 1234 1

# Show help
./zig-out/bin/me-client --help
```

## Usage

### Interactive Mode (Default)

```bash
# Connect and enter interactive mode
./zig-out/bin/me-client localhost 1234
```

```
Connecting to localhost:1234...
Connected to localhost:1234 (tcp/csv)

=== Interactive Mode ===
Commands:
  buy SYMBOL PRICE QTY [ORDER_ID]
  sell SYMBOL PRICE QTY [ORDER_ID]
  cancel ORDER_ID
  flush
  quit

> buy IBM 100 50
→ BUY IBM 50@100 (order 1)
[RECV] A, IBM, 1, 1
[RECV] B, IBM, B, 100, 50

> sell IBM 100 50
→ SELL IBM 50@100 (order 2)
[RECV] A, IBM, 1, 2
[RECV] T, IBM, 1, 1, 1, 2, 100, 50
[RECV] B, IBM, B, -, -
[RECV] B, IBM, S, -, -

> flush
→ FLUSH

> quit
=== Disconnecting ===
```

### Test Scenarios

Run pre-defined test scenarios (like the C tcp_client):

```bash
# Scenario 1: Simple orders (buy + sell at different prices, no match)
./zig-out/bin/me-client localhost 1234 1

# Scenario 2: Matching trade (buy + sell at same price)
./zig-out/bin/me-client localhost 1234 2

# Scenario 3: Cancel order
./zig-out/bin/me-client localhost 1234 3
```

### UDP Mode

When the server is running in UDP mode:

```bash
# Start server in UDP mode
./build/matching_engine --udp

# Connect with UDP
./zig-out/bin/me-client --udp localhost 1234
./zig-out/bin/me-client --udp localhost 1234 1  # Run scenario 1
```

**Note:** UDP mode is fire-and-forget. The server doesn't send responses back to the client (responses go to the output publisher). Use multicast subscriber to see market data.

### Multicast Market Data

Subscribe to multicast market data feed:

```bash
# Subscribe to multicast group
./zig-out/bin/me-client subscribe 239.255.0.1 5000
```

```
Joining multicast group 239.255.0.1:5000...
Subscribed. Waiting for market data (Ctrl+C to stop)...

[RECV] A, IBM, 1, 1
[RECV] B, IBM, B, 100, 50
[RECV] T, IBM, 1, 1, 1, 2, 100, 50
...
```

### Benchmark

Run latency benchmark:

```bash
./zig-out/bin/me-client benchmark
```

## CLI Reference

```
Usage: me-client [OPTIONS] [host] [port] [scenario]

Arguments:
  host      Server host (default: 127.0.0.1)
  port      Server port (default: 1234)
  scenario  Test scenario (1, 2, 3) or 'i' for interactive (default)

Options:
  --tcp     Use TCP transport (default)
  --udp     Use UDP transport
  --binary  Use binary protocol
  --csv     Use CSV protocol (default)
  --host    Server host
  --port    Server port
  -h, --help Show this help

Commands:
  subscribe <group> <port>  Subscribe to multicast market data
  benchmark                 Run latency benchmark
```

## Interactive Commands

| Command | Description | Example |
|---------|-------------|---------|
| `buy SYMBOL PRICE QTY [OID]` | Send buy order | `buy IBM 100 50` |
| `sell SYMBOL PRICE QTY [OID]` | Send sell order | `sell IBM 100 50` |
| `cancel OID` | Cancel order by ID | `cancel 1` |
| `flush` | Cancel all orders | `flush` |
| `quit` / `exit` | Disconnect | `quit` |

## Response Messages

| Prefix | Type | Format |
|--------|------|--------|
| `A` | Ack | `A, SYMBOL, USER_ID, ORDER_ID` |
| `C` | Cancel Ack | `C, SYMBOL, USER_ID, ORDER_ID` |
| `T` | Trade | `T, SYMBOL, BUY_USER, BUY_OID, SELL_USER, SELL_OID, PRICE, QTY` |
| `B` | Top of Book | `B, SYMBOL, SIDE, PRICE, QTY` |

## Building

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Clean build artifacts
zig build clean
# or
rm -rf .zig-cache zig-out
```

## Project Structure

```
matching-engine-zig-client/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig           # CLI entry point
│   ├── protocol/
│   │   ├── types.zig      # Wire format structs
│   │   ├── binary.zig     # Binary encoder/decoder
│   │   ├── csv.zig        # CSV encoder/decoder
│   │   └── framing.zig    # TCP length-prefix framing
│   ├── transport/
│   │   ├── socket.zig     # Cross-platform socket abstraction
│   │   ├── tcp.zig        # TCP client with framing
│   │   ├── udp.zig        # UDP fire-and-forget client
│   │   └── multicast.zig  # Multicast subscriber
│   ├── client/
│   │   ├── engine_client.zig # High-level API
│   │   └── order_builder.zig # Fluent builder
│   ├── memory/
│   │   ├── pool.zig       # Fixed-size memory pools
│   │   └── ring_buffer.zig # Lock-free SPSC queues
│   └── util/
│       └── timestamp.zig  # High-resolution timing
└── docs/
    ├── ARCHITECTURE.md    # Design documentation
    └── PROTOCOL.md        # Wire protocol specification
```

## Library API

For embedding in other Zig projects:

```zig
const std = @import("std");
const me = @import("me_client");

pub fn main() !void {
    // Connect
    var client = try me.EngineClient.init(.{
        .host = "127.0.0.1",
        .port = 1234,
        .transport = .tcp,
        .protocol = .csv,
    });
    defer client.deinit();

    // Send order
    try client.sendNewOrder(1, "IBM", 100, 50, .buy, 1);

    // Receive response (TCP only)
    if (client.tcp_client) |*tcp| {
        const data = try tcp.recv();
        std.debug.print("Response: {s}\n", .{data});
    }
}
```

## Requirements

- **Zig**: 0.13.0 or later
- **C Matching Engine**: Running server to connect to
- **Network**: TCP/UDP for orders, multicast support for market data

## See Also

- [C Matching Engine](../matching-engine-c/) - The server this client connects to
- [Go Client](../matching-engine-go-client/) - Go implementation
- [Architecture](docs/ARCHITECTURE.md) - Design decisions
- [Protocol](docs/PROTOCOL.md) - Wire format specification
