"""Phase 5: top-of-book engine (book_engine).

Events are driven directly; every BBO update must equal tb/book_model.py's
HwBook, and, when no hardware limit was hit, an unbounded order book as well.
"""
from __future__ import annotations

import random

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from axis_util import random_pause, start
from book_model import ADD, CANCEL, DELETE, EXEC, EXEC_PX, REPLACE, TRADE, FullBook, HwBook

BASE = 20_000_000          # $2,000.0000 ... level 0
COUNTERS = ["events", "bbo", "out_of_window", "collisions", "unknown", "duplicates"]


async def drive(dut, events):
    """Present events back to back; each is taken when ev_ready is high at a clock edge."""
    for (t, ref, new_ref, shares, price, sell, seq) in events:
        dut.ev_type.value, dut.ev_ref.value, dut.ev_new_ref.value = t, ref, new_ref
        dut.ev_shares.value, dut.ev_price.value = shares, price
        dut.ev_side_sell.value, dut.ev_seq.value = int(sell), seq
        dut.ev_valid.value = 1
        while True:
            await RisingEdge(dut.clk)
            if int(dut.ev_ready.value):
                break
    await RisingEdge(dut.clk)
    dut.ev_valid.value = 0


async def collect(dut, out, p_stall=0.0, seed=0):
    stall = random_pause(seed, p_stall)
    while True:
        await RisingEdge(dut.clk)
        dut.bbo_ready.value = 0 if (p_stall and next(stall)) else 1
        await ReadOnly()
        if int(dut.bbo_valid.value) and int(dut.bbo_ready.value):
            out.append(tuple(int(getattr(dut, f"bbo_{f}").value)
                             for f in ["bid_px", "bid_qty", "ask_px", "ask_qty", "seq"]))


async def run(dut, events, p_stall=0.0, seed=0):
    dut.cfg_base_price.value = BASE
    dut.ev_valid.value = 0
    dut.bbo_ready.value = 1
    await start(dut)
    got: list = []
    cocotb.start_soon(collect(dut, got, p_stall, seed))
    hw, full = HwBook(BASE), FullBook()
    want, want_full = [], []
    for e in events:
        r = hw.event(*e)
        if r:
            want.append(r)
        r = full.event(*e)
        if r:
            want_full.append(r)
    t0 = cocotb.utils.get_sim_time("ns")
    await drive(dut, events)
    await ClockCycles(dut.clk, 40)
    cycles = (cocotb.utils.get_sim_time("ns") - t0) / 6.4
    for i, (g, w) in enumerate(zip(got, want)):
        if g != w:
            ctx = [e for e in events if w[4] - 3 <= e[6] <= max(w[4], g[4])]
            dut._log.error(f"first difference at BBO {i}: got {g}, want {w}; events around it: {ctx}")
            break
    assert len(got) == len(want), f"{len(got)} BBO updates, expected {len(want)}"
    for i, (g, w) in enumerate(zip(got, want)):
        assert g == w, f"BBO {i}: got {g}, want {w}"
    for c in COUNTERS:
        assert int(getattr(dut, f"cnt_{c}").value) == hw.c[c], f"cnt_{c}: {int(getattr(dut, f'cnt_{c}').value)} != {hw.c[c]}"
    assert int(dut.live_orders.value) == hw.live
    return hw, want, want_full, cycles


def flow(rng: random.Random, n: int, mid_idx=2048, spread=40, p_far=0.0, ref0=1000):
    """A valid single-stock event stream around a mid price (all prices on the tick grid)."""
    live, ev, ref, seq = {}, [], ref0, 1
    for _ in range(n):
        r = rng.random()
        if r < 0.45 or len(live) < 20:
            sell = rng.random() < 0.5
            off = rng.randint(1, spread)
            idx = mid_idx + off if sell else mid_idx - off
            if rng.random() < p_far:
                idx = rng.choice([-5, 5000, 4096, 4095, 0])     # outside or at the window edges
            price = BASE + 100 * idx
            sh = rng.randint(1, 30) * 100
            ref += rng.randint(1, 5)
            if price > 0:
                live[ref] = [sell, price, sh]
            ev.append((ADD, ref, 0, sh, max(price, 0), sell, seq))
        elif r < 0.60:
            k = rng.choice(list(live))
            sh = rng.randint(1, live[k][2])
            ev.append((rng.choice([EXEC, EXEC_PX]), k, 0, sh, 0, False, seq))
            live[k][2] -= sh
            if live[k][2] == 0:
                del live[k]
        elif r < 0.70:
            k = rng.choice(list(live))
            if live[k][2] > 1:
                sh = rng.randint(1, live[k][2] - 1)
                ev.append((CANCEL, k, 0, sh, 0, False, seq))
                live[k][2] -= sh
        elif r < 0.88:
            k = rng.choice(list(live))
            ev.append((DELETE, k, 0, 0, 0, False, seq))
            del live[k]
        elif r < 0.97:
            k = rng.choice(list(live))
            sell = live.pop(k)[0]
            off = rng.randint(1, spread)
            price = BASE + 100 * (mid_idx + off if sell else mid_idx - off)
            ref += rng.randint(1, 5)
            sh = rng.randint(1, 30) * 100
            live[ref] = [sell, price, sh]
            ev.append((REPLACE, k, ref, sh, price, False, seq))
        else:
            ev.append((TRADE, 0, 0, 100, BASE, False, seq))
        seq += 1
    return ev


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def directed_scenarios(dut):
    p = lambda i: BASE + 100 * i
    ev = [
        (ADD, 10, 0, 100, p(100), False, 1),        # bid 100 x 100
        (ADD, 11, 0, 50, p(100), False, 2),         # same level: qty 150
        (ADD, 12, 0, 300, p(105), True, 3),         # ask 105 x 300
        (ADD, 13, 0, 10, p(104), True, 4),          # better ask
        (EXEC, 13, 0, 4, 0, False, 5),              # partial
        (EXEC_PX, 13, 0, 6, 0, False, 6),           # rest: best ask falls back to 105
        (CANCEL, 10, 0, 30, 0, False, 7),           # bid qty 120
        (REPLACE, 11, 20, 70, p(101), False, 8),    # moves to a better bid
        (DELETE, 20, 0, 0, 0, False, 9),            # best bid back to 100 x 70
        (DELETE, 99, 0, 0, 0, False, 10),           # unknown
        (TRADE, 0, 0, 100, p(100), False, 11),      # no book change
        (DELETE, 10, 0, 0, 0, False, 12),           # bid side empty
    ]
    hw, want, want_full, _ = await run(dut, ev)
    assert [w[:4] for w in want] == [
        (p(100), 100, 0, 0), (p(100), 150, 0, 0), (p(100), 150, p(105), 300),
        (p(100), 150, p(104), 10), (p(100), 150, p(104), 6), (p(100), 150, p(105), 300),
        (p(100), 120, p(105), 300), (p(101), 70, p(105), 300), (p(100), 70, p(105), 300),
        (0, 0, p(105), 300)]
    assert want == want_full


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def random_flow_matches_unbounded_book(dut):
    """10,000 events, all inside the window (prices spread over ~600 levels, i.e. many
    bitmap words): identical to an unbounded book."""
    rng = random.Random(11)
    ev = flow(rng, 10_000, spread=300)
    hw, want, want_full, cycles = await run(dut, ev, p_stall=0.3, seed=11)
    assert hw.c["out_of_window"] == hw.c["collisions"] == hw.c["duplicates"] == 0
    assert want == want_full, "hardware-rule model differs from an unbounded book"
    dut._log.info(f"{len(ev)} events, {len(want)} BBO updates, {cycles / len(ev):.2f} cycles/event "
                  "(with 30% output stalls)")


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def window_edges_and_out_of_window(dut):
    """Orders at levels 0 and 4,095 are booked; below the base, beyond the window and
    off the tick grid are counted and ignored."""
    rng = random.Random(12)
    ev = flow(rng, 4_000, mid_idx=2048, spread=2047, p_far=0.05)
    ev += [(ADD, 900_000_001, 0, 100, BASE + 150, False, 9_999_001),   # off the $0.01 grid
           (ADD, 900_000_002, 0, 100, BASE - 100, False, 9_999_002)]   # below the base
    hw, _, _, _ = await run(dut, ev)
    assert hw.c["out_of_window"] > 0


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def set_collisions_and_duplicates(dut):
    """Five orders in one set: the fifth collides. A reused live ref is a duplicate.
    After a delete frees a way, the next add to that set succeeds."""
    p = BASE + 100 * 2000
    s = 77
    ev = [(ADD, s + (k << 12), 0, 100, p, False, k + 1) for k in range(5)]
    ev += [(ADD, s, 0, 100, p, False, 6),                    # duplicate of a live ref
           (DELETE, s + (1 << 12), 0, 0, 0, False, 7),       # frees a way
           (ADD, s + (9 << 12), 0, 100, p, False, 8)]        # now fits
    hw, want, _, _ = await run(dut, ev)
    assert hw.c["collisions"] == 1 and hw.c["duplicates"] == 1
    assert want[-1][:2] == (p, 400)
