# Testing Guide

Comprehensive testing documentation for the Zig matching engine client.

## Test Organization

```
tests/
├── protocol_tests.zig      # Wire format and codec tests
└── (integration tests)     # Require running server

src/
├── protocol/
│   ├── types.zig          # Inline unit tests
│   ├── binary.zig         # Inline unit tests
│   ├── csv.zig            # Inline unit tests
│   └── framing.zig        # Inline unit tests
├── transport/
│   ├── socket.zig         # Inline unit tests
│   └── multicast.zig      # Inline unit tests
├── memory/
│   ├── pool.zig           # Inline unit tests
│   └── ring_buffer.zig    # Inline unit tests
└── main.zig               # Test aggregation
```

## Running Tests

### All Tests

```bash
zig build test
```

### Protocol Tests Only

```bash
zig build test-protocol
```

### Single Module Tests

```bash
# Test a specific file
zig test src/protocol/types.zig
zig test src/protocol/binary.zig
zig test src/memory/ring_buffer.zig
```

### Verbose Output

```bash
zig build test -- --verbose
```

## Test Categories

### 1. Wire Format Tests

Verify binary struct layouts match the C server:

```zig
test "binary new order wire format" {
    const order = types.BinaryNewOrder.init(1, "IBM", 10000, 50, .buy, 1001);
    const bytes = order.asBytes();

    // Verify exact byte layout
    try std.testing.expectEqual(@as(u8, 0x4D), bytes[0]);  // Magic
    try std.testing.expectEqual(@as(u8, 'N'), bytes[1]);   // Type
    try std.testing.expectEqual(@as(usize, 30), bytes.len); // Size
}
```

### 2. Struct Size Tests

Ensure compatibility with C server structures:

```zig
test "struct sizes match C server" {
    try std.testing.expectEqual(@as(usize, 30), @sizeOf(types.BinaryNewOrder));
    try std.testing.expectEqual(@as(usize, 11), @sizeOf(types.BinaryCancel));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(types.OutputMessage));
}
```

### 3. Codec Round-Trip Tests

Verify encode/decode symmetry:

```zig
test "csv parse round-trip" {
    var buf: [256]u8 = undefined;

    // Encode
    const encoded = try csv.formatNewOrder(&buf, 1, "IBM", 10000, 50, .buy, 1001);

    // Decode (would need server response for full round-trip)
    // ...
}
```

### 4. Cache Alignment Tests

Verify structures are cache-line aligned:

```zig
test "pool cache alignment" {
    var pool = Pool(TestItem, 4).init();

    const item1 = pool.alloc().?;
    const item2 = pool.alloc().?;

    const addr1 = @intFromPtr(item1);
    const addr2 = @intFromPtr(item2);
    const diff = if (addr2 > addr1) addr2 - addr1 else addr1 - addr2;

    // Items should be at least 64 bytes apart
    try std.testing.expect(diff >= 64);
}
```

### 5. Ring Buffer Tests

Verify lock-free queue behavior:

```zig
test "ring buffer wrap around" {
    var rb = RingBuffer(u64, 4).init();

    // Fill and drain multiple times
    for (0..10) |i| {
        try std.testing.expect(rb.push(i));
        try std.testing.expectEqual(i, rb.pop().?);
    }
}
```

### 6. Error Handling Tests

Verify error conditions are handled:

```zig
test "invalid magic byte" {
    const data = [_]u8{ 0x00, 'N', 0, 0, 0, 1 };
    try std.testing.expectError(
        binary.DecodeError.InvalidMagic,
        binary.decodeOutput(&data)
    );
}
```

## Integration Testing

### With Running Server

Integration tests require the C matching engine running:

```bash
# Terminal 1: Start server
./matching_engine --tcp --port 1234

# Terminal 2: Run integration test
zig build run -- order --symbol IBM --price 10000 --qty 50 --buy
```

### Manual Testing Script

```bash
#!/bin/bash

# Start fresh
./me-client flush

# Send orders
./me-client order --symbol IBM --price 10000 --qty 100 --buy --order-id 1
./me-client order --symbol IBM --price 10050 --qty 50 --sell --order-id 2

# Should trigger trade
./me-client order --symbol IBM --price 10050 --qty 50 --buy --order-id 3

# Cancel remaining
./me-client cancel --user 1 --order-id 1

# Flush all
./me-client flush
```

### Multicast Testing

```bash
# Terminal 1: Start server with multicast
./matching_engine --tcp --multicast 239.255.0.1:5000

# Terminal 2: Subscribe
./me-client subscribe --group 239.255.0.1 --port 5000

# Terminal 3: Send orders (triggers broadcasts)
./me-client order --symbol IBM --price 10000 --qty 50 --buy
```

## Performance Testing

### Latency Benchmark

```bash
./me-client benchmark --tcp --binary
```

Output:
```
=== Results ===

Round-trip latency:
  Min:    1234 ns (1.234 µs)
  Avg:    2345 ns (2.345 µs)
  Max:    12345 ns (12.345 µs)

Throughput:
  Total time: 234 ms
  Messages:   42735/sec
```

### Protocol Comparison

```bash
# Binary (default, lowest latency)
./me-client benchmark --tcp --binary

# CSV (human-readable)
./me-client benchmark --tcp --csv

# UDP (fire-and-forget, no round-trip measurement)
./me-client benchmark --udp --binary
```

### Memory Pool Stress Test

```zig
test "pool exhaustion" {
    var pool = Pool(u64, 1000).init();

    // Allocate all
    var items: [1000]*u64 = undefined;
    for (&items) |*item| {
        item.* = pool.alloc().?;
    }

    // Should be exhausted
    try std.testing.expect(pool.alloc() == null);

    // Free all
    for (items) |item| {
        pool.free(item);
    }

    // Should be available again
    try std.testing.expect(pool.alloc() != null);
}
```

## Test Coverage

While Zig doesn't have built-in coverage, you can use:

```bash
# With kcov (Linux)
kcov --include-path=./src coverage/ ./zig-out/bin/test
```

## Writing New Tests

### Test Template

```zig
const std = @import("std");
const module = @import("../src/module.zig");

test "descriptive test name" {
    // Arrange
    const input = ...;

    // Act
    const result = module.function(input);

    // Assert
    try std.testing.expectEqual(expected, result);
}

test "error case" {
    try std.testing.expectError(
        error.ExpectedError,
        module.function(bad_input)
    );
}
```

### Compile-Time Tests

```zig
comptime {
    // These run at compile time
    if (@sizeOf(MyStruct) != 64) {
        @compileError("MyStruct must be 64 bytes");
    }
}
```

## Continuous Integration

### GitHub Actions

```yaml
name: Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.13.0
      - name: Run tests
        run: zig build test
      - name: Run protocol tests
        run: zig build test-protocol
```

### Pre-commit Hook

```bash
#!/bin/bash
# .git/hooks/pre-commit

echo "Running tests..."
zig build test || exit 1
echo "Tests passed!"
```

## Debugging Tests

### Print Debugging

```zig
test "debugging example" {
    const value = compute();
    std.debug.print("value = {}\n", .{value});  // Prints during test
    try std.testing.expectEqual(expected, value);
}
```

### GDB/LLDB

```bash
# Build with debug info
zig build

# Debug with gdb
gdb ./zig-out/bin/me-client
(gdb) break main
(gdb) run order --symbol IBM
```
