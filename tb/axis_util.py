"""Shared cocotb helpers: clock/reset, random backpressure, AXI-Stream protocol checks."""
from __future__ import annotations

import itertools
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
from cocotbext.axi import AxiStreamBus, AxiStreamSink, AxiStreamSource


def random_pause(seed: int, p_pause: float):
    """Endless pause pattern for cocotbext-axi: True = stall this cycle."""
    rng = random.Random(seed)
    while True:
        yield rng.random() < p_pause


async def start(dut, period_ns: float = 6.4):
    """156.25 MHz clock, synchronous active-high reset for 5 cycles."""
    cocotb.start_soon(Clock(dut.clk, period_ns, units="ns").start())
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def axis_pair(dut, s_prefix="s_axis", m_prefix="m_axis"):
    src = AxiStreamSource(AxiStreamBus.from_prefix(dut, s_prefix), dut.clk, dut.rst)
    snk = AxiStreamSink(AxiStreamBus.from_prefix(dut, m_prefix), dut.clk, dut.rst)
    return src, snk


async def check_axis_protocol(dut, prefix: str, has_keep: bool = True, has_user: bool = False):
    """AXI-Stream rules on an output port, checked every cycle:
    while tvalid is high and tready is low, tvalid must stay high and
    tdata/tkeep/tlast/tuser must not change (no beat may be withdrawn or altered)."""
    sig = lambda n: getattr(dut, f"{prefix}_{n}")
    fields = ["tdata", "tlast"] + (["tkeep"] if has_keep else []) + (["tuser"] if has_user else [])
    held = None
    while True:
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.rst.value):
            held = None
            continue
        valid, ready = int(sig("tvalid").value), int(sig("tready").value)
        now = {f: int(sig(f).value) for f in fields}
        if held is not None:
            assert valid, f"{prefix}: tvalid dropped before the beat was accepted"
            assert now == held, f"{prefix}: payload changed while stalled: {held} -> {now}"
        held = now if (valid and not ready) else None
