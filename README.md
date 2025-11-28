# Matching Engine Zig Client

A high-performance, cross-platform client for the C matching engine, written in Zig with a focus on low-latency trading system principles.

## Features

- **Multiple Transports**: TCP (reliable), UDP (fire-and-forget), Multicast (market data)
- **Multiple Protocols**: Binary (lowest latency) and CSV (human-readable)
- **Cross-Platform**: Linux, macOS, Windows from a single codebase
- **Zero-Allocation Hot Path**: Pre-allocated memory pools, no malloc during trading
- **Cache-Optimized**: 64-byte aligned structures prevent false sharing
- **Lock-Free Queues**: SPSC ring buffers for thread communication
- **Fluent API**: Builder pattern for ergonomic order construction

## Quick Start

```bash
# Install Zig (macOS)
brew install zig

# Build
cd matching-engine-zig-client
zig build

# Run tests
zig build test

# Show help
./zig-out/bin/me-client --help
```

## Usage

### Command Line

```bash
# Send a buy order
./zig-out/bin/me-client order --symbol IBM --price 10000 --qty 50 --buy

# Send a sell order
./zig-out/bin/me-client order --symbol AAPL --price 15000 --qty 100 --sell --order-id 1001

# Cancel an order
./zig-out/bin/me-client cancel --user 1 --order-id 1001

# Flush all orders
./zig-out/bin/me-client flush

# Subscribe to multicast market data
./zig-out/bin/me-client subscribe --group 239.255.0.1 --port 5000

# Run latency benchmark
./zig-out/bin/me-client benchmark --tcp --binary
```

### CLI Options

```
CONNECTION:
    --host <HOST>    Server host (default: 127.0.0.1)
    --port <PORT>    Server port (default: 12345)
    --tcp            Use TCP transport (default)
    --udp            Use UDP transport
    --binary         Use binary protocol (default)
    --csv            Use CSV protocol

ORDER:
    --symbol <SYM>   Symbol, max 8 chars (default: IBM)
    --price <PRICE>  Price in cents (default: 10000)
    --qty <QTY>      Quantity (default: 100)
    --buy            Buy side (default)
    --sell           Sell side
    --user <ID>      User ID (default: 1)
    --order-id <ID>  Order ID (default: 1)

MULTICAST:
    --group <ADDR>   Multicast group (default: 239.255.0.1)
```

### Library API

```zig
const std = @import("std");
const me = @import("me_client");

pub fn main() !void {
    // Connect with TCP/binary (most common)
    var client = try me.connectTcpBinary("127.0.0.1", 12345);
    defer client.deinit();

    // Method 1: Direct API
    try client.sendNewOrder(1, "IBM", 10000, 50, .buy, 1001);

    // Method 2: Fluent builder
    try me.order()
        .userId(1)
        .sym("IBM")
        .priceDollars(100.00)  // Converts to cents
        .qty(50)
        .buy()
        .orderId(1001)
        .send(&client);

    // Receive response
    const response = try client.recv();
    std.debug.print("Received: {s}\n", .{@tagName(response.msg_type)});
}
```

### Advanced Configuration

```zig
// Full configuration
var client = try me.EngineClient.init(.{
    .host = "192.168.1.100",
    .port = 9999,
    .transport = .tcp,   // or .udp
    .protocol = .binary, // or .csv
});

// Multicast subscriber
var subscriber = try me.MulticastSubscriber.join("239.255.0.1", 5000);
defer subscriber.close();

while (true) {
    const msg = try subscriber.recvMessage();
    // Process market data...
}
```

## Building

### Debug Build

```bash
zig build
```

### Release Build

```bash
zig build -Doptimize=ReleaseFast
```

### Cross-Compilation

```bash
# Build for all platforms
zig build cross

# Or specific target
zig build -Dtarget=x86_64-linux
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows
```

Output binaries are in `zig-out/bin/` (native) or `zig-out/<target>/` (cross).

## Testing

```bash
# All tests
zig build test

# Protocol tests only
zig build test-protocol

# Single file
zig test src/protocol/types.zig
```

## Project Structure

```
matching-engine-zig-client/
├── build.zig                 # Build configuration
├── src/
│   ├── main.zig              # CLI entry point & public API
│   ├── protocol/
│   │   ├── types.zig         # Wire format structs
│   │   ├── binary.zig        # Binary encoder/decoder
│   │   ├── csv.zig           # CSV encoder/decoder
│   │   └── framing.zig       # TCP length-prefix framing
│   ├── transport/
│   │   ├── socket.zig        # Cross-platform socket abstraction
│   │   ├── tcp.zig           # TCP client with framing
│   │   ├── udp.zig           # UDP fire-and-forget client
│   │   └── multicast.zig     # Multicast market data subscriber
│   ├── client/
│   │   ├── engine_client.zig # Unified high-level API
│   │   └── order_builder.zig # Fluent order builder
│   ├── memory/
│   │   ├── pool.zig          # Fixed-size memory pools
│   │   └── ring_buffer.zig   # Lock-free SPSC queues
│   └── util/
│       └── timestamp.zig     # High-resolution timing
├── tests/
│   └── protocol_tests.zig    # Wire format verification
├── examples/
│   ├── simple_order.zig      # Basic order submission
│   ├── market_subscriber.zig # Multicast data feed
│   └── benchmark.zig         # Latency measurement
└── docs/
    ├── QUICK_START.md        # Getting started guide
    ├── ARCHITECTURE.md       # Design documentation
    ├── PROTOCOL.md           # Wire protocol specification
    ├── BUILD.md              # Build instructions
    └── TESTING.md            # Testing guide
```

## Performance

Design targets based on HFT best practices:

| Metric | Target |
|--------|--------|
| Round-trip latency (TCP) | < 10 µs |
| Hot-path allocations | 0 |
| L1 cache miss rate | < 1% |
| Message throughput | 10M+ msg/sec |

Key optimizations:

- **Cache-line alignment**: All hot structures are 64-byte aligned
- **False sharing prevention**: Producer/consumer indices on separate cache lines
- **Memory pools**: Pre-allocated at startup, O(1) alloc/free
- **Packed structs**: Minimal wire format overhead
- **TCP_NODELAY**: Nagle disabled for lower latency

## Protocol Comparison

| Feature | Binary | CSV |
|---------|--------|-----|
| Latency | Lower | Higher |
| Message size | Smaller | Larger |
| Debugging | Harder | Easier |
| Tool compatibility | Custom | netcat, etc. |

Use **binary** for production, **CSV** for debugging and testing.

## Documentation

- [Quick Start Guide](docs/QUICK_START.md) - Get building in 5 minutes
- [Architecture](docs/ARCHITECTURE.md) - Design decisions and rationale
- [Protocol Specification](docs/PROTOCOL.md) - Wire format details
- [Build Guide](docs/BUILD.md) - Build options and cross-compilation
- [Testing Guide](docs/TESTING.md) - Running and writing tests

## Requirements

- **Zig**: 0.13.0 or later
- **C Matching Engine**: Running server to connect to
- **Network**: TCP/UDP for orders, multicast support for market data

## License

MIT License - see LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Run tests: `zig build test`
4. Submit a pull request

## Acknowledgments

Design principles derived from:
- NASA/JPL Power of Ten coding rules
- HFT latency optimization techniques
- Modern cache-aware data structure design
