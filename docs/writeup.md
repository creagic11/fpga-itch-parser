# Top of book from the wire: an ITCH 5.0 feed handler in SystemVerilog

This is the write-up for `fpga-itch-parser`: a receive pipeline that takes Ethernet frames carrying
Nasdaq TotalView-ITCH 5.0 market data and keeps the best bid and offer of one stock, in hardware,
at the 156.25 MHz clock of a 10 Gb/s Ethernet datapath. It was verified in simulation against an
independent C++ order book on real Nasdaq data, then implemented in Vivado for an Artix-7 until
timing closed. There is no board: everything below is simulation and place-and-route.

## 1. The problem

A market-data feed handler turns exchange packets into an order book. In software the work per
message is a hash lookup and a few comparisons, and the cost is everything around it: the kernel
network stack, cache misses, scheduling. An FPGA removes those by doing the work as the bytes arrive.
The interesting part is that a byte stream with variable-length messages, packed at arbitrary
offsets into 8-byte bus words, has to be cut into messages and applied to a book at line rate,
every clock cycle, with no software in the path.

Inputs and outputs:

- **In:** Ethernet frames on a 64-bit AXI-Stream bus (8 bytes per cycle at 156.25 MHz = 10 Gb/s).
  Inside: IPv4, UDP, then MoldUDP64 (Nasdaq's sequenced packet format), then ITCH messages.
- **Out:** a best-bid-and-offer update (price, size, sequence number) whenever the top of book of the
  chosen stock changes, using the same rule as the C++ book in
  [lowlat-orderbook](https://github.com/creagic11/lowlat-orderbook).

## 2. Architecture

```
frames -> eth_ip_udp_rx -> skid -> realign -> FIFO -> skid -> mold_framer -> skid -> itch_decode -> book_engine -> BBO
           headers,          2-byte shift   64 deep     32-byte ring,          type, fields,      order table,
           checksum,                                    sequence numbers       stock filter       price ladder,
           filters                                                                                priority encoders
```

| Block | Job | Key decision |
| --- | --- | --- |
| `eth_ip_udp_rx` | Accept or drop each frame: EtherType, IPv4 header, checksum, destination, UDP length | Every field needed is known by beat 4, so the payload is forwarded from beat 5 with no added delay; header checks are registered beat by beat as they arrive |
| `realign` | Shift the payload by 2 bytes so the UDP payload starts at lane 0 | Fixed 2-byte shift: one register stage, no barrel shifter |
| `mold_framer` | Split MoldUDP64 packets into ITCH messages; track sequence numbers, gaps, duplicates | 32-byte **ring buffer**: consuming bytes moves a pointer, data never shifts; next message length read one beat ahead |
| `itch_decode` | Type, length check, field extraction, stock filter | Every field the book needs is in the first 40 bytes at a fixed offset per type: capture 5 beats, then a type-indexed mux |
| `book_engine` | Apply Add/Execute/Cancel/Delete/Replace; find the best bid and offer | 4-way set-associative order table in block RAM; 4,096-tick price window per side; bitmap of non-empty levels with a two-level priority encoder |

**Order table.** Order references are 64-bit, but Nasdaq assigns them in increasing order through
the day, so the low 12 bits spread live orders evenly over 4,096 sets. Each set has 4 ways
(78-bit entries: valid, side, 32-bit tag, price index, shares). A full set counts as a collision;
on the real-data run there were none.

**Price ladder.** Prices map to a 4,096-tick window per side above a configured base. The division
by the tick size (100 ITCH units) is a multiply by 5,243 and a shift by 19 in a DSP block, exact for
every multiple of 100 below 2^19; a round-trip check rejects off-grid prices. Level quantities live in
block RAM; a 4,096-bit bitmap per side marks non-empty levels. When the best level empties, a
two-level priority encoder (a 64-bit summary of non-empty words, then the chosen 64-bit word) finds the
next one in a fixed number of cycles: no search loop, no data-dependent latency.

## 3. Results

| Measure | Value |
| --- | --- |
| Clock | **156.25 MHz met** on Artix-7 xc7a100t, slowest speed grade (WNS +0.141 ns, Fmax 159.8 MHz) |
| Resources | 16.4k LUTs (26%), 13.4k flip-flops (11%), 48.5 block RAM tiles (36%), 1 DSP |
| Wire-to-BBO latency | 52 cycles = 333 ns for an Add that improves the bid, from the frame's first beat; 13 of those cycles are the 100-byte frame arriving. Identical on every run: no caches, no arbitration |
| Framer throughput | 3.13 cycles per message for back-to-back 19-byte Deletes (6.7 of 8 bytes per cycle); typical messages at line rate |
| Book throughput | about 26 cycles per event, ~6 M events/s: far above any single stock's message rate |
| Correctness on real data | first 1,000,000 messages of the Nasdaq BX feed of 30 Dec 2019, stock UGAZ: **9,295 BBO updates identical to the C++ book**, 0 gaps, 0 collisions, 0 unknown references |

## 4. Timing closure: six runs from 59 to 160 MHz

Simulation proves the logic; place-and-route decides whether it runs at the target clock. On the
slowest Artix-7 speed grade, a 6.4 ns cycle allows only about 6-7 levels of logic once routing is
counted, and on this design routing turned out to be 60-90% of every critical path.

| Run | Fmax | What limited it | What fixed it |
| --- | --- | --- | --- |
| 1 | — | The order table as one 1.28 Mbit array: over Vivado's 1 Mbit per-variable limit | One block-RAM instance per way |
| 2 | 59 MHz | Book: price minus base, divide by 100, and the order-table write in one cycle (21 logic levels) | One step per state; RAM output registers; divide as a DSP multiply-and-shift |
| 3 | 115 MHz | Every block 0.6-2.3 ns short: checksum add-fold-compare before the accept decision, decoder checks in the last-beat cycle, RAM write ports and an 8,192-bit bitmap fed across the chip | Checksum verdict one cycle later as a plain compare; decode one cycle after capture; registered RAM writes; bitmap written from pre-decoded word and bit enables |
| 4 | 107 MHz (worse) | My run-3 framer fix appended the input beat and then shifted a 24-byte buffer in the same cycle, with the FIFO's unregistered block-RAM output (2.5 ns) at the front | See run 5 |
| 5 | 148 MHz | Framer replaced by a ring buffer behind a register slice; RAM read addresses registered inside each RAM (one address register had been driving 36 RAM tiles); RAM power-gating logic disabled. Left: three paths 0.08-0.36 ns short | See run 6 |
| 6 | **160 MHz, met** | — | Next message length read one beat earlier into raw registers; 64-bit priority encoders over two cycles; checksum fold with both carry outcomes computed in parallel |

What I took from it:

- **Data that moves every cycle is expensive.** A 24-byte buffer shifted by a variable amount each
  cycle is a 25-way mux on 192 bits whose select comes out of the parser's own decision logic. A ring
  buffer moves a 5-bit pointer instead. This single change was worth more than all the others.
- **Routing, not logic, was the limit after run 3.** One path that failed by 1.6 ns had zero logic
  levels: an address register driving 36 block-RAM tiles spread over the die. Registering the address
  inside each RAM instance, and turning off Vivado's RAM power optimisation (which had inserted gating
  logic in front of the RAMs), fixed what no amount of logic restructuring would have.
- **Look ahead instead of computing late.** The framer must know how many bytes the next message
  takes before it can decide anything. Reading the next length on the second-to-last beat of the
  current message, when its position is already a register, turned a 7-level path into a 3-level one
  at no throughput cost.
- **Measure, then fix the named block.** From run 3 on, the build script writes the worst path into
  every module (`slack_by_module.rpt`) and the full detail of each failing one. Every fix after that
  targeted a path Vivado had actually reported, not a guess.
- **A fix can make it worse.** Run 4 regressed because the run-3 framer change put a slow source in
  series with the shifter. The per-module report showed it immediately.

The cost of closing timing was latency: 30 cycles (192 ns) in the first version, 52 cycles (333 ns)
at 156.25 MHz. Each added cycle is a register that bought the clock period back.

## 5. Verification

- **Benches.** cocotb 1.9.2 with Verilator 5.020, one bench per block plus the full design: 7 benches
  in CI. Frames are built with scapy, an independent implementation of Ethernet, IPv4 and UDP. Every
  output port is checked every cycle for AXI-Stream rule violations, every output beat for lane-0
  alignment, and every bench runs with random stalls on both sides.
- **Golden models.** A Python model of each block's rules (including the hardware's limits: window
  edges, set collisions), an unbounded Python order book for random event streams, and the C++ book
  from `lowlat-orderbook` on real Nasdaq data.
- **Planted bugs.** For every block, and again after every timing change, I planted small bugs (an
  off-by-one in a length check, the wrong priority direction, a pointer not advanced, a skipped
  carry) and confirmed a bench fails. Twice a planted bug passed, and each time it exposed a
  missing test: a UDP length exactly one byte too long, and a checksum whose fold carries (which a valid header can never produce, so the test builds a bad header that
  only a fold without its end-around carry would accept).
- **Bugs the tests found in the design.** Block RAMs keep their contents through a reset (the
  second test saw the first test's orders: fixed with a clear pass after reset). The framer's buffer
  was not cleared by reset, so leftover bytes corrupted the next packet's sequence number and the
  packet was dropped as a duplicate (found on the full design, then reproduced in a unit test).

## 6. Limits and what is not claimed

- No board and no MAC/PHY: the design is implemented out of context, as a block inside a larger
  FPGA design. A real 10 Gb/s system needs transceivers (an Artix-7 100T has none fast enough; a
  Kintex-7 or UltraScale+ part would be the real target) and a MAC in front of `eth_ip_udp_rx`.
- One stock per book engine, a 4,096-tick window per side, 16,384 live orders per stock (4,096 sets
  x 4 ways). Orders outside the window or in a full set are counted, not booked.
- Events are processed one at a time (~26 cycles each). That is ample for one stock; a full-feed book
  would pipeline events with read-after-write forwarding, or run one engine per stock.
- Latency is measured in simulation at the target clock, not on hardware.

## 7. What I would do next

- Pipeline the book engine across events (forwarding for same-order and same-level hazards) to cut
  per-event cycles from ~26 to a few.
- Multiple stocks: several book engines behind the decoder's locate filter.
- Retarget to a Kintex-7 or UltraScale+ part with a 10G MAC and run it on a board with a packet
  generator, to measure real wire-to-wire latency.

## Running it

See the README for commands. In short: `make test` runs every bench; the real-data check needs the
Nasdaq sample file (`ITCH_REAL=... ITCH_GOLDEN=... python3 tb/run.py itch_book`); `syn\build.bat`
runs Vivado and writes the reports in `syn/reports/`.
