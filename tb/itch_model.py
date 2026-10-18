"""ITCH 5.0 reference model for the decoder bench: message builders and the
expected decoded event for any message (Nasdaq TotalView-ITCH 5.0 layouts)."""
from __future__ import annotations

import random
import struct

SIZE = {
    "S": 12, "R": 39, "H": 25, "Y": 20, "L": 26, "V": 35, "W": 12, "K": 28,
    "J": 35, "h": 21, "A": 36, "F": 40, "E": 31, "C": 36, "X": 23, "D": 19,
    "U": 35, "P": 44, "Q": 40, "B": 19, "I": 50, "N": 20, "O": 48,
}
EV_CODE = {"A": 1, "F": 1, "E": 2, "C": 3, "X": 4, "D": 5, "U": 6, "P": 7}


def header(t: str, locate: int, ts: int, tracking: int = 0) -> bytes:
    return t.encode() + struct.pack(">HH", locate, tracking) + ts.to_bytes(6, "big")


def random_message(rng: random.Random, t: str, locate: int, ts: int) -> bytes:
    """A message of type t with random field values and the correct length."""
    h = header(t, locate, ts, rng.getrandbits(16))
    side = rng.choice(b"BS")
    if t in "AF":
        body = struct.pack(">QBI", rng.getrandbits(64), side, rng.getrandbits(32)) + b"TEST    " + \
            struct.pack(">I", rng.getrandbits(32)) + (b"GSCO" if t == "F" else b"")
    elif t == "E":
        body = struct.pack(">QIQ", rng.getrandbits(64), rng.getrandbits(32), rng.getrandbits(64))
    elif t == "C":
        body = struct.pack(">QIQ", rng.getrandbits(64), rng.getrandbits(32), rng.getrandbits(64)) + \
            b"Y" + struct.pack(">I", rng.getrandbits(32))
    elif t == "X":
        body = struct.pack(">QI", rng.getrandbits(64), rng.getrandbits(32))
    elif t == "D":
        body = struct.pack(">Q", rng.getrandbits(64))
    elif t == "U":
        body = struct.pack(">QQII", rng.getrandbits(64), rng.getrandbits(64), rng.getrandbits(32),
                           rng.getrandbits(32))
    elif t == "P":
        body = struct.pack(">QBI", rng.getrandbits(64), side, rng.getrandbits(32)) + b"TEST    " + \
            struct.pack(">IQ", rng.getrandbits(32), rng.getrandbits(64))
    else:
        body = bytes(rng.getrandbits(8) for _ in range(SIZE[t] - 11))
    m = h + body
    assert len(m) == SIZE[t], (t, len(m))
    return m


def expected_event(m: bytes, seq: int, filter_locate: int | None = None):
    """Decoded event tuple the hardware must produce, or None if it drops the message."""
    t = chr(m[0])
    if SIZE.get(t) != len(m) or t not in EV_CODE:
        return None
    locate = struct.unpack_from(">H", m, 1)[0]
    if filter_locate is not None and locate != filter_locate:
        return None
    ts = int.from_bytes(m[5:11], "big")
    ref = struct.unpack_from(">Q", m, 11)[0]
    new_ref = shares = price = 0
    sell = 0
    if t in "AFP":
        sell = int(m[19] == ord("S"))
        shares, price = struct.unpack_from(">I", m, 20)[0], struct.unpack_from(">I", m, 32)[0]
    elif t in "EX":
        shares = struct.unpack_from(">I", m, 19)[0]
    elif t == "C":
        shares, price = struct.unpack_from(">I", m, 19)[0], struct.unpack_from(">I", m, 32)[0]
    elif t == "U":
        new_ref, shares, price = struct.unpack_from(">QII", m, 19)
    return (EV_CODE[t], m[0], locate, ts, ref, new_ref, shares, price, sell, seq)


def read_itch_file(path: str, limit: int):
    """First `limit` messages of a Nasdaq sample file (2-byte length framing)."""
    out = []
    with open(path, "rb") as f:
        while len(out) < limit:
            ln = f.read(2)
            if len(ln) < 2:
                break
            out.append(f.read(struct.unpack(">H", ln)[0]))
    return out
