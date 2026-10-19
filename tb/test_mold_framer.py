"""Phase 3: MoldUDP64 framer.

The DUT receives MoldUDP64 payloads (one AXI-Stream packet each) and must emit
one packet per ITCH message, lane 0 aligned, with m_seq = the message's sequence
number, dropping duplicates and counting gaps, heartbeats and errors.
"""
from __future__ import annotations

import random

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
from cocotbext.axi import AxiStreamFrame

import mold
from axis_util import axis_pair, check_axis_protocol, random_pause, start

COUNTERS = ["packets", "messages", "heartbeats", "gaps", "gap_msgs", "dup_msgs", "errors"]


def counters(dut):
    c = {k: int(getattr(dut, f"cnt_{k}").value) for k in COUNTERS}
    c["expected_seq"] = int(dut.expected_seq.value)
    c["eos"] = int(dut.end_of_session.value)
    return c


async def seq_monitor(dut, seqs: list):
    """Record m_seq for every message as its first beat is accepted."""
    first = True
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            if first:
                seqs.append(int(dut.m_seq.value))
            first = bool(int(dut.m_axis_tlast.value))


async def check_aligned(dut):
    ok_last = {(1 << n) - 1 for n in range(0, 9)}
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            keep, last = int(dut.m_axis_tkeep.value), int(dut.m_axis_tlast.value)
            assert (keep in ok_last) if last else keep == 0xFF, f"bad tkeep {keep:#x} last={last}"


async def setup(dut, seed=0, p_src=0.0, p_snk=0.0):
    await start(dut)
    src, snk = axis_pair(dut)
    if p_src:
        src.set_pause_generator(random_pause(seed, p_src))
    if p_snk:
        snk.set_pause_generator(random_pause(seed + 1, p_snk))
    seqs: list[int] = []
    cocotb.start_soon(seq_monitor(dut, seqs))
    cocotb.start_soon(check_axis_protocol(dut, "m_axis", has_user=True))
    cocotb.start_soon(check_aligned(dut))
    return src, snk, seqs


def last_user(f) -> int:
    return f.tuser[-1] if isinstance(f.tuser, list) else int(f.tuser or 0)


async def expect_messages(snk, seqs, want: list[tuple[int, bytes]]):
    for i, (seq, data) in enumerate(want):
        got = await snk.recv()
        assert bytes(got.tdata) == data, f"message {i} (seq {seq}): {bytes(got.tdata).hex()} != {data.hex()}"
        assert last_user(got) == 0
    assert seqs[: len(want)] == [s for s, _ in want], f"sequence numbers differ: {seqs[:10]}..."


def random_messages(rng, n, lo=1, hi=60):
    return [bytes(rng.getrandbits(8) for _ in range(rng.randint(lo, hi))) for _ in range(n)]


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def splits_every_length_and_alignment(dut):
    """Message lengths 1..80 in every order, so lengths and bodies start at every lane."""
    src, snk, seqs = await setup(dut)
    rng = random.Random(1)
    msgs = random_messages(rng, 1500, 1, 80) + random_messages(rng, 20, 200, 600)
    pkts = mold.pack_stream(msgs, start_seq=1000, max_payload=1400)
    for p in pkts:
        await src.send(AxiStreamFrame(p))
    await expect_messages(snk, seqs, [(1000 + i, m) for i, m in enumerate(msgs)])
    await ClockCycles(dut.clk, 20)
    c = counters(dut)
    assert c["messages"] == len(msgs) and c["packets"] == len(pkts) and c["errors"] == 0, c
    assert c["gaps"] == 0 and c["expected_seq"] == 1000 + len(msgs), c


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def heartbeats_gaps_duplicates_end_of_session(dut):
    src, snk, seqs = await setup(dut)
    rng = random.Random(2)
    m = random_messages(rng, 40)
    want = []
    await src.send(AxiStreamFrame(mold.packet(1, m[0:5])))          # seq 1-5
    want += [(1 + i, x) for i, x in enumerate(m[0:5])]
    await src.send(AxiStreamFrame(mold.heartbeat(6)))               # in sync
    await src.send(AxiStreamFrame(mold.packet(6, m[5:10])))         # seq 6-10
    want += [(6 + i, x) for i, x in enumerate(m[5:10])]
    await src.send(AxiStreamFrame(mold.packet(14, m[13:18])))       # gap: 11-13 missing
    want += [(14 + i, x) for i, x in enumerate(m[13:18])]
    await src.send(AxiStreamFrame(mold.packet(6, m[5:10])))         # old copy: all duplicates
    await src.send(AxiStreamFrame(mold.packet(17, m[16:22])))       # 17,18 dup; 19-22 new
    want += [(19 + i, x) for i, x in enumerate(m[18:22])]
    await src.send(AxiStreamFrame(mold.heartbeat(25)))              # gap: 23-24 missing
    await src.send(AxiStreamFrame(mold.end_of_session(25)))
    await expect_messages(snk, seqs, want)
    await ClockCycles(dut.clk, 30)
    assert snk.empty(), "a duplicate leaked through"
    c = counters(dut)
    assert c["messages"] == len(want), c
    assert c["dup_msgs"] == 5 + 2, c
    assert c["gaps"] == 2 and c["gap_msgs"] == 3 + 2, c
    assert c["heartbeats"] == 2 and c["eos"] == 1 and c["errors"] == 0, c
    assert c["expected_seq"] == 25, c


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def truncated_and_malformed_packets(dut):
    src, snk, seqs = await setup(dut)
    good = [b"G" * 13, b"H" * 9]
    full = mold.packet(1, [b"A" * 30, b"B" * 30])
    await src.send(AxiStreamFrame(full[: 20 + 2 + 30 + 2 + 11]))  # cut 19 bytes into message 2
    got = await snk.recv()
    assert bytes(got.tdata) == b"A" * 30 and last_user(got) == 0
    got = await snk.recv()
    assert bytes(got.tdata) == b"B" * 11 and last_user(got) == 1, "cut message must be flagged"
    await src.send(AxiStreamFrame(mold.packet(3, good)[:15]))         # ends inside the header
    await src.send(AxiStreamFrame(mold.packet(3, good) + b"\x00" * 5))  # trailing bytes
    await src.send(AxiStreamFrame(mold.packet(5, good)))              # clean packet still works
    for want in good + good:
        got = await snk.recv()
        assert bytes(got.tdata) == want and last_user(got) == 0
    await ClockCycles(dut.clk, 30)
    c = counters(dut)
    assert c["errors"] == 3, c   # cut message, cut header, trailing bytes
    assert c["messages"] == 1 + 2 + 2, c


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def random_stream_under_backpressure(dut):
    """3,000 packets of random messages; random stalls on both sides."""
    src, snk, seqs = await setup(dut, seed=9, p_src=0.3, p_snk=0.5)
    rng = random.Random(9)
    msgs = random_messages(rng, 20000, 1, 64)
    pkts = mold.pack_stream(msgs, start_seq=1, max_payload=rng.choice([200, 600, 1400]))
    for p in pkts:
        await src.send(AxiStreamFrame(p))
    await expect_messages(snk, seqs, [(1 + i, m) for i, m in enumerate(msgs)])
    c = counters(dut)
    assert c["messages"] == len(msgs) and c["errors"] == 0, c


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def throughput_back_to_back_deletes(dut):
    """1,000 ITCH Delete-sized (19-byte) messages in full packets, no stalls.
    Input is 21 bytes per message, so 8 bytes/cycle line rate is 2.6 cycles per
    message; the framer should need about 3 (one per output beat)."""
    src, snk, seqs = await setup(dut)
    msgs = [bytes([0x44]) + bytes(18)] * 1000
    pkts = mold.pack_stream(msgs, start_seq=1, max_payload=1400)
    t0 = cocotb.utils.get_sim_time("ns")
    for p in pkts:
        await src.send(AxiStreamFrame(p))
    for _ in msgs:
        await snk.recv()
    cycles = (cocotb.utils.get_sim_time("ns") - t0) / 6.4
    per_msg = cycles / len(msgs)
    dut._log.info(f"{cycles:.0f} cycles for {len(msgs)} messages: {per_msg:.2f} cycles/message, "
                  f"{21 * len(msgs) / cycles:.2f} input bytes/cycle")
    assert per_msg < 3.3, f"{per_msg:.2f} cycles per message"


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def large_sequence_numbers(dut):
    """Sequence numbers with every byte non-zero, so each of the 8 header bytes
    must really be captured (small numbers would hide a missed high byte)."""
    src, snk, seqs = await setup(dut)
    rng = random.Random(3)
    base = 0x0102030405060708
    msgs = random_messages(rng, 300, 1, 60)
    for p in mold.pack_stream(msgs, start_seq=base, max_payload=300):
        await src.send(AxiStreamFrame(p))
    await expect_messages(snk, seqs, [(base + i, m) for i, m in enumerate(msgs)])
    await ClockCycles(dut.clk, 20)
    c = counters(dut)
    assert c["expected_seq"] == base + len(msgs), f"expected_seq {c['expected_seq']:#x}"
    assert c["gaps"] == 0 and c["dup_msgs"] == 0 and c["errors"] == 0, c


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def reset_mid_packet(dut):
    """Reset while the buffer still holds part of a packet, then a fresh packet.
    Regression for a real bug: the buffer was not cleared by reset, so its stale
    bytes were OR-ed into the next header and corrupted the sequence number (the
    next packet was then dropped as a duplicate)."""
    src, snk, seqs = await setup(dut)
    rng = random.Random(6)
    snk.pause = True                                  # stall so the framer holds bytes
    junk = bytes(rng.getrandbits(8) | 0x80 for _ in range(600))
    await src.send(AxiStreamFrame(mold.packet(0x7F7F7F7F7F7F7F7F, [junk[:300], junk[300:]])))
    await ClockCycles(dut.clk, 40)
    assert int(dut.cnt.value) != 0, "test needs the buffer to be holding bytes at reset"
    src.clear()
    dut.rst.value = 1
    await ClockCycles(dut.clk, 5)
    dut.rst.value = 0
    snk.clear()
    snk.pause = False
    await RisingEdge(dut.clk)
    seqs.clear()
    base = 0x0102030405060708
    msgs = random_messages(rng, 50, 1, 60)
    for p in mold.pack_stream(msgs, start_seq=base, max_payload=300):
        await src.send(AxiStreamFrame(p))
    await expect_messages(snk, seqs, [(base + i, m) for i, m in enumerate(msgs)])
    await ClockCycles(dut.clk, 20)
    c = counters(dut)
    assert c["expected_seq"] == base + len(msgs), f"expected_seq {c['expected_seq']:#x}"
    assert c["dup_msgs"] == 0 and c["gaps"] == 0, c


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def junk_in_null_bytes(dut):
    """Bytes outside tkeep on a packet's last beat are don't-care in AXI-Stream and
    may carry leftovers; they must not reach the next packet."""
    src, snk, seqs = await setup(dut)
    rng = random.Random(5)
    base = 0x0A0B0C0D0E0F1011
    msgs = random_messages(rng, 400, 1, 60)
    for p in mold.pack_stream(msgs, start_seq=base, max_payload=rng.choice([150, 333])):
        pad = (-len(p)) % 8
        f = AxiStreamFrame(p + bytes(rng.getrandbits(8) | 1 for _ in range(pad)),
                           tkeep=[1] * len(p) + [0] * pad)
        await src.send(f)
    await expect_messages(snk, seqs, [(base + i, m) for i, m in enumerate(msgs)])
    await ClockCycles(dut.clk, 20)
    c = counters(dut)
    assert c["gaps"] == 0 and c["dup_msgs"] == 0 and c["errors"] == 0, c
    assert c["expected_seq"] == base + len(msgs)
