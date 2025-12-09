# Protocol Specification

This document describes the wire protocols supported by the Zig Matching Engine Client.

## Overview

The client supports two protocols:

| Protocol | Format | Message Size | Best For |
|----------|--------|--------------|----------|
| Binary | Fixed-width binary | 26 bytes in, 18-40 bytes out | High throughput |
| CSV | Text, comma-separated | Variable | Debugging, manual testing |

Both protocols use the same logical message types; only the encoding differs.

## Transport Framing

### TCP Framing

TCP connections use **length-prefix framing**:

```
┌─────────────────┬──────────────────────────────┐
│ Length (4 bytes)│ Payload (Length bytes)       │
│ Little-endian   │                              │
└─────────────────┴──────────────────────────────┘
```

- **Length**: 32-bit unsigned integer, little-endian
- **Payload**: Raw protocol message (binary or CSV)
- **Max frame size**: 16,384 bytes

Example: Sending a 26-byte binary message
```
04 00 00 00 1A 00 00 00    # Length = 26 (0x1A)
4D 4E 01 00 00 00 ...      # Payload (26 bytes)
```

### UDP

UDP datagrams contain raw protocol messages without framing. Each datagram is exactly one message.

## Binary Protocol

### Magic Byte

All binary messages start with magic byte `0x4D` ('M').

### Input Messages (Client → Server)

#### New Order (26 bytes)

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x4E ('N') = New Order
2       4     UserID      User identifier (little-endian)
6       8     Symbol      Symbol (null-padded ASCII)
14      4     Price       Price in cents (little-endian)
18      4     Quantity    Order quantity (little-endian)
22      1     Side        'B' = Buy, 'S' = Sell
23      4     OrderID     Order identifier (little-endian, unaligned)
──────────────────────────────────────────────────
Total: 26 bytes (with 1 byte padding for alignment)
```

**Note**: The struct has 1 byte of implicit padding after Side to align OrderID, making the total 26 bytes.

#### Cancel Order (26 bytes)

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x43 ('C') = Cancel
2       4     UserID      User identifier
6       8     Symbol      Symbol (null-padded)
14      4     Price       0 (unused)
18      4     Quantity    0 (unused)
22      1     Side        0 (unused)
23      4     OrderID     Order to cancel
──────────────────────────────────────────────────
```

#### Flush (26 bytes)

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x46 ('F') = Flush
2-25    24    (unused)    Zero-filled
──────────────────────────────────────────────────
```

### Output Messages (Server → Client)

#### ACK (19 bytes)

Confirms order acceptance.

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x41 ('A') = ACK
2       4     UserID      User identifier
6       8     Symbol      Symbol
14      4     OrderID     Assigned order ID
18      1     Padding     Alignment padding
──────────────────────────────────────────────────
Total: 19 bytes
```

#### Cancel ACK (19 bytes)

Confirms order cancellation.

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x58 ('X') = Cancel ACK
2       4     UserID      User identifier
6       8     Symbol      Symbol
14      4     OrderID     Cancelled order ID
18      1     Padding     Alignment padding
──────────────────────────────────────────────────
```

#### Trade (36 bytes)

Reports a trade execution.

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x54 ('T') = Trade
2       4     UserID      User identifier
6       8     Symbol      Symbol
14      4     Price       Trade price (cents)
18      4     Quantity    Trade quantity
22      4     BuyOrderID  Buyer's order ID
26      4     SellOrderID Seller's order ID
30      4     BuyUserID   Buyer's user ID
34      4     SellUserID  Seller's user ID
──────────────────────────────────────────────────
Total: 36 bytes (may vary by server version)
```

#### Top of Book (40 bytes)

Reports best bid/ask update.

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x42 ('B') = Top of Book
2       4     UserID      User identifier
6       8     Symbol      Symbol
14      4     BidPrice    Best bid price (cents), 0 if none
18      4     BidQty      Best bid quantity
22      4     AskPrice    Best ask price (cents), 0 if none
26      4     AskQty      Best ask quantity
30      1     Side        Which side updated ('B' or 'S')
31-39   9     Reserved    Padding/reserved
──────────────────────────────────────────────────
Total: 40 bytes
```

#### Reject (19 bytes)

Reports order rejection.

```
Offset  Size  Field       Description
──────────────────────────────────────────────────
0       1     Magic       0x4D ('M')
1       1     MsgType     0x52 ('R') = Reject
2       4     UserID      User identifier
6       8     Symbol      Symbol
14      4     OrderID     Rejected order ID
18      1     Reason      Rejection reason code
──────────────────────────────────────────────────
```

**Rejection Reasons:**
| Code | Meaning |
|------|---------|
| 1 | Invalid symbol |
| 2 | Invalid price |
| 3 | Invalid quantity |
| 4 | Order not found (for cancel) |
| 5 | Duplicate order ID |

## CSV Protocol

### Format

Each message is a single line terminated by newline (`\n`). Fields are comma-separated.

### Input Messages

#### New Order
```
N,<user_id>,<symbol>,<price>,<quantity>,<side>,<order_id>
```

Example:
```
N,1,IBM,10000,100,B,1
```

#### Cancel Order
```
C,<user_id>,<symbol>,<order_id>
```

Example:
```
C,1,IBM,1
```

#### Flush
```
F
```

### Output Messages

#### ACK
```
A,<symbol>,<user_id>,<order_id>
```

Example:
```
A,IBM,1,1
```

#### Cancel ACK
```
X,<symbol>,<user_id>,<order_id>
```

Example:
```
X,IBM,1,1
```

#### Trade
```
T,<symbol>,<price>,<quantity>,<buy_order_id>,<sell_order_id>
```

Example:
```
T,IBM,10000,100,1,2
```

#### Top of Book
```
B,<symbol>,<side>,<bid_price>,<bid_qty>,<ask_price>,<ask_qty>
```

Example:
```
B,IBM,B,10000,100,10100,50
```

#### Reject
```
R,<symbol>,<user_id>,<order_id>,<reason>
```

Example:
```
R,IBM,1,1,4
```

## Protocol Detection

The client can auto-detect which protocol the server expects:

1. Send a binary probe order
2. Wait for response (200ms timeout)
3. If valid binary response → use binary
4. Otherwise, send CSV probe
5. If valid CSV response → use CSV
6. Otherwise → connection error

The probe order uses:
- UserID: 999999
- Symbol: "PROBE"
- Price: 1
- Quantity: 1
- OrderID: 999999

After detection, the probe order is cancelled to clean up.

## Byte Order

All multi-byte integers are **little-endian**.

## Symbol Encoding

Symbols are ASCII strings, up to 8 characters:
- Stored in fixed 8-byte field
- Null-padded if shorter than 8 characters
- No null terminator if exactly 8 characters

Examples:
```
"IBM"     → 49 42 4D 00 00 00 00 00
"AAPL"    → 41 41 50 4C 00 00 00 00
"GOOGL"   → 47 4F 4F 47 4C 00 00 00
"XXXXXXXX"→ 58 58 58 58 58 58 58 58  (no null)
```

## Price Encoding

Prices are stored as **32-bit unsigned integers representing cents**.

| Display Price | Wire Value |
|---------------|------------|
| $100.00 | 10000 |
| $1.50 | 150 |
| $0.01 | 1 |
| $99,999.99 | 9999999 |

Maximum representable price: $42,949,672.95 (2^32 - 1 cents)

## Sequence Numbers

The matching engine assigns sequence numbers to all outbound messages for:
- Gap detection
- Replay requests
- Audit trail

Sequence numbers are monotonically increasing 64-bit integers, reset on server restart.

**Note**: The current client does not track sequence numbers. This is a future enhancement.

## Error Handling

### Connection Errors

| Error | Meaning | Recovery |
|-------|---------|----------|
| ConnectionRefused | Server not running | Retry with backoff |
| ConnectionClosed | Server disconnected | Reconnect |
| Timeout | No response | Retry or abort |

### Protocol Errors

| Error | Meaning | Recovery |
|-------|---------|----------|
| InvalidMagic | Not a valid binary message | Check protocol mode |
| MessageTooShort | Incomplete message | Wait for more data |
| UnknownMessageType | Unrecognized type byte | Log and skip |
| ParseError | Malformed CSV | Log and skip |

## Example Session

### Binary (hex dump)

```
# Client → Server: New Buy Order
04 00 00 00                         # Frame length: 26 bytes
4D 4E                               # Magic + MsgType (New Order)
01 00 00 00                         # UserID: 1
49 42 4D 00 00 00 00 00             # Symbol: "IBM"
10 27 00 00                         # Price: 10000 ($100.00)
64 00 00 00                         # Quantity: 100
42                                  # Side: 'B' (Buy)
01 00 00 00                         # OrderID: 1

# Server → Client: ACK
13 00 00 00                         # Frame length: 19 bytes
4D 41                               # Magic + MsgType (ACK)
01 00 00 00                         # UserID: 1
49 42 4D 00 00 00 00 00             # Symbol: "IBM"
01 00 00 00                         # OrderID: 1
00                                  # Padding
```

### CSV

```
# Client → Server: New Buy Order
N,1,IBM,10000,100,B,1

# Server → Client: ACK
A,IBM,1,1

# Client → Server: New Sell Order (matching)
N,1,IBM,10000,100,S,2

# Server → Client: ACK + Trade + Top of Book
A,IBM,1,2
T,IBM,10000,100,1,2
B,IBM,S,0,0,0,0
```

## Compatibility

This client is compatible with:
- Zig Matching Engine v0.1.0+
- C Matching Engine (original implementation)

Protocol version negotiation is not currently implemented; both sides must use matching protocol versions.
