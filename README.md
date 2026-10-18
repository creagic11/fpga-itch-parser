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
| 3 | MoldUDP64 framer: message splitting across beats, sequence gaps | done |
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
frames ─▶ eth_ip_udp_rx ─▶ axis_skid ─▶ realign ─▶ mold_framer ─▶ one packet per ITCH message
            │ filters, IPv4 checksum,                   │ + its sequence number
            │ trim to UDP length                        └ gaps, duplicates, heartbeats, errors
            └ counters: frames, accepted, drop by reason, truncated
```

- **eth_ip_udp_rx.** All header fields needed to accept or drop a frame arrive by beat 4, and the IPv4 checksum is summed as the beats arrive. The decision is registered as the payload starts (byte 42, beat 5, lane 2), so no extra latency is added. Drops: non-IPv4 (incl. VLAN), IP options, fragments, non-UDP, bad checksum, other destination IP or port, frames ending inside the headers. The payload is trimmed to the UDP length, which strips Ethernet padding; a frame ending early is flagged with `tuser`.
- **realign.** Shifts the payload 2 bytes so every message stream starts at lane 0: output beat k = input beat k lanes 2..7 + input beat k+1 lanes 0..1, plus one flush beat when the last input beat has bytes left in lanes 2..7.
- **axis_skid.** Two-entry register slice between stages, so `tready` is never a long combinational chain.
- **mold_framer.** A 24-byte buffer: input beats are appended behind the bytes held, and the parser consumes from the front, so a message may start at any byte and a length field may straddle two beats. The 2-byte length and the first 8 message bytes leave in the same cycle, so a message costs one cycle per output beat. Sequence tracking: a packet starting beyond the expected number is a gap (counted, with the missing count); messages below it are duplicates (for example the other copy of an A/B feed) and are dropped. Heartbeats and end-of-session are recognised. A packet ending inside a message closes it with `tuser` set.

## Verification

| Bench | What is checked |
| --- | --- |
| `axis_skid`, `axis_fifo` | 10,000 random packets with light stalls and 3,000 with the sink stalled 70% of cycles; one beat per clock with no stalls |
| `udp_rx` | every payload length 1-200 plus 1000/1458/1472 bytes; each drop reason counted exactly; padding trimmed; truncation flagged; 5,000 mixed good/bad frames under random stalls on both sides |
| `mold` | 1,520 messages of 1-80 and 200-600 bytes (every start lane); heartbeats, gaps, duplicate packets, end of session; cut header, cut message, trailing bytes; 20,000 messages under random stalls; sequence number checked on every message |

Frames come from scapy, an independent implementation of the protocols. Every output port is checked each cycle for AXI-Stream rule violations (`tvalid` dropped or payload changed while stalled), and every output beat is checked to be lane-0 aligned. Planted bugs (a skid buffer that overwrites a stalled beat, a checksum that skips a word, a realigner that loses the last bytes, a framer reading the body one byte off, a duplicate count off by one) each make the benches fail.

**Throughput (simulation).** Worst case for the framer is a stream of 19-byte Delete messages (21 bytes with the length): 3.22 cycles per message including per-packet header handling, i.e. 6.5 of the 8 input bytes per cycle. Typical ITCH traffic (Adds are 36 bytes) is at line rate.
