# Protocol Specification

This document specifies the wire protocols used to communicate with the matching engine.

## Overview

The matching engine supports two protocols:

| Protocol | Format | Use Case |
|----------|--------|----------|
| Binary | Packed structs, big-endian | Production (lowest latency) |
| CSV | Text, comma-separated | Development/debugging |

Both protocols support the same message types:

**Input (Client → Server):**
- New Order (`N`)
- Cancel Order (`C`)
- Flush All (`F`)

**Output (Server → Client):**
- Acknowledgment (`A`)
- Cancel Acknowledgment (`X`)
- Trade (`T`)
- Top of Book (`B`)

## Transport Framing

### TCP

TCP requires explicit message framing since it's a stream protocol. We use a 4-byte big-endian length prefix:

```
┌─────────────────────┬────────────────────────────────────────┐
│ Length (4 bytes BE) │ Message Payload (N bytes)              │
└─────────────────────┴────────────────────────────────────────┘
```

Example (30-byte new order):
```
00 00 00 1E  4D 4E 00 00 00 01 ...
└─────────┘  └─────────────────────┘
 length=30      message payload
```

Maximum message size: 16,384 bytes (16 KB)

### UDP

No framing needed. Each UDP datagram is one complete message. Maximum message size is limited by MTU (typically 1500 bytes).

### Multicast

Same as UDP. The server broadcasts to a multicast group (e.g., `239.255.0.1:5000`). Clients join the group to receive market data.

## Binary Protocol

### Common Header

All binary messages start with:

```
Offset  Size  Field    Value
──────  ────  ─────    ─────
0       1     magic    0x4D ('M')
1       1     type     Message type character
```

### Input Messages

#### New Order (Type: 'N', Size: 30 bytes)

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'N' (0x4E)
2       4     user_id        u32 BE      User identifier
6       8     symbol         char[8]     Symbol, null-padded
14      4     price          u32 BE      Price in cents
18      4     quantity       u32 BE      Order quantity
22      1     side           u8          'B' (buy) or 'S' (sell)
23      4     user_order_id  u32 BE      Client order ID
27      3     _padding       u8[3]       Reserved (0x00)
──────
Total: 30 bytes
```

**Example:** Buy 100 shares of IBM at $150.00, user 1, order 1001

```
Hex dump:
4D 4E                         # magic='M', type='N'
00 00 00 01                   # user_id=1
49 42 4D 00 00 00 00 00       # symbol="IBM\0\0\0\0\0"
00 00 3A 98                   # price=15000 ($150.00)
00 00 00 64                   # quantity=100
42                            # side='B' (buy)
00 00 03 E9                   # user_order_id=1001
00 00 00                      # padding
```

#### Cancel Order (Type: 'C', Size: 11 bytes)

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'C' (0x43)
2       4     user_id        u32 BE      User identifier
6       4     user_order_id  u32 BE      Order to cancel
10      1     _padding       u8          Reserved (0x00)
──────
Total: 11 bytes
```

**Example:** Cancel order 1001 for user 1

```
Hex dump:
4D 43                         # magic='M', type='C'
00 00 00 01                   # user_id=1
00 00 03 E9                   # user_order_id=1001
00                            # padding
```

#### Flush All Orders (Type: 'F', Size: 2 bytes)

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'F' (0x46)
──────
Total: 2 bytes
```

**Example:** Flush all orders

```
Hex dump:
4D 46                         # magic='M', type='F'
```

### Output Messages

#### Acknowledgment (Type: 'A', Size: 19 bytes)

Confirms order was accepted.

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'A' (0x41)
2       8     symbol         char[8]     Symbol, null-padded
10      4     user_id        u32 BE      User identifier
14      4     user_order_id  u32 BE      Client order ID
18      1     _padding       u8          Reserved (0x00)
──────
Total: 19 bytes
```

#### Cancel Acknowledgment (Type: 'X', Size: 19 bytes)

Confirms order was cancelled. Same layout as Acknowledgment.

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'X' (0x58)
2       8     symbol         char[8]     Symbol, null-padded
10      4     user_id        u32 BE      User identifier
14      4     user_order_id  u32 BE      Cancelled order ID
18      1     _padding       u8          Reserved (0x00)
──────
Total: 19 bytes
```

#### Trade (Type: 'T', Size: 34 bytes)

Reports an executed trade between two orders.

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'T' (0x54)
2       8     symbol         char[8]     Symbol, null-padded
10      4     buy_user_id    u32 BE      Buyer's user ID
14      4     buy_order_id   u32 BE      Buyer's order ID
18      4     sell_user_id   u32 BE      Seller's user ID
22      4     sell_order_id  u32 BE      Seller's order ID
26      4     price          u32 BE      Trade price in cents
30      4     quantity       u32 BE      Trade quantity
──────
Total: 34 bytes
```

**Example:** Trade 50 shares at $150.00

```
Hex dump:
4D 54                         # magic='M', type='T'
49 42 4D 00 00 00 00 00       # symbol="IBM"
00 00 00 01                   # buy_user_id=1
00 00 03 E9                   # buy_order_id=1001
00 00 00 02                   # sell_user_id=2
00 00 07 D1                   # sell_order_id=2001
00 00 3A 98                   # price=15000 ($150.00)
00 00 00 32                   # quantity=50
```

#### Top of Book (Type: 'B', Size: 20 bytes)

[OReports the best bid or ask price after a book change.

```
Offset  Size  Field          Type        Description
──────  ────  ─────          ────        ───────────
0       1     magic          u8          0x4D
1       1     msg_type       u8          'B' (0x42)
2       8     symbol         char[8]     Symbol, null-padded
10      1     side           u8          'B' (bid) or 'S' (ask)
11      1     _padding       u8          Reserved (0x00)
12      4     price          u32 BE      Best price (0 if empty)
16      4     quantity       u32 BE      Total quantity (0 if empty)
──────
Total: 20 bytes
```

**Empty book:** When a side has no orders, price=0 and quantity=0.

## CSV Protocol

Human-readable text format. Each message is one line terminated by `\n`.

### Input Messages

#### New Order

```
N, <user_id>, <symbol>, <price>, <quantity>, <side>, <order_id>
```

- `user_id`: Positive integer
- `symbol`: Up to 8 characters
- `price`: Price in cents
- `quantity`: Positive integer
- `side`: `B` (buy) or `S` (sell)
- `order_id`: Positive integer

**Example:**
```
N, 1, IBM, 15000, 100, B, 1001
```

#### Cancel Order

```
C, <user_id>, <order_id>
```

**Example:**
```
C, 1, 1001
```

#### Flush All

```
F
```

### Output Messages

#### Acknowledgment

```
A, <symbol>, <user_id>, <order_id>
```

**Example:**
```
A, IBM, 1, 1001
```

#### Cancel Acknowledgment

```
C, <symbol>, <user_id>, <order_id>
```

**Example:**
```
C, IBM, 1, 1001
```

#### Trade

```
T, <symbol>, <buy_user>, <buy_order>, <sell_user>, <sell_order>, <price>, <qty>
```

**Example:**
```
T, IBM, 1, 1001, 2, 2001, 15000, 50
```

#### Top of Book

```
B, <symbol>, <side>, <price>, <quantity>
```

Empty book uses `-` for price and quantity:
```
B, IBM, B, -, -
```

**Example (with orders):**
```
B, IBM, B, 15000, 100
```

## Protocol Detection

The server auto-detects protocol based on the first byte:

| First Byte | Protocol |
|------------|----------|
| `0x4D` ('M') | Binary |
| Any other | CSV |

The client can also auto-detect responses using the same logic.

## Byte Order

All multi-byte integers in the binary protocol are **big-endian** (network byte order).

```zig
// Encoding
const wire_value = std.mem.nativeToBig(u32, native_value);

// Decoding
const native_value = std.mem.bigToNative(u32, wire_value);
```

## Symbol Encoding

Symbols are fixed 8-byte fields:

- ASCII characters only
- Unused bytes filled with `0x00` (null)
- No null terminator if exactly 8 characters

**Examples:**
| Symbol | Encoding |
|--------|----------|
| IBM | `49 42 4D 00 00 00 00 00` |
| AAPL | `41 41 50 4C 00 00 00 00` |
| GOOGL | `47 4F 4F 47 4C 00 00 00` |
| TSLA | `54 53 4C 41 00 00 00 00` |

## Price Encoding

Prices are encoded as unsigned 32-bit integers representing **cents** (1/100 of a dollar):

| Price | Encoded Value |
|-------|---------------|
| $100.00 | 10000 |
| $150.50 | 15050 |
| $0.01 | 1 |
| $42,949.67 | 4294967 (max practical) |

Maximum representable: $42,949,672.95 (2^32 - 1 cents)

## Side Encoding

| Side | Binary | CSV |
|------|--------|-----|
| Buy | `0x42` ('B') | `B` |
| Sell | `0x53` ('S') | `S` |

## Message Sequence

Typical order lifecycle:

```
Client                     Server
  │                          │
  │──── New Order ──────────►│
  │                          │
  │◄──── Acknowledgment ─────│
  │                          │
  │                          │  (matching occurs)
  │                          │
  │◄──── Trade ──────────────│
  │                          │
  │◄──── Top of Book ────────│
  │                          │
```

Cancel lifecycle:

```
Client                     Server
  │                          │
  │──── Cancel Order ───────►│
  │                          │
  │◄──── Cancel Ack ─────────│
  │                          │
  │◄──── Top of Book ────────│
  │                          │
```

## Error Handling

The server does not send explicit error messages. Invalid messages are silently dropped. The client should:

1. Use timeouts to detect unacknowledged orders
2. Implement sequence numbers at the application layer if needed
3. Log and monitor for dropped messages

## Multicast Groups

Market data is broadcast to multicast groups in the range `224.0.0.0` - `239.255.255.255`.

Default group: `239.255.0.1:5000`

Clients must:
1. Create a UDP socket
2. Bind to the multicast port
3. Join the multicast group via `IP_ADD_MEMBERSHIP`

## Compatibility

This protocol is compatible with:

- C matching engine (reference implementation)
- Go client
- This Zig client

All implementations must use:
- Big-endian byte order for binary protocol
- Exact struct sizes as specified
- Same message type characters
