"""Phase 4: Ethernet frames -> UDP -> MoldUDP64 -> ITCH decoder (itch_rx_top).

Every decoded event is compared field by field with tb/itch_model.py. Set
ITCH_REAL=/path/to/YYYYMMDD.BX_ITCH_50 (and optionally ITCH_REAL_N) to also run a
slice of a real Nasdaq day through the full chain.
"""
from __future__ import annotations

import ipaddress
import os
import random

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
from cocotbext.axi import AxiStreamFrame, AxiStreamBus, AxiStreamSource
from scapy.layers.inet import IP, UDP
from scapy.layers.l2 import Ether
from scapy.packet import Raw

import itch_model as im
import mold
from axis_util import random_pause, start

GROUP, PORT = "233.54.12.111", 26477
FIELDS = ["ev_type", "ev_msg_type", "ev_locate", "ev_ts", "ev_ref", "ev_new_ref", "ev_shares",
          "ev_price", "ev_side_sell", "ev_seq"]


def eth_frame(payload: bytes) -> bytes:
    b = bytes(Ether(dst="01:00:5e:36:0c:6f") / IP(src="10.0.0.1", dst=GROUP) /
              UDP(sport=40000, dport=PORT) / Raw(payload))
    return b + bytes(max(0, 60 - len(b)))


async def collect_events(dut, out: list, p_stall: float, seed: int):
    """Drive ev_ready with random stalls; record every accepted event."""
    # Each cycle: choose ready right after the clock edge, then sample in the
    # read-only phase. A beat counts when valid and ready are both high there,
    # because that is exactly what the next edge will see.
    stall = random_pause(seed, p_stall)
    while True:
        await RisingEdge(dut.clk)
        dut.ev_ready.value = 0 if (p_stall and next(stall)) else 1
        await ReadOnly()
        if int(dut.ev_valid.value) and int(dut.ev_ready.value):
            out.append(tuple(int(getattr(dut, f).value) for f in FIELDS))


async def setup(dut, filter_locate=None, p_src=0.0, p_ev=0.0, seed=0):
    dut.cfg_dst_ip.value = int(ipaddress.IPv4Address(GROUP))
    dut.cfg_dst_port.value = PORT
    dut.cfg_filter_en.value = int(filter_locate is not None)
    dut.cfg_locate.value = filter_locate or 0
    dut.ev_ready.value = 1
    await start(dut)
    src = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_axis"), dut.clk, dut.rst)
    if p_src:
        src.set_pause_generator(random_pause(seed, p_src))
    events: list = []
    cocotb.start_soon(collect_events(dut, events, p_ev, seed + 7))
    return src, events


async def run_messages(dut, msgs, filter_locate=None, start_seq=1, max_payload=1400, **kw):
    src, events = await setup(dut, filter_locate, **kw)
    for p in mold.pack_stream(msgs, start_seq=start_seq, max_payload=max_payload):
        await src.send(AxiStreamFrame(eth_frame(p)))
    want = [e for e in (im.expected_event(m, start_seq + i, filter_locate)
                        for i, m in enumerate(msgs)) if e is not None]
    # Wait until all events arrive; give up only if nothing moves for 5,000 cycles
    # (progress = messages framed + events out; a day starts with ~20K directory
    # and status messages that produce no events).
    last, idle = -1, 0
    while len(events) < len(want) and idle < 50:
        await ClockCycles(dut.clk, 100)
        progress = len(events) + int(dut.cnt_messages.value) + int(dut.cnt_frames.value)
        idle = idle + 1 if progress == last else 0
        last = progress
    await ClockCycles(dut.clk, 200)
    if len(events) != len(want):
        cn = {n: int(getattr(dut, n).value) for n in ["cnt_frames", "cnt_accepted", "cnt_packets",
              "cnt_messages", "cnt_events", "cnt_other", "cnt_filtered", "cnt_bad",
              "cnt_mold_errors", "cnt_gaps", "cnt_dup_msgs", "cnt_truncated"]}
        dut._log.error(f"counters: {cn}")
        first_diff = next((i for i, (g, w) in enumerate(zip(events, want)) if g != w), None)
        dut._log.error(f"first differing event: {first_diff}")
    assert len(events) == len(want), f"{len(events)} events, expected {len(want)}"
    for i, (g, w) in enumerate(zip(events, want)):
        assert g == w, f"event {i}:\n got  {dict(zip(FIELDS, g))}\n want {dict(zip(FIELDS, w))}"
    return want


def synthetic_day(rng: random.Random, n: int, locates=(1, 2, 3)):
    book = list("AAAAFEECXXDDDDUUP")
    other = [t for t in im.SIZE if t not in im.EV_CODE]
    msgs, ts = [], 34_200_000_000_000
    for _ in range(n):
        ts += rng.randint(0, 100_000)
        t = rng.choice(book) if rng.random() < 0.85 else rng.choice(other)
        msgs.append(im.random_message(rng, t, rng.choice(locates), ts))
    return msgs


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def decodes_every_type_end_to_end(dut):
    """6,000 messages of all 23 ITCH types (85% book messages) with random field values."""
    rng = random.Random(4)
    msgs = synthetic_day(rng, 6000)
    want = await run_messages(dut, msgs)
    other = sum(1 for m in msgs if chr(m[0]) not in im.EV_CODE)
    assert int(dut.cnt_events.value) == len(want)
    assert int(dut.cnt_other.value) == other
    assert int(dut.cnt_bad.value) == 0 and int(dut.cnt_mold_errors.value) == 0


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def stock_filter_bad_lengths_and_backpressure(dut):
    """Filter on locate 2, wrong-length and unknown messages mixed in, stalls everywhere."""
    rng = random.Random(5)
    msgs = synthetic_day(rng, 5000)
    bad = 0
    for i in range(0, len(msgs), 37):          # corrupt every 37th message
        m = msgs[i]
        msgs[i] = m[:-1] if i % 2 else b"z" + m[1:]
        bad += 1
    await run_messages(dut, msgs, filter_locate=2, p_src=0.2, p_ev=0.6, seed=5)
    assert int(dut.cnt_bad.value) == bad, f"{int(dut.cnt_bad.value)} bad, expected {bad}"
    assert int(dut.cnt_filtered.value) > 0


@cocotb.test(timeout_time=2000, timeout_unit="ms", skip=not os.environ.get("ITCH_REAL"))
async def real_nasdaq_slice(dut):
    """First ITCH_REAL_N (default 200,000) messages of a real Nasdaq file."""
    n = int(os.environ.get("ITCH_REAL_N", "200000"))
    msgs = im.read_itch_file(os.environ["ITCH_REAL"], n)
    want = await run_messages(dut, msgs, start_seq=1)
    dut._log.info(f"real slice: {len(msgs)} messages -> {len(want)} book events, all fields match")
    assert int(dut.cnt_bad.value) == 0 and int(dut.cnt_gaps.value) == 0
