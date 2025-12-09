# Zig Matching Engine Client

A high-performance, safety-critical client for the Zig Matching Engine, implementing NASA JPL's Power of Ten coding standards for maximum reliability.

## Features

- **Multi-Protocol Support**: Binary (18-byte fixed) and CSV text protocols
- **Multi-Transport Support**: TCP (with length-prefix framing) and UDP
- **Power of Ten Compliant**: All code follows NASA JPL safety-critical coding rules
- **Zero Dynamic Allocation**: Fixed-size buffers and memory pools throughout
- **Interactive & Batch Modes**: REPL for manual testing, scenarios for stress testing
- **Comprehensive Scenarios**: From simple orders to 100M+ trade stress tests

## Quick Start

```bash
# Build (release mode)
make build

# Run interactive mode (auto-detects protocol)
make interactive

# Run simple order scenario
make scenario-1

# Run 10K trade stress test
make match-10k
```

## Installation

### Prerequisites

- Zig 0.13.0 or later
- A running Zig Matching Engine server

### Building

```bash
# Debug build
zig build

# Release build (optimized)
zig build -Doptimize=ReleaseFast

# Run tests
zig build test
```

## Usage

### Command Line

```bash
./zig-out/bin/me-client [OPTIONS] <HOST> <PORT> <SCENARIO>
```

**Options:**
- `--tcp` - Use TCP transport (default)
- `--udp` - Use UDP transport
- `--binary` - Use binary protocol (default)
- `--csv` - Use CSV text protocol

**Scenarios:**
| ID | Name | Description |
|----|------|-------------|
| `i` | Interactive | REPL mode for manual order entry |
| `1` | Simple Orders | Basic buy/sell with responses |
| `2` | Order Cancel | Submit and cancel orders |
| `3` | Multiple Symbols | Orders across IBM, AAPL, MSFT |
| `4` | Price Levels | Orders at multiple price points |
| `5` | Partial Fills | Large orders matched incrementally |
| `20` | Match 1K | 1,000 matching trade pairs |
| `21` | Match 10K | 10,000 matching trade pairs |
| `22` | Match 100K | 100,000 matching trade pairs |
| `23` | Match 1M | 1,000,000 matching trade pairs |
| `30` | Dual Proc 10K | 10K trades across both processors |
| `31` | Dual Proc 100K | 100K trades across both processors |

### Interactive Mode

```
> buy IBM 100.50 100
→ BUY IBM 100.50@100 (order 1)
[RECV] A, IBM, 1, 1

> sell IBM 100.50 100
→ SELL IBM 100.50@100 (order 2)
[RECV] A, IBM, 1, 2
[RECV] T, IBM, 100.50, 100, 1, 2

> cancel IBM 1
→ CANCEL IBM order 1

> quit
```

### Makefile Targets

```bash
make build          # Build release binary
make debug          # Build debug binary
make test           # Run all tests
make clean          # Clean build artifacts

# Scenarios
make interactive    # Interactive REPL
make scenario-1     # Simple orders
make scenario-2     # Order cancellation
make scenario-3     # Multiple symbols
make scenario-4     # Price levels
make scenario-5     # Partial fills

# Stress Tests
make match-1k       # 1K trades (2K orders)
make match-10k      # 10K trades (20K orders)
make match-100k     # 100K trades (200K orders)
make match-1m       # 1M trades (2M orders)

# Dual Processor Tests
make dual-10k       # 10K trades split across processors
make dual-100k      # 100K trades split across processors
```

## Architecture

The client is organized into clean, modular layers:

```
src/
├── main.zig              # Entry point, CLI parsing
├── scenarios.zig         # Test scenarios and stress tests
├── protocol/
│   ├── types.zig         # Message types, constants
│   ├── binary.zig        # Binary protocol codec
│   ├── csv.zig           # CSV protocol codec
│   └── framing.zig       # TCP length-prefix framing
├── transport/
│   ├── tcp.zig           # TCP client with framing
│   ├── udp.zig           # UDP client
│   ├── socket.zig        # Low-level socket operations
│   └── multicast.zig     # Multicast subscriber
├── client/
│   ├── engine_client.zig # High-level client API
│   └── order_builder.zig # Fluent order construction
├── memory/
│   ├── pool.zig          # Fixed-size memory pool
│   └── ring_buffer.zig   # Lock-free ring buffer
└── util/
    └── timestamp.zig     # High-resolution timing
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed design documentation.

## Protocol

The client supports two wire protocols:

### Binary Protocol (Default)

Fixed 26-byte input messages, 18-24 byte output messages. Optimal for high-throughput scenarios.

### CSV Protocol

Human-readable text format. Useful for debugging and manual testing.

See [PROTOCOL.md](PROTOCOL.md) for complete protocol specification.

## Power of Ten Compliance

This codebase follows NASA JPL's Power of Ten rules for safety-critical software:

1. ✅ **Simple Control Flow** - No goto, setjmp, or recursion
2. ✅ **Fixed Loop Bounds** - All loops have compile-time or explicit bounds
3. ✅ **No Dynamic Allocation** - After initialization, no heap allocation
4. ✅ **Short Functions** - All functions ≤60 lines
5. ✅ **Assertions** - Minimum 2 assertions per function
6. ✅ **Minimal Scope** - Variables declared at smallest scope
7. ✅ **Check Return Values** - All returns checked, errors propagated

See [ARCHITECTURE.md](ARCHITECTURE.md) for compliance details per file.

## Performance

Typical performance on a modern Linux system:

| Scenario | Throughput | Latency |
|----------|------------|---------|
| 10K trades | ~1.6K trades/sec | <1ms avg |
| Sustained | ~2K trades/sec | <2ms avg |

*Note: Current settings prioritize reliability over raw speed. Throughput can be increased by adjusting batch sizes and delays in `scenarios.zig`.*

## Testing

```bash
# Run all unit tests
zig build test

# Run specific test file
zig test src/protocol/binary.zig

# Run with verbose output
zig build test -- --verbose
```

## Troubleshooting

### Connection Refused
Ensure the matching engine server is running:
```bash
cd ../matching-engine-zig
make run-threaded
```

### Missing Responses
The client may disconnect before receiving all responses. Try:
- Smaller batch sizes in stress tests
- Longer drain timeouts
- Check server logs for backpressure warnings

### Protocol Mismatch
If you see "oversized frame" errors on the server, ensure both client and server agree on framing mode. The TCP transport uses 4-byte length-prefix framing by default.

## License

MIT License - See LICENSE file for details.

## Related Projects

- [Zig Matching Engine](../matching-engine-zig) - The server this client connects to
- [C Matching Engine](../matching-engine) - Original C implementation
