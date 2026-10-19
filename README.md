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
| 4 | ITCH 5.0 decoder and symbol filter | done: verified on 1M real Nasdaq messages |
| 5 | Top-of-book engine (BRAM order table, price ladder) | done |
| 6 | End-to-end verification against the C++ book on real data | done: 1M real messages, 9,295 BBO updates identical to the C++ book; 320 ns wire-to-BBO |
| 7 | Synthesis and timing closure | in progress: 59 MHz, then 115 MHz after re-pipelining the book engine; every block now pipelined for 156.25 MHz |
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
frames ─▶ eth_ip_udp_rx ─▶ skid ─▶ realign ─▶ FIFO ─▶ mold_framer ─▶ skid ─▶ itch_decode ─▶ book events
            │ filters, IPv4 checksum,                    │ messages + sequence     │ type, locate, ts, ref,
            │ trim to UDP length                         │ numbers; gaps, dups,    │ new ref, shares, price,
            └ drop counters by reason                    └ heartbeats, errors      └ side, seq; stock filter
```

`itch_rx_top` is the whole receive chain, Ethernet frames to decoded order-book events;
`itch_book_top` adds the `book_engine` and is the full design: Ethernet frames in, best bid
and offer of one stock out.

## Results

**Real Nasdaq data, FPGA vs C++.** The first 1,000,000 messages of the Nasdaq BX day of
30 Dec 2019 are packed into MoldUDP64 packets inside Ethernet frames and fed to
`itch_book_top` with the filter on UGAZ (locate 8124, base price $58.29, the stock's whole
price range fits the 4,096-tick window). The C++ order book from
[lowlat-orderbook](https://github.com/creagic11/lowlat-orderbook) replays the same file
(`replay --locate 8124 --bbo-out`). **The FPGA's 9,295 BBO updates are identical to the C++
book's, record for record** (price, size and sequence number on both sides), with 0 gaps,
0 bad messages, 0 out-of-window orders, 0 set collisions and 0 unknown references.

```bash
ITCH_REAL=20191230.BX_ITCH_50 ITCH_REAL_N=1000000 ITCH_GOLDEN=ugaz.bbo \
ITCH_LOCATE=8124 ITCH_BASE=582900 python3 tb/run.py itch_book
```

**Wire-to-BBO latency (simulation, 156.25 MHz).** A 100-byte frame carrying one Add that
improves the bid: **50 cycles = 320 ns** from the frame's first beat entering the design to the
BBO update leaving it, of which 13 cycles are the frame itself arriving at 8 bytes per cycle.
A Delete of the best bid (the priority encoder finds the next level): 48 cycles. Every
measurement is identical (min = median = max), as expected of a design with no caches or
arbitration on this path. (The first version took 30 cycles but reached only 59 MHz in
Vivado; pipelining every block for 156.25 MHz added 20 cycles, see *Timing closure*.)

**Throughput.** The receive chain keeps up with 10 Gb/s line rate for typical ITCH traffic;
the framer's worst case (back-to-back 19-byte Deletes) is 6.7 of 8 bytes per cycle. The book
engine takes about 24 cycles per event (random mix), about 6.5 M events/s, far above the
message rate of any single stock.

- **eth_ip_udp_rx.** All header fields needed to accept or drop a frame arrive by beat 4, and the IPv4 checksum is summed as the beats arrive. The decision is made as the payload starts (byte 42, beat 5, lane 2), so no extra latency is added; the checksum verdict alone is taken one cycle later, while beat 5 is presented, as a plain comparison (the folded sum of the first nine words must be the complement of the tenth). Drops: non-IPv4 (incl. VLAN), IP options, fragments, non-UDP, bad checksum, other destination IP or port, frames ending inside the headers. The payload is trimmed to the UDP length, which strips Ethernet padding; a frame ending early is flagged with `tuser`.
- **realign.** Shifts the payload 2 bytes so every message stream starts at lane 0: output beat k = input beat k lanes 2..7 + input beat k+1 lanes 0..1, plus one flush beat when the last input beat has bytes left in lanes 2..7.
- **axis_skid.** Two-entry register slice between stages, so `tready` is never a long combinational chain.
- **itch_decode.** Every field the book needs lies in a message's first 40 bytes, so five beats are captured and fields are cut at fixed offsets per type: no searching, just a type-indexed mux. The last beat is captured like the others, and the message is checked and decoded from registers in the next cycle. The length is checked against the type (all 23 ITCH 5.0 types), non-book messages are counted and dropped, and an optional filter keeps one stock (by locate code). Event codes match the C++ decoder in `lowlat-orderbook`.
- **book_engine.** Top of book for one stock. Orders live in a 4-way set-associative table in block RAM (4,096 sets indexed by the low bits of the order reference, 32-bit tags); a full set is counted as a collision. Prices map into a 4,096-tick window per side ($40.96 at $0.01 ticks) with level quantities in block RAM and a bitmap of non-empty levels; a two-level priority encoder (64-bit summary, then the 64-bit word) finds the next best price when the best level empties. Each event runs through a pipelined sequence of single-step states (about 24 cycles per event, two passes for a Replace), every block RAM has registered read address, write port and output, a bitmap bit is written from one-hot word and bit enables decoded a cycle earlier, and the price-to-level division by 100 is a multiply by 5,243 and a shift in a DSP; events are handled one at a time, so no read-after-write forwarding is needed: about 6.5 M events/s at 156.25 MHz. After reset a clear pass zeroes the block RAMs, because FPGA memories keep their contents through a reset (a bug the test bench caught: the second test saw the first test's orders).
- **mold_framer.** A 32-byte ring buffer: input bytes are written at a write pointer and the parser reads a 10-byte window at the read pointer, so a message may start at any byte and a length field may straddle two beats, and consuming bytes only moves a pointer (an earlier version shifted a 24-byte buffer by the bytes consumed, which could not run at 156.25 MHz). How many bytes to consume comes from registers only: a message's body is tracked in registers, and on its last beat the next message's length is read at a known position and consumed with the tail (length look-ahead), so the next message starts on the following cycle and a message costs one cycle per output beat. Sequence tracking: a packet starting beyond the expected number is a gap (counted, with the missing count); messages below it are duplicates (for example the other copy of an A/B feed) and are dropped. Heartbeats and end-of-session are recognised. A packet ending inside a message closes it with `tuser` set. Input bytes outside `tkeep` are never written.

## Timing closure

Vivado 2024.1, out of context on an Artix-7 100T (xc7a100tcsg324-1, the slowest speed grade),
target 156.25 MHz (6.4 ns). Each run's reports are in `syn/reports/`; `slack_by_module.rpt`
lists the worst path into every block.

| Run | Result | What limited it | Fix |
| --- | --- | --- | --- |
| 1 | synthesis error | order table as one 1.28 Mbit array (Vivado's limit is 1 Mbit per variable) | one block-RAM instance per way |
| 2 | 59.3 MHz (WNS -10.45 ns) | book engine: price, divide by 100 and order-table write in one cycle (21 logic levels) | one step per state; RAM output registers; divide as multiply-and-shift |
| 3 | 115.2 MHz (WNS -2.28 ns) | every block 0.6-2.3 ns short: checksum add-fold-compare before the accept decision; framer length to shift amount; decoder length and type checks in the last-beat cycle; RAM write ports and the 8,192-bit bitmap fed across the chip | checksum verdict one cycle later as a compare; length look-ahead in the framer; decode one cycle after capture; registered RAM write ports; bitmap write from pre-decoded word and bit enables; registered FIFO ready |
| 4 | 107.3 MHz (WNS -2.92 ns) | framer: the FIFO's block-RAM output (2.5 ns, unregistered) fed the append-then-shift buffer; way-RAM read address routed to 36 RAM tiles (0 logic levels, -1.6 ns); RAM power-gating logic; replicated bitmap flag in a 7-level path | framer as a ring buffer (pointers move, data does not) behind a register slice; read address registered inside each RAM; RAM power optimisation off; bitmap flag in one flop, copied a cycle later; header, type and checksum checks precomputed a beat early; timing-driven Vivado directives |
| 5 | pending | | |

## Verification

| Bench | What is checked |
| --- | --- |
| `axis_skid`, `axis_fifo` | 10,000 random packets with light stalls and 3,000 with the sink stalled 70% of cycles; one beat per clock with no stalls |
| `udp_rx` | every payload length 1-200 plus 1000/1458/1472 bytes; each drop reason counted exactly; padding trimmed; truncation flagged; 5,000 mixed good/bad frames under random stalls on both sides |
| `itch_rx` | full chain from Ethernet frames: 6,000 messages of all 23 ITCH types with random field values; stock filter, wrong-length and unknown messages under random stalls on input and output; **a slice of a real Nasdaq BX day (1,000,000 messages)**, every decoded field compared with a Python decoder |
| `book` | directed scenarios; 10,000 random events over ~600 levels identical to an unbounded order book (with 30% output stalls); window edges, below-base, off-grid and beyond-window prices; set collisions, duplicate refs, freed ways; every counter checked against a Python model of the hardware rules |
| `itch_book` | full design from Ethernet frames: two interleaved stocks with the filter keeping one, identical to an unbounded order book under random stalls; wire-to-BBO latency; **real Nasdaq slice vs the C++ book** (opt-in, ~12 minutes) |
| `mold` | 1,520 messages of 1-80 and 200-600 bytes (every start lane); heartbeats, gaps, duplicate packets, end of session; cut header, cut message, trailing bytes; 20,000 messages under random stalls; sequence numbers with every byte non-zero; junk in bytes outside `tkeep`; reset while the buffer holds part of a packet; sequence number checked on every message |

Frames come from scapy, an independent implementation of the protocols. Every output port is checked each cycle for AXI-Stream rule violations (`tvalid` dropped or payload changed while stalled), and every output beat is checked to be lane-0 aligned. Planted bugs (a skid buffer that overwrites a stalled beat, a checksum that skips a word, a realigner that loses the last bytes, a framer reading the body one byte off, a duplicate count off by one, a Replace price read one byte off, a stock filter that ignores its setting, a best-ask search that picks the highest word, a partial execution that is not stored, a level quantity that is never reduced, an off-grid price check that is skipped, a framer buffer not cleared by reset) each make the benches fail.

**Real data.** `ITCH_REAL=/path/to/20191230.BX_ITCH_50 ITCH_REAL_N=1000000 python3 tb/run.py itch_rx` packs the first N messages of a Nasdaq sample file into MoldUDP64 packets inside Ethernet frames and checks every decoded event. The data file is not in the repo (`scripts` in `lowlat-orderbook` downloads it).

**Throughput (simulation).** Worst case for the framer is a stream of 19-byte Delete messages (21 bytes with the length): 3.13 cycles per message including per-packet header handling, i.e. 6.7 of the 8 input bytes per cycle. Typical ITCH traffic (Adds are 36 bytes) is at line rate.
