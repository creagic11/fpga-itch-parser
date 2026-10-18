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
| 1 | AXI-Stream skid buffer and FIFO, random-backpressure tests, protocol checker | |
| 2 | Ethernet/IPv4/UDP receive: filters, header checksum, 2-byte realignment | |
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
