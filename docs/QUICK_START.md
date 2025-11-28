# Quick Start Guide

Get the Zig matching engine client building and running step by step.

## Prerequisites

### Install Zig

**macOS:**
```bash
brew install zig
```

**Linux (Ubuntu/Debian):**
```bash
# Download latest from https://ziglang.org/download/
wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
tar -xf zig-linux-x86_64-0.13.0.tar.xz
export PATH=$PATH:$(pwd)/zig-linux-x86_64-0.13.0
```

**Windows:**
```powershell
# Download from https://ziglang.org/download/
# Or use scoop:
scoop install zig
```

**Verify installation:**
```bash
zig version
# Expected: 0.13.0 or similar
```

## Step 1: Build

```bash
cd matching-engine-zig-client

# Debug build
zig build

# If successful, binary is at:
ls -la zig-out/bin/me-client
```

### Common Build Errors

**Error: "file not found" for imports**
- Check that all source files exist in the correct paths
- Verify the directory structure matches what's expected

**Error: struct size mismatch (comptime error)**
- The `comptime` blocks verify struct sizes match the C server
- If sizes don't match, adjust padding fields

**Error: "expected type" or similar type errors**
- Zig is very strict about types
- Check that all `@intCast`, `@ptrCast` are correct

## Step 2: Run Tests

```bash
# Run all inline tests
zig build test

# Run protocol-specific tests
zig build test-protocol

# Test a single file directly
zig test src/protocol/types.zig
```

### Test Output

Successful output looks like:
```
All 42 tests passed.
```

If tests fail, you'll see which specific test and assertion failed.

## Step 3: Try the CLI

```bash
# Show help
./zig-out/bin/me-client --help

# Or run directly through build system
zig build run -- --help
```

Expected output:
```
Matching Engine Zig Client

USAGE:
    me-client [OPTIONS] <COMMAND>

COMMANDS:
    order       Send a new order
    cancel      Cancel an order
    flush       Cancel all orders
    subscribe   Subscribe to multicast market data
    benchmark   Run latency benchmark
...
```

## Step 4: Connect to Server

First, make sure your C matching engine is running:

```bash
# In another terminal, start the matching engine
./matching_engine --tcp --port 1234
```

Then connect with the Zig client:

```bash
# Send an order
./zig-out/bin/me-client order --symbol IBM --price 10000 --qty 50 --buy --order-id 1

# Expected output:
# Connecting to 127.0.0.1:1234 (tcp/binary)...
# Sending order: buy IBM 50@10000 (user=1, oid=1)
# Order sent.
# Waiting for response...
# Response: ACK: IBM user=1 order=1
```

## Step 5: Test Multicast (Optional)

Start server with multicast:
```bash
./matching_engine --tcp --port 1234 --multicast 239.255.0.1:5000
```

Subscribe:
```bash
./zig-out/bin/me-client subscribe --group 239.255.0.1 --port 5000
```

## Troubleshooting

### "Connection refused"

The matching engine server isn't running or wrong port:
```bash
# Check if server is listening
netstat -an | grep 1234
# or
lsof -i :1234
```

### Struct size assertion failed

If you see a comptime error like:
```
error: comptime: BinaryNewOrder must be exactly 30 bytes
```

This means the struct layout doesn't match. Check:
1. Field order in the struct
2. `align(1)` on integer fields
3. Padding bytes

### Socket errors on Windows

Windows socket behavior differs slightly. Ensure:
- `linkLibC()` is called in build.zig
- Timeouts use milliseconds not timeval

### Cross-compilation issues

```bash
# Explicitly specify target
zig build -Dtarget=x86_64-linux-gnu

# Or use musl for static linking
zig build -Dtarget=x86_64-linux-musl
```

## File Checklist

Make sure all these files exist:

```
matching-engine-zig-client/
├── build.zig                          ✓
├── src/
│   ├── main.zig                       ✓
│   ├── protocol/
│   │   ├── types.zig                  ✓
│   │   ├── binary.zig                 ✓
│   │   ├── csv.zig                    ✓
│   │   └── framing.zig                ✓
│   ├── transport/
│   │   ├── socket.zig                 ✓
│   │   ├── tcp.zig                    ✓
│   │   ├── udp.zig                    ✓
│   │   └── multicast.zig              ✓
│   ├── client/
│   │   ├── engine_client.zig          ✓
│   │   └── order_builder.zig          ✓
│   ├── memory/
│   │   ├── pool.zig                   ✓
│   │   └── ring_buffer.zig            ✓
│   └── util/
│       └── timestamp.zig              ✓
└── tests/
    └── protocol_tests.zig             ✓
```

## Next Steps

Once building:

1. **Run the benchmark**: `./zig-out/bin/me-client benchmark`
2. **Test with CSV protocol**: Add `--csv` flag
3. **Try UDP mode**: Add `--udp` flag
4. **Cross-compile**: `zig build -Dtarget=x86_64-windows`

## Getting Help

If you hit a compile error:

1. Copy the exact error message
2. Note which file and line number
3. Check if it's a known Zig version issue (0.12 vs 0.13 syntax changes)

Common Zig 0.13 changes from 0.12:
- `@intCast` now requires explicit target type via inference
- `std.mem.zeroes` replaced by `.{0} ** N` syntax
- Some std.posix paths changed
