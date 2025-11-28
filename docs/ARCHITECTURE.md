# Architecture

This document describes the architecture and design decisions of the Zig matching engine client.

## Design Philosophy

The client is designed around principles from high-frequency trading systems:

1. **Cache is King** - Data structures are sized and aligned to maximize cache efficiency
2. **Zero Allocation** - No dynamic memory allocation in the hot path
3. **Predictable Latency** - Bounded loops, no recursion, deterministic execution
4. **Compile-Time Verification** - Static assertions catch bugs before runtime

### Why Zig?

Zig provides several advantages over C/C++ for this use case:

- **No preprocessor** - `comptime` is type-safe and debuggable
- **Error unions** - Forces return value checking (no silent failures)
- **Cross-compilation** - Built-in, single command for any target
- **No hidden control flow** - No exceptions, no hidden allocations
- **Strict by default** - Integer overflow is caught, null is explicit

## Layer Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Application Layer                       │
│  ┌─────────────────┐  ┌─────────────────┐                   │
│  │   CLI (main)    │  │    Examples     │                   │
│  └────────┬────────┘  └────────┬────────┘                   │
│           │                    │                             │
│           ▼                    ▼                             │
│  ┌─────────────────────────────────────────────┐            │
│  │              Client Layer                    │            │
│  │  ┌──────────────────┐  ┌─────────────────┐  │            │
│  │  │  EngineClient    │  │  OrderBuilder   │  │            │
│  │  │  (unified API)   │  │  (fluent API)   │  │            │
│  │  └────────┬─────────┘  └────────┬────────┘  │            │
│  └───────────┼─────────────────────┼───────────┘            │
│              │                     │                         │
│              ▼                     ▼                         │
│  ┌─────────────────────────────────────────────┐            │
│  │             Transport Layer                  │            │
│  │  ┌────────┐  ┌────────┐  ┌──────────────┐   │            │
│  │  │  TCP   │  │  UDP   │  │  Multicast   │   │            │
│  │  └────┬───┘  └────┬───┘  └──────┬───────┘   │            │
│  │       └───────────┼─────────────┘           │            │
│  │                   ▼                          │            │
│  │           ┌──────────────┐                   │            │
│  │           │    Socket    │                   │            │
│  │           │ (cross-plat) │                   │            │
│  │           └──────────────┘                   │            │
│  └─────────────────────────────────────────────┘            │
│                                                              │
│  ┌─────────────────────────────────────────────┐            │
│  │             Protocol Layer                   │            │
│  │  ┌────────┐  ┌────────┐  ┌────────────────┐ │            │
│  │  │ Binary │  │  CSV   │  │    Framing     │ │            │
│  │  │ Codec  │  │ Codec  │  │ (TCP len-pfx)  │ │            │
│  │  └────────┘  └────────┘  └────────────────┘ │            │
│  │                   │                          │            │
│  │                   ▼                          │            │
│  │           ┌──────────────┐                   │            │
│  │           │    Types     │                   │            │
│  │           │ (wire fmt)   │                   │            │
│  │           └──────────────┘                   │            │
│  └─────────────────────────────────────────────┘            │
│                                                              │
│  ┌─────────────────────────────────────────────┐            │
│  │             Memory Layer                     │            │
│  │  ┌────────────────┐  ┌───────────────────┐  │            │
│  │  │   Pool         │  │   Ring Buffer     │  │            │
│  │  │ (pre-alloc)    │  │   (lock-free)     │  │            │
│  │  └────────────────┘  └───────────────────┘  │            │
│  └─────────────────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────┘
```

## Cache Optimization

### False Sharing Prevention

False sharing occurs when two threads access different variables that share a cache line. This forces cache invalidation even though there's no true data sharing.

**Problem:**
```
Cache Line (64 bytes):
┌────────────────────────────────────────────────────────────┐
│ head (8B) │ tail (8B) │ ...unused...                       │
└────────────────────────────────────────────────────────────┘
     ▲            ▲
     │            │
  Producer     Consumer
  writes       writes
     │            │
     └────────────┘
        CONTENTION!
```

**Solution:**
```
Cache Line 1 (64 bytes):        Cache Line 2 (64 bytes):
┌──────────────────────────┐    ┌──────────────────────────┐
│ head (8B) │ padding (56B)│    │ tail (8B) │ padding (56B)│
└──────────────────────────┘    └──────────────────────────┘
     ▲                               ▲
     │                               │
  Producer                        Consumer
  (isolated)                      (isolated)
```

Implementation in `ring_buffer.zig`:
```zig
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return struct {
        // Producer cache line
        head: usize align(64) = 0,
        _pad_head: [56]u8 = undefined,

        // Consumer cache line  
        tail: usize align(64) = 0,
        _pad_tail: [56]u8 = undefined,

        // Data buffer
        buffer: [capacity]T = undefined,
    };
}
```

### Structure Alignment

All hot-path structures are sized to cache-line boundaries:

```zig
pub const OutputMessage = struct {
    msg_type: OutputMsgType,        // 1 byte
    symbol: [8]u8,                  // 8 bytes
    symbol_len: u8,                 // 1 byte
    user_id: u32,                   // 4 bytes
    order_id: u32,                  // 4 bytes
    // ... more fields ...
    _padding: [CACHE_LINE_SIZE - 49]u8, // Pad to 64 bytes

    comptime {
        if (@sizeOf(OutputMessage) != 64) {
            @compileError("OutputMessage must be 64 bytes");
        }
    }
};
```

### Memory Pool Design

```
Pool Layout:
┌──────────────────────────────────────────────────────────────┐
│                        Pool Struct                           │
├──────────────────────────────────────────────────────────────┤
│  items[0]: │ data (T) │ padding to 64B │   <- Cache line 0   │
│  items[1]: │ data (T) │ padding to 64B │   <- Cache line 1   │
│  items[2]: │ data (T) │ padding to 64B │   <- Cache line 2   │
│  ...                                                         │
├──────────────────────────────────────────────────────────────┤
│  free_stack: [capacity]u32  <- Indices of free items         │
│  free_count: u32            <- Stack pointer                 │
├──────────────────────────────────────────────────────────────┤
│  Statistics: allocations, deallocations, peak_usage          │
└──────────────────────────────────────────────────────────────┘

Allocation: O(1)
  1. Check free_count > 0
  2. Decrement free_count
  3. Return items[free_stack[free_count]]

Deallocation: O(1)
  1. Calculate index from pointer
  2. free_stack[free_count] = index
  3. Increment free_count
```

## Wire Format

### Binary Protocol Structure

All binary messages start with a 2-byte header:

```
┌─────────┬──────────┬─────────────────────┐
│ Magic   │ Type     │ Payload...          │
│ (0x4D)  │ (N/C/F)  │                     │
│ 1 byte  │ 1 byte   │ variable            │
└─────────┴──────────┴─────────────────────┘
```

### New Order (30 bytes)

```
Offset  Size  Field           Encoding
──────  ────  ─────           ────────
0       1     magic           0x4D
1       1     msg_type        'N'
2       4     user_id         big-endian u32
6       8     symbol          null-padded ASCII
14      4     price           big-endian u32 (cents)
18      4     quantity        big-endian u32
22      1     side            'B' or 'S'
23      4     user_order_id   big-endian u32
27      3     padding         0x00
──────
Total: 30 bytes
```

### TCP Framing

TCP is a stream protocol with no message boundaries. We use length-prefix framing:

```
┌────────────────────┬─────────────────────────────────────┐
│ Length (4B BE)     │ Payload (N bytes)                   │
└────────────────────┴─────────────────────────────────────┘

Example:
┌──────────────┬─────────────────────────────────────────────┐
│ 00 00 00 1E  │ 4D 4E 00 00 00 01 49 42 4D 00 00 00 00 00...│
│ (length=30)  │ (BinaryNewOrder)                            │
└──────────────┴─────────────────────────────────────────────┘
```

Frame reader state machine:

```
                    ┌─────────────────┐
                    │     EMPTY       │
                    └────────┬────────┘
                             │ recv()
                             ▼
                    ┌─────────────────┐
         ┌─────────│ READING_HEADER  │◄────────┐
         │         └────────┬────────┘         │
         │                  │                  │
         │ < 4 bytes        │ >= 4 bytes       │
         │                  ▼                  │
         │         ┌─────────────────┐         │
         │         │ READING_PAYLOAD │         │
         │         └────────┬────────┘         │
         │                  │                  │
         │ < len bytes      │ >= len bytes     │
         │                  ▼                  │
         │         ┌─────────────────┐         │
         └────────►│ MESSAGE_READY   ├─────────┘
                   └─────────────────┘
                             │
                             ▼
                      Return message
```

## Transport Layer

### TCP Client

```
┌────────────────────────────────────────────────────────────┐
│                      TcpClient                              │
├────────────────────────────────────────────────────────────┤
│  sock: TcpSocket           <- OS socket handle              │
│  frame_reader: FrameReader <- Handles partial reads         │
│  send_buf: [16KB]u8        <- Framing buffer                │
├────────────────────────────────────────────────────────────┤
│  connect(host, port)       -> Establish connection          │
│  send(data)                -> Frame and send                │
│  recv()                    -> Block until complete msg      │
│  close()                   -> Cleanup                       │
└────────────────────────────────────────────────────────────┘
```

### UDP Client

```
┌────────────────────────────────────────────────────────────┐
│                      UdpClient                              │
├────────────────────────────────────────────────────────────┤
│  sock: UdpSocket           <- OS socket handle              │
│  recv_buf: [1500]u8        <- MTU-sized buffer              │
├────────────────────────────────────────────────────────────┤
│  init(host, port)          -> Set target address            │
│  send(data)                -> Fire and forget               │
│  recv()                    -> Optional receive              │
│  close()                   -> Cleanup                       │
└────────────────────────────────────────────────────────────┘

Note: No framing needed - UDP preserves message boundaries
```

### Multicast Subscriber

```
┌────────────────────────────────────────────────────────────┐
│                  MulticastSubscriber                        │
├────────────────────────────────────────────────────────────┤
│  sock: UdpSocket           <- Bound to multicast group      │
│  recv_buf: [1500]u8        <- MTU-sized buffer              │
│  packets_received: u64     <- Statistics                    │
│  parse_errors: u64         <- Statistics                    │
├────────────────────────────────────────────────────────────┤
│  join(group, port)         -> Bind + IP_ADD_MEMBERSHIP      │
│  recvMessage()             -> Parse binary or CSV           │
│  recvRaw()                 -> Raw bytes                     │
│  getStats()                -> Monitoring data               │
│  close()                   -> Leave group + cleanup         │
└────────────────────────────────────────────────────────────┘
```

## Thread Safety

### Single-Threaded Model

The client is designed for single-threaded use within one thread:

```
┌─────────────────────────────────────────────────────────────┐
│                    Trading Thread                            │
│                                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │ Strategy │───►│  Client  │───►│ Network  │              │
│  │  Logic   │    │   API    │    │   I/O    │              │
│  └──────────┘    └──────────┘    └──────────┘              │
│       ▲                               │                      │
│       │         ┌──────────┐          │                      │
│       └─────────│ Response │◄─────────┘                      │
│                 │ Handler  │                                 │
│                 └──────────┘                                 │
└─────────────────────────────────────────────────────────────┘
```

### Multi-Threaded Communication

For multi-threaded applications, use the ring buffer:

```
┌────────────────────┐           ┌────────────────────┐
│   Producer Thread  │           │  Consumer Thread   │
│                    │           │                    │
│  while (running) { │           │  while (running) { │
│    msg = generate()│           │    if (rb.pop()) { │
│    rb.push(msg)    │──────────►│      process(msg)  │
│  }                 │           │    }               │
│                    │           │  }                 │
└────────────────────┘           └────────────────────┘
                    │
                    ▼
        ┌───────────────────────────┐
        │      Ring Buffer          │
        │  ┌──────┬──────┬──────┐  │
        │  │ head │ pad  │ tail │  │  <- Separate cache lines
        │  └──────┴──────┴──────┘  │
        │  ┌──────────────────────┐│
        │  │ data[0..capacity]    ││
        │  └──────────────────────┘│
        └───────────────────────────┘
```

## Error Handling

Zig's error unions ensure all errors are handled:

```zig
// Errors bubble up automatically
pub fn sendOrder(client: *Client) !void {
    const data = try encodeOrder();   // Error propagates
    try client.send(data);            // Error propagates
}

// Explicit handling when needed
const result = client.recv() catch |err| switch (err) {
    error.Timeout => return handleTimeout(),
    error.ConnectionClosed => return reconnect(),
    else => return err,
};
```

Error categories:

| Layer | Error Types |
|-------|-------------|
| Protocol | InvalidMagic, UnknownMessageType, MessageTooShort |
| Transport | ConnectFailed, SendFailed, RecvFailed, Timeout |
| Framing | MessageTooLarge, IncompleteHeader |
| Builder | MissingUserId, MissingSymbol, InvalidQuantity |

## Compile-Time Verification

Critical invariants are checked at compile time:

```zig
// Struct sizes must match C server
comptime {
    if (@sizeOf(BinaryNewOrder) != 30) {
        @compileError("BinaryNewOrder must be exactly 30 bytes");
    }
}

// Ring buffer capacity must be power of 2
comptime {
    if (capacity & (capacity - 1) != 0) {
        @compileError("Capacity must be power of 2");
    }
}

// Cache alignment verification
comptime {
    if (@sizeOf(OutputMessage) != CACHE_LINE_SIZE) {
        @compileError("OutputMessage must be cache-line sized");
    }
}
```

## Future Enhancements

Potential improvements for production use:

1. **Kernel Bypass** - DPDK/io_uring for lower latency
2. **Hardware Timestamps** - NIC timestamping for accurate latency measurement
3. **Connection Pooling** - Multiple connections for throughput
4. **Compression** - LZ4 for high-bandwidth scenarios
5. **TLS Support** - Encrypted connections
6. **Metrics Export** - Prometheus/StatsD integration
7. **Hot Reload** - Configuration changes without restart
