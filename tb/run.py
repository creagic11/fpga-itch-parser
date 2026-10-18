#!/usr/bin/env python3
"""Build and run every cocotb test bench with Verilator (default) or Icarus.

    python3 tb/run.py                 # all benches
    python3 tb/run.py axis_skid       # one bench
    SIM=icarus python3 tb/run.py      # other simulator
    WAVES=1 python3 tb/run.py ...     # dump FST waveforms into sim_build/<bench>/

Exit status is non-zero if any test fails.
"""
from __future__ import annotations

import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from cocotb.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
TB = ROOT / "tb"

# bench name -> (toplevel, test module, rtl files)
BENCHES = {
    "axis_skid": ("wrap_axis_skid", "test_axis_basics", ["axis_skid.sv"]),
    "axis_fifo": ("wrap_axis_fifo", "test_axis_basics", ["axis_fifo.sv"]),
    "udp_rx":    ("udp_rx_top",     "test_udp_rx",      ["axis_skid.sv", "eth_ip_udp_rx.sv",
                                                         "realign.sv", "udp_rx_top.sv"]),
    "mold":      ("mold_framer",    "test_mold_framer", ["mold_framer.sv"]),
    "book":      ("book_engine",    "test_book_engine", ["book_engine.sv"]),
    "itch_book": ("itch_book_top",  "test_itch_book",   ["axis_skid.sv", "axis_fifo.sv",
                                                         "eth_ip_udp_rx.sv", "realign.sv",
                                                         "udp_rx_top.sv", "mold_framer.sv",
                                                         "itch_decode.sv", "itch_rx_top.sv",
                                                         "book_engine.sv", "itch_book_top.sv"]),
    "itch_rx":   ("itch_rx_top",    "test_itch_rx",     ["axis_skid.sv", "axis_fifo.sv",
                                                         "eth_ip_udp_rx.sv", "realign.sv",
                                                         "udp_rx_top.sv", "mold_framer.sv",
                                                         "itch_decode.sv", "itch_rx_top.sv"]),
}


def run(name: str) -> bool:
    top, module, files = BENCHES[name]
    sim = os.environ.get("SIM", "verilator")
    sources = [RTL / f for f in files] + sorted((TB / "wrappers").glob("*.sv"))
    build_dir = ROOT / "sim_build" / name
    waves = os.environ.get("WAVES") == "1"
    build_args = []
    if sim == "verilator":
        build_args = ["-Wno-fatal", "-Wall", "-Wno-DECLFILENAME", "-Wno-UNUSEDSIGNAL",
                      "-Wno-MULTITOP", "--top-module", top]
        if waves:
            build_args += ["--trace-fst", "--trace-structs"]
    else:
        build_args = ["-g2012"]
    runner = get_runner(sim)
    runner.build(verilog_sources=[str(s) for s in sources], hdl_toplevel=top,
                 build_args=build_args, build_dir=str(build_dir), always=True, waves=waves)
    results = build_dir / "results.xml"
    runner.test(hdl_toplevel=top, test_module=module, test_dir=str(TB), build_dir=str(build_dir),
                results_xml=str(results), waves=waves,
                extra_env={"PYTHONPATH": str(TB),
                           **{k: v for k, v in os.environ.items()
                              if k.startswith("ITCH_") or k == "LATENCY_OUT"}})
    tree = ET.parse(results)
    failures = [tc.get("name") for tc in tree.iter("testcase") if tc.find("failure") is not None]
    total = sum(1 for _ in tree.iter("testcase"))
    print(f"[{name}] {total - len(failures)}/{total} passed" + (f"; FAILED: {failures}" if failures else ""))
    return not failures


if __name__ == "__main__":
    sys.path.insert(0, str(TB))
    names = sys.argv[1:] or [n for n in BENCHES if (RTL / BENCHES[n][2][-1]).exists()]
    ok = all([run(n) for n in names])
    sys.exit(0 if ok else 1)
