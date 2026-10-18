"""Phase 2: Ethernet/IPv4/UDP receive + realign (udp_rx_top).

Frames are built with scapy, so lengths and IPv4 checksums are computed by an
independent implementation. The DUT must output exactly the UDP payloads of
the frames that pass every filter, each starting at lane 0, and count every
drop by reason.
"""
from __future__ import annotations

import ipaddress
import random

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge
from cocotbext.axi import AxiStreamFrame
from scapy.layers.inet import IP, TCP, UDP, IPOption_NOP
from scapy.layers.l2 import ARP, Dot1Q, Ether
from scapy.packet import Raw

from axis_util import axis_pair, check_axis_protocol, random_pause, start

GROUP = "233.54.12.111"
PORT = 26477
SRC_MAC, DST_MAC = "00:11:22:33:44:55", "01:00:5e:36:0c:6f"


def frame(payload: bytes, dst=GROUP, dport=PORT, pad=True, **ip_kw) -> bytes:
    pkt = Ether(src=SRC_MAC, dst=DST_MAC) / IP(src="10.0.0.1", dst=dst, **ip_kw) / UDP(
        sport=40000, dport=dport) / Raw(payload)
    b = bytes(pkt)
    return b + bytes(max(0, 60 - len(b))) if pad else b


COUNTERS = ["frames", "accepted", "drop_eth", "drop_ip", "drop_dst", "drop_csum", "drop_runt",
            "truncated"]


def counters(dut):
    return {c: int(getattr(dut, f"cnt_{c}").value) for c in COUNTERS}


async def setup(dut, seed=0, p_src=0.0, p_snk=0.0):
    dut.cfg_dst_ip.value = int(ipaddress.IPv4Address(GROUP))
    dut.cfg_dst_port.value = PORT
    await start(dut)
    src, snk = axis_pair(dut)
    if p_src:
        src.set_pause_generator(random_pause(seed, p_src))
    if p_snk:
        snk.set_pause_generator(random_pause(seed + 1, p_snk))
    cocotb.start_soon(check_axis_protocol(dut, "m_axis", has_user=True))
    cocotb.start_soon(check_lane0_aligned(dut))
    return src, snk


async def check_lane0_aligned(dut):
    """Every output beat must be lane-0 aligned: full tkeep, or a contiguous
    1..8 lanes from lane 0 on the last beat of a packet."""
    ok_last = {(1 << n) - 1 for n in range(1, 9)}
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            keep, last = int(dut.m_axis_tkeep.value), int(dut.m_axis_tlast.value)
            assert (keep in ok_last) if last else (keep == 0xFF), \
                f"misaligned beat: tkeep={keep:#04x} tlast={last}"


def last_user(f: AxiStreamFrame) -> int:
    """tuser of a packet's last beat (cocotbext-axi gives an int for 1-beat packets)."""
    return f.tuser[-1] if isinstance(f.tuser, list) else int(f.tuser or 0)


async def drain(dut, cycles=50):
    await ClockCycles(dut.clk, cycles)


@cocotb.test(timeout_time=2, timeout_unit="ms")
async def accepts_and_aligns_every_length(dut):
    """Payload lengths 1..200 and a few large ones; output must equal the payload."""
    src, snk = await setup(dut)
    lengths = list(range(1, 201)) + [1000, 1458, 1472]
    rng = random.Random(1)
    sent = []
    for n in lengths:
        p = bytes(rng.getrandbits(8) for _ in range(n))
        sent.append(p)
        await src.send(AxiStreamFrame(frame(p)))
    for i, want in enumerate(sent):
        got = await snk.recv()
        assert bytes(got.tdata) == want, f"len {len(want)}: got {bytes(got.tdata).hex()}"
        assert last_user(got) == 0, "tuser set on a good frame"
    await drain(dut)
    c = counters(dut)
    assert c["frames"] == c["accepted"] == len(lengths), c


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def drops_and_counts_by_reason(dut):
    src, snk = await setup(dut)
    good = b"KEEP-ME-" * 5
    cases = [
        ("drop_eth", bytes(Ether(dst=DST_MAC) / ARP(pdst="10.0.0.2")) + bytes(18)),
        ("drop_eth", bytes(Ether(dst=DST_MAC) / Dot1Q(vlan=7) / IP(dst=GROUP) / UDP(dport=PORT) / Raw(good))),
        ("drop_eth", bytes(Ether(dst=DST_MAC, type=0x86DD)) + bytes(60)),        # IPv6 ethertype
        ("drop_ip", bytes(Ether(dst=DST_MAC) / IP(dst=GROUP, options=[IPOption_NOP()] * 4) / UDP(dport=PORT) / Raw(good))),
        ("drop_ip", frame(good, flags="MF")),                                    # first fragment
        ("drop_ip", frame(good, frag=100)),                                      # later fragment
        ("drop_ip", bytes(Ether(dst=DST_MAC) / IP(dst=GROUP) / TCP(dport=PORT) / Raw(good))),
        ("drop_csum", frame(good, chksum=0x1234)),
        ("drop_dst", frame(good, dst="233.54.12.112")),
        ("drop_dst", frame(good, dport=PORT + 1)),
        ("drop_runt", frame(good)[:30]),                                         # ends inside IP header
        ("drop_runt", frame(good)[:40]),                                         # ends inside UDP header
    ]
    expect = {c: 0 for c in COUNTERS}
    for reason, f in cases:
        await src.send(AxiStreamFrame(f))
        await src.send(AxiStreamFrame(frame(good)))  # a good frame after every bad one
        expect[reason] += 1
    for _ in cases:
        got = await snk.recv()
        assert bytes(got.tdata) == good
    await drain(dut)
    assert snk.empty(), "a dropped frame leaked through"
    c = counters(dut)
    expect["frames"] = 2 * len(cases)
    expect["accepted"] = len(cases)
    assert c == expect, f"\n got {c}\nwant {expect}"


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def trims_padding_and_flags_truncation(dut):
    src, snk = await setup(dut)
    tiny = b"\x01\x02\x03"
    padded = frame(tiny)                              # 45 bytes padded to 60
    assert len(padded) == 60
    await src.send(AxiStreamFrame(padded))
    got = await snk.recv()
    assert bytes(got.tdata) == tiny, "padding leaked into the payload"

    full = frame(bytes(range(100)))
    await src.send(AxiStreamFrame(full[:42 + 37]))    # frame cut 63 bytes short of the UDP length
    got = await snk.recv()
    assert bytes(got.tdata) == bytes(range(37))
    assert last_user(got) == 1, "truncated payload must be flagged on its last beat"
    await drain(dut)
    assert counters(dut)["truncated"] == 1


@cocotb.test(timeout_time=10, timeout_unit="ms")
async def mixed_traffic_under_backpressure(dut):
    """5,000 random frames (70% good) with random stalls on both sides."""
    src, snk = await setup(dut, seed=7, p_src=0.3, p_snk=0.5)
    rng = random.Random(7)
    want, n_bad = [], 0
    for _ in range(5000):
        p = bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 300)))
        r = rng.random()
        if r < 0.7:
            want.append(p)
            f = frame(p)
        elif r < 0.8:
            f = frame(p, chksum=0xBEEF)
        elif r < 0.9:
            f = frame(p, dport=1234)
        else:
            f = frame(p, dst="239.1.1.1")
        n_bad += r >= 0.7
        await src.send(AxiStreamFrame(f))
    for i, w in enumerate(want):
        got = await snk.recv()
        assert bytes(got.tdata) == w, f"payload {i} differs"
    await drain(dut, 200)
    assert snk.empty()
    c = counters(dut)
    assert c["accepted"] == len(want) and c["frames"] == 5000, c
