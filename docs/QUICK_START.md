# Quick Start Guide

Get up and running with the Zig Matching Engine Client in under 5 minutes.

## Prerequisites

- **Zig 0.13.0+** - [Install Zig](https://ziglang.org/download/)
- **Zig Matching Engine** - The server to connect to

## Step 1: Start the Server

In a terminal, start the matching engine:

```bash
cd ~/matching-engine-zig
make run-threaded
```

You should see:
```
╔════════════════════════════════════════════╗
║     Zig Matching Engine v0.1.0             ║
╠════════════════════════════════════════════╣
║  TCP:       0.0.0.0:1234                   ║
║  UDP:       0.0.0.0:1235                   ║
║  Multicast: 239.255.0.1:1236               ║
╚════════════════════════════════════════════╝
```

## Step 2: Build the Client

In another terminal:

```bash
cd ~/matching-engine-zig-client
make build
```

## Step 3: Test Connection

Run the simple orders scenario:

```bash
make scenario-1
```

Expected output:
```
Connecting to 127.0.0.1:1234...
Connected (tcp/binary)
=== Scenario 1: Simple Orders ===
[SEND] N, 1, IBM, 10000, 100, B, 1
[RECV] A, IBM, 1, 1
[RECV] B, IBM, B, 10000, 100, 0, 0
[SEND] N, 1, IBM, 10000, 100, S, 2
[RECV] A, IBM, 1, 2
[RECV] T, IBM, 10000, 100, 1, 2
[RECV] B, IBM, S, 0, 0, 0, 0
=== Disconnecting ===
```

🎉 **Success!** The client is working.

## Step 4: Interactive Mode

Try manual order entry:

```bash
make interactive
```

Enter commands at the prompt:

```
> buy IBM 100.00 50
→ BUY IBM 100.00@50 (order 1)
[RECV] A, IBM, 1, 1
[RECV] B, IBM, B, 10000, 50, 0, 0

> sell IBM 100.00 50
→ SELL IBM 100.00@50 (order 2)
[RECV] A, IBM, 1, 2
[RECV] T, IBM, 10000, 50, 1, 2
[RECV] B, IBM, S, 0, 0, 0, 0

> quit
```

## Step 5: Run Stress Tests

Test with increasing load:

```bash
# 1,000 trades
make match-1k

# 10,000 trades (recommended first stress test)
make match-10k
```

Expected output for match-10k:
```
=== Matching Stress Test: 10000 Trades ===
Target: 10K trades (20K orders)
  10% | 1001 pairs | 585 ms | 1711 trades/sec
  20% | 2001 pairs | 1210 ms | 1653 trades/sec
  ...
=== Validation ===
ACKs:            20000/20000 ✓ PASS
Trades:          10000/10000 ✓ PASS
*** TEST PASSED ***
```

## Common Commands

### Interactive Mode

| Command | Description |
|---------|-------------|
| `buy SYMBOL PRICE QTY` | Submit buy order |
| `sell SYMBOL PRICE QTY` | Submit sell order |
| `cancel SYMBOL ORDER_ID` | Cancel order |
| `flush` | Flush server buffers |
| `quit` | Exit |

### Makefile Targets

| Target | Description |
|--------|-------------|
| `make build` | Build release binary |
| `make test` | Run unit tests |
| `make interactive` | Interactive mode |
| `make scenario-N` | Run scenario N (1-5) |
| `make match-1k` | 1K trade stress test |
| `make match-10k` | 10K trade stress test |

## Troubleshooting

### "Connection refused"

The server isn't running. Start it with:
```bash
cd ~/matching-engine-zig && make run-threaded
```

### "Missing responses" in stress tests

The client may disconnect before receiving all responses. This is a timing issue with aggressive test parameters. The 10K test should pass reliably; larger tests may need parameter tuning.

### Build errors

Ensure you have Zig 0.13.0 or later:
```bash
zig version
```

### Server crashes with "oversized frame"

Protocol mismatch. Ensure both client and server use TCP framing. The client defaults to framing mode, which matches the server.

## Next Steps

1. **Read the Protocol**: See [PROTOCOL.md](PROTOCOL.md) for wire format details
2. **Understand the Architecture**: See [ARCHITECTURE.md](ARCHITECTURE.md) for design decisions
3. **Run More Scenarios**: Try scenarios 2-5 for different order flows
4. **Dual Processor Tests**: Try `make dual-10k` to test both server processors

## Configuration

### Using UDP Instead of TCP

```bash
./zig-out/bin/me-client --udp 127.0.0.1 1235 1
```

Note: UDP uses port 1235 (not 1234).

### Using CSV Protocol

```bash
./zig-out/bin/me-client --csv 127.0.0.1 1234 1
```

CSV is human-readable but slower than binary.

### Custom Host/Port

```bash
./zig-out/bin/me-client 192.168.1.100 5000 1
```

## Getting Help

- Check server logs for error messages
- Review [ARCHITECTURE.md](ARCHITECTURE.md) for design details
- Submit issues on GitHub
