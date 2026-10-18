# fpga-itch-parser

A SystemVerilog pipeline that takes Ethernet frames carrying Nasdaq TotalView-ITCH 5.0 market
data (over MoldUDP64) and maintains the best bid and offer of a stock in hardware. 64-bit
AXI-Stream at 156.25 MHz (the 10 Gb/s datapath), verified in cocotb against a C++ golden model,
synthesised and timed in Vivado for an Artix-7.

> Work in progress, built phase by phase. Simulation and Vivado reports only: no board.

## Status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Makefile, Verilator lint, cocotb runner, CI, Vivado batch flow | done |
| 1 | AXI-Stream skid buffer and FIFO, random-backpressure tests, protocol checker | done |
| 2 | Ethernet/IPv4/UDP receive: filters, header checksum, 2-byte realignment | done |
| 3 | MoldUDP64 framer: message splitting across beats, sequence gaps | |
| 4 | ITCH 5.0 decoder and symbol filter | |
| 5 | Top-of-book engine (BRAM order table, price ladder) | |
| 6 | End-to-end verification against the C++ book on real data | |
| 7 | Synthesis and timing closure | |
| 8 | Write-up | |

## Running

```bash
pip install -r requirements.txt      # cocotb, cocotbext-axi, scapy
sudo apt install verilator iverilog  # Ubuntu / WSL2
make lint                            # Verilator -Wall on every synthesizable top
make test                            # all cocotb benches (SIM=icarus for Icarus)
WAVES=1 python3 tb/run.py udp_rx     # one bench, FST waveforms in sim_build/udp_rx/
```

Vivado (synthesis, place and route, timing and utilisation reports, out of context):

```bat
syn\build.bat                        :: Windows, Vivado 2024.1
```
```bash
make syn                             # Linux
```

## Design so far

```
frames ─▶ eth_ip_udp_rx ─▶ axis_skid ─▶ realign ─▶ UDP payload, lane 0 aligned
            │ filters, IPv4 checksum, trim to UDP length
            └ counters: frames, accepted, drop by reason, truncated
```

- **eth_ip_udp_rx.** All header fields needed to accept or drop a frame arrive by beat 4, and the IPv4 checksum is summed as the beats arrive. The decision is registered as the payload starts (byte 42, beat 5, lane 2), so no extra latency is added. Drops: non-IPv4 (incl. VLAN), IP options, fragments, non-UDP, bad checksum, other destination IP or port, frames ending inside the headers. The payload is trimmed to the UDP length, which strips Ethernet padding; a frame ending early is flagged with `tuser`.
- **realign.** Shifts the payload 2 bytes so every message stream starts at lane 0: output beat k = input beat k lanes 2..7 + input beat k+1 lanes 0..1, plus one flush beat when the last input beat has bytes left in lanes 2..7.
- **axis_skid.** Two-entry register slice between stages, so `tready` is never a long combinational chain.

## Verification

| Bench | What is checked |
| --- | --- |
| `axis_skid`, `axis_fifo` | 10,000 random packets with light stalls and 3,000 with the sink stalled 70% of cycles; one beat per clock with no stalls |
| `udp_rx` | every payload length 1-200 plus 1000/1458/1472 bytes; each drop reason counted exactly; padding trimmed; truncation flagged; 5,000 mixed good/bad frames under random stalls on both sides |

Frames come from scapy, an independent implementation of the protocols. Every output port is checked each cycle for AXI-Stream rule violations (`tvalid` dropped or payload changed while stalled), and every output beat is checked to be lane-0 aligned. Planted bugs (a skid buffer that overwrites a stalled beat, a checksum that skips a word, a realigner that loses the last bytes) each make the benches fail.
