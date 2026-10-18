"""MoldUDP64 packet model (Nasdaq MoldUDP64 specification).

Downstream packet: session (10 bytes ASCII) | sequence number (8, BE) of the first
message | message count (2, BE), then `count` message blocks of
[length (2, BE)][message bytes]. Count 0 = heartbeat, 0xFFFF = end of session.
"""
from __future__ import annotations

import struct

SESSION = b"0000012345"


def packet(seq: int, messages: list[bytes], session: bytes = SESSION) -> bytes:
    body = b"".join(struct.pack(">H", len(m)) + m for m in messages)
    return session + struct.pack(">QH", seq, len(messages)) + body


def heartbeat(next_seq: int, session: bytes = SESSION) -> bytes:
    return session + struct.pack(">QH", next_seq, 0)


def end_of_session(next_seq: int, session: bytes = SESSION) -> bytes:
    return session + struct.pack(">QH", next_seq, 0xFFFF)


def parse(payload: bytes) -> tuple[int, int, list[bytes]]:
    """(sequence, count, messages) of one packet."""
    seq, count = struct.unpack_from(">QH", payload, 10)
    msgs, off = [], 20
    if count not in (0, 0xFFFF):
        for _ in range(count):
            (ln,) = struct.unpack_from(">H", payload, off)
            msgs.append(payload[off + 2: off + 2 + ln])
            off += 2 + ln
    return seq, count, msgs


def pack_stream(messages: list[bytes], start_seq: int = 1, max_payload: int = 1400):
    """Split a message stream into MoldUDP64 packets of at most max_payload bytes."""
    out, cur, size, seq = [], [], 20, start_seq
    for m in messages:
        if cur and size + 2 + len(m) > max_payload:
            out.append(packet(seq, cur))
            seq += len(cur)
            cur, size = [], 20
        cur.append(m)
        size += 2 + len(m)
    if cur:
        out.append(packet(seq, cur))
    return out
