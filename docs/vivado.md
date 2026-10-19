# Running Vivado (Phase 7)

Vivado 2024.1 on Windows, out-of-context implementation of the whole design
(`itch_book_top`) on an Artix-7 100T (xc7a100tcsg324-1) at 156.25 MHz.

1. Open a Command Prompt in the repository folder (the one containing `syn\`).
2. Run:

   ```bat
   syn\build.bat
   ```

   `build.bat` finds Vivado through `C:\Xilinx\Vivado\2024.1\settings64.bat`; edit that line if
   Vivado is installed elsewhere. Synthesis, placement and routing take about 10–20 minutes.
3. The last lines print the result, for example:

   ```
   == RESULT top=itch_book_top part=xc7a100tcsg324-1 period=6.400ns WNS=0.412ns WHS=0.031ns TIMING MET
   == Fmax estimate: 166.9 MHz
   ```

4. Reports are written to `syn\reports\`:
   `itch_book_top_timing_summary.rpt`, `itch_book_top_critical_paths.rpt`,
   `itch_book_top_utilization.rpt`, `itch_book_top_utilization_hier.rpt`,
   `itch_book_top_slack_by_module.rpt`.
   Send these five files back (or commit them). The slack-by-module report lists the worst
   path ending in each block (also printed as `== slack` lines), so a failing run shows every
   block that needs pipelining, not only the worst one. If any block fails, a sixth file,
   `itch_book_top_failing_paths.rpt`, holds the full path of each failing block: send it too.

Other tops: `syn\build.bat udp_rx_top` (receiver only), `syn\build.bat book_engine`.
