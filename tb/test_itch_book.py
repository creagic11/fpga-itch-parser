"""Phase 6: the whole design, Ethernet frames in -> BBO out (itch_book_top).

1. Synthetic: two interleaved stocks, the filter keeps one; every BBO update must
   equal an unbounded order book for that stock.
2. Latency: wire-to-BBO cycles for single-message frames, from the frame's first
   beat entering the design to the BBO update leaving it.
3. Real data (opt-in): ITCH_REAL=<file> ITCH_GOLDEN=<C++ replay --locate N --bbo-out>
   ITCH_LOCATE=N ITCH_BASE=<price> [ITCH_REAL_N]: the BBO stream must equal the
   C++ book's, record for record (C++ seq = file index = MoldUDP64 seq - 1).
"""
from __future__ import annotations

import ipaddress
import os
import random
import statistics
import struct

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
from cocotbext.axi import AxiStreamBus, AxiStreamFrame, AxiStreamSource

import itch_model as im
import mold
from axis_util import random_pause, start
from book_model import ADD, CANCEL, DELETE, EXEC, EXEC_PX, REPLACE, TRADE, FullBook
from test_book_engine import flow
from test_itch_rx import GROUP, PORT, eth_frame

BASE = 20_000_000


def to_itch(ev, locate: int, ts: int) -> bytes:
    """Encode a book-model event as an ITCH 5.0 message."""
    t, ref, new_ref, shares, price, sell, _ = ev
    side = b"S" if sell else b"B"
    if t == ADD:
        return im.header("A", locate, ts) + struct.pack(">Q", ref) + side + struct.pack(">I", shares) + \
            b"TEST    " + struct.pack(">I", price)
    if t == EXEC:
        return im.header("E", locate, ts) + struct.pack(">QIQ", ref, shares, 1)
    if t == EXEC_PX:
        return im.header("C", locate, ts) + struct.pack(">QIQ", ref, shares, 1) + b"Y" + struct.pack(">I", price)
    if t == CANCEL:
        return im.header("X", locate, ts) + struct.pack(">QI", ref, shares)
    if t == DELETE:
        return im.header("D", locate, ts) + struct.pack(">Q", ref)
    if t == REPLACE:
        return im.header("U", locate, ts) + struct.pack(">QQII", ref, new_ref, shares, price)
    return im.header("P", locate, ts) + struct.pack(">Q", 0) + side + struct.pack(">I", shares) + \
        b"TEST    " + struct.pack(">IQ", price, 1)


async def collect(dut, out: list, cycle_log: list | None = None, p_stall=0.0, seed=0):
    stall = random_pause(seed, p_stall)
    cyc = 0
    while True:
        await RisingEdge(dut.clk)
        cyc += 1
        dut.bbo_ready.value = 0 if (p_stall and next(stall)) else 1
        await ReadOnly()
        if int(dut.bbo_valid.value) and int(dut.bbo_ready.value):
            out.append(tuple(int(getattr(dut, f"bbo_{f}").value)
                             for f in ["seq", "bid_qty", "ask_qty", "bid_px", "ask_px"]))
            if cycle_log is not None:
                cycle_log.append(cocotb.utils.get_sim_time("ns"))


async def setup(dut, locate: int, base: int, p_src=0.0, p_bbo=0.0, seed=0, cycle_log=None):
    dut.cfg_dst_ip.value = int(ipaddress.IPv4Address(GROUP))
    dut.cfg_dst_port.value = PORT
    dut.cfg_filter_en.value = 1
    dut.cfg_locate.value = locate
    dut.cfg_base_price.value = base
    dut.bbo_ready.value = 1
    dut.s_axis_tvalid.value = 0          # a previous test may have left the bus mid-frame
    await start(dut)
    await ClockCycles(dut.clk, 4200)   # the book engine's memory-clear pass after reset
    src = AxiStreamSource(AxiStreamBus.from_prefix(dut, "s_axis"), dut.clk, dut.rst)
    if p_src:
        src.set_pause_generator(random_pause(seed, p_src))
    got: list = []
    cocotb.start_soon(collect(dut, got, cycle_log, p_bbo, seed + 3))
    return src, got


async def wait_for(dut, got, n, idle_limit=50):
    last, idle = -1, 0
    while len(got) < n and idle < idle_limit:
        await ClockCycles(dut.clk, 100)
        progress = len(got) + int(dut.cnt_messages.value) + int(dut.cnt_frames.value)
        idle = idle + 1 if progress == last else 0
        last = progress
    await ClockCycles(dut.clk, 100)


@cocotb.test(timeout_time=40, timeout_unit="ms")
async def two_stocks_filtered_matches_unbounded_book(dut):
    rng = random.Random(21)
    a = flow(rng, 6000, spread=200, ref0=1_000)             # stock 5 (kept)
    b = flow(rng, 6000, spread=200, ref0=50_000_000)        # stock 9 (filtered out)
    # interleave the two streams at random, keeping each stock's own order
    order = [5] * len(a) + [9] * len(b)
    rng.shuffle(order)
    ia, ib = iter(a), iter(b)
    mixed = [(loc, next(ia) if loc == 5 else next(ib)) for loc in order]
    msgs, ts = [], 34_200_000_000_000
    for loc, e in mixed:
        ts += 1000
        msgs.append(to_itch(e, loc, ts))
    full, want = FullBook(), []
    for i, (loc, e) in enumerate(mixed):
        if loc != 5:
            continue
        r = full.event(*e[:6], i + 1)                       # MoldUDP64 seq = index + 1
        if r:
            want.append((r[4], r[1], r[3], r[0], r[2]))     # seq, bid_qty, ask_qty, bid_px, ask_px
    src, got = await setup(dut, 5, BASE, p_src=0.2, p_bbo=0.4, seed=21)
    for p in mold.pack_stream(msgs, start_seq=1, max_payload=1400):
        await src.send(AxiStreamFrame(eth_frame(p)))
    await wait_for(dut, got, len(want))
    await src.wait()                     # leave the bus idle for the next test
    assert int(dut.cnt_out_of_window.value) == 0 and int(dut.cnt_collisions.value) == 0
    assert len(got) == len(want), f"{len(got)} BBO updates, expected {len(want)}"
    for i, (g, w) in enumerate(zip(got, want)):
        assert g == w, f"BBO {i}: got {g} want {w}"
    dut._log.info(f"{len(msgs)} messages (2 stocks) -> {len(want)} BBO updates for the kept stock")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def wire_to_bbo_latency(dut):
    """Single-message frames, one at a time on an idle design: cycles from the
    frame's first beat to the BBO update. Adds that improve the bid, and Deletes
    of the best bid (next best found by the priority encoder)."""
    times: list = []
    src, got = await setup(dut, 5, BASE, cycle_log=times)

    lat, seq, ts = [], 1, 34_200_000_000_000
    for k in range(200):
        kind = ADD if k % 2 == 0 else DELETE
        ref = 10_000 + k // 2
        ev = (ADD, ref, 0, 100, BASE + 100 * (1000 + k), False, 0) if kind == ADD else \
             (DELETE, ref, 0, 0, 0, False, 0)
        frame = eth_frame(mold.packet(seq, [to_itch(ev, 5, ts)]))
        seq += 1
        n0 = len(got)
        t0 = cocotb.utils.get_sim_time("ns")
        await src.send(AxiStreamFrame(frame))
        for _ in range(3000):
            if len(got) > n0:
                break
            await RisingEdge(dut.clk)
        else:
            c = {k: int(getattr(dut, f"cnt_{k}").value) for k in
                 ["frames", "messages", "events", "book_events", "bbo", "out_of_window", "unknown", "gaps", "bad"]}
            raise AssertionError(f"no BBO for frame {k}: {c}")
        lat.append(round((times[-1] - t0) / 6.4))
        await ClockCycles(dut.clk, 20)
    adds, dels = lat[0::2], lat[1::2]
    ns = lambda c: c * 6.4
    dut._log.info(f"wire-to-BBO latency, Add: min {min(adds)} / median {statistics.median(adds)} / "
                  f"max {max(adds)} cycles ({ns(statistics.median(adds)):.1f} ns at 156.25 MHz)")
    dut._log.info(f"wire-to-BBO latency, Delete of best: min {min(dels)} / median "
                  f"{statistics.median(dels)} / max {max(dels)} cycles")
    with open(os.environ.get("LATENCY_OUT", "/dev/null"), "w") as f:
        f.write(f"add {min(adds)} {statistics.median(adds)} {max(adds)}\n"
                f"delete {min(dels)} {statistics.median(dels)} {max(dels)}\n")


@cocotb.test(timeout_time=3000, timeout_unit="ms", skip=not os.environ.get("ITCH_GOLDEN"))
async def real_day_matches_cpp_book(dut):
    locate, base = int(os.environ["ITCH_LOCATE"]), int(os.environ["ITCH_BASE"])
    n = int(os.environ.get("ITCH_REAL_N", "1000000"))
    msgs = im.read_itch_file(os.environ["ITCH_REAL"], n)
    g = open(os.environ["ITCH_GOLDEN"], "rb").read()
    golden = [struct.unpack_from("<QQQII", g, i) for i in range(0, len(g), 40)]
    src, got = await setup(dut, locate, base)
    for p in mold.pack_stream(msgs, start_seq=1, max_payload=1400):
        await src.send(AxiStreamFrame(eth_frame(p)))
    await wait_for(dut, got, len(golden))
    await src.wait()                     # every frame in, then let the pipeline drain
    await ClockCycles(dut.clk, 2000)
    c = {k: int(getattr(dut, f"cnt_{k}").value) for k in
         ["messages", "book_events", "bbo", "out_of_window", "collisions", "unknown", "duplicates", "gaps", "bad"]}
    dut._log.info(f"counters: {c}")
    mine = [(s - 1, bq, aq, bp, ap) for (s, bq, aq, bp, ap) in got]
    for i, (m, w) in enumerate(zip(mine, golden)):
        assert m == w, f"BBO {i}: FPGA {m} vs C++ {w}"
    assert len(mine) == len(golden), f"FPGA {len(mine)} BBO updates, C++ {len(golden)}"
    dut._log.info(f"real data: {len(msgs)} messages -> {len(mine)} BBO updates, identical to the C++ book")
