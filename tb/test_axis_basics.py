"""Phase 1: skid buffer and FIFO under random backpressure on both sides."""
from __future__ import annotations

import random

import cocotb
from cocotb.triggers import RisingEdge
from cocotbext.axi import AxiStreamFrame

from axis_util import axis_pair, check_axis_protocol, random_pause, start

N_PACKETS = 10_000


async def run_stream(dut, seed: int, p_src: float, p_snk: float, n_packets: int = N_PACKETS):
    await start(dut)
    src, snk = axis_pair(dut)
    src.set_pause_generator(random_pause(seed, p_src))
    snk.set_pause_generator(random_pause(seed + 1, p_snk))
    cocotb.start_soon(check_axis_protocol(dut, "m_axis"))
    rng = random.Random(seed)
    sent = []
    for _ in range(n_packets):
        frame = bytes(rng.getrandbits(8) for _ in range(rng.randint(1, 40)))
        sent.append(frame)
        await src.send(AxiStreamFrame(frame))
    for i, want in enumerate(sent):
        got = await snk.recv()
        assert bytes(got.tdata) == want, f"packet {i}: {bytes(got.tdata).hex()} != {want.hex()}"
    assert snk.empty()


@cocotb.test(timeout_time=1, timeout_unit="ms")
async def skid_full_throughput(dut):
    """With no stalls the skid buffer must pass one beat per clock."""
    await start(dut)
    src, snk = axis_pair(dut)
    data = bytes(range(256)) * 8  # 2,048 bytes = 256 beats
    t0 = cocotb.utils.get_sim_time("ns")
    await src.send(AxiStreamFrame(data))
    got = await snk.recv()
    cycles = (cocotb.utils.get_sim_time("ns") - t0) / 6.4
    assert bytes(got.tdata) == data
    assert cycles < 256 + 10, f"took {cycles:.0f} cycles for 256 beats"


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def random_backpressure_light(dut):
    await run_stream(dut, seed=1, p_src=0.1, p_snk=0.1)


@cocotb.test(timeout_time=3, timeout_unit="ms")
async def random_backpressure_heavy(dut):
    await run_stream(dut, seed=2, p_src=0.5, p_snk=0.7, n_packets=3000)
