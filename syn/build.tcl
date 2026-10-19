# Vivado non-project flow: synthesis, implementation and reports, out of context.
#
#   vivado -mode batch -source syn/build.tcl -tclargs [TOP] [PART]
#
# Out-of-context mode: the design is implemented as a block inside a larger FPGA
# design, with no I/O buffers on its ports. That is the standard way to get the
# timing and size of a datapath block; a full board design would add a MAC/PHY.
# Reports land in syn/reports/ (committed); checkpoints in syn/out/ (ignored).

set script_dir [file dirname [file normalize [info script]]]
set root       [file dirname $script_dir]
set top  [expr {[llength $argv] > 0 ? [lindex $argv 0] : "itch_book_top"}]
set part [expr {[llength $argv] > 1 ? [lindex $argv 1] : "xc7a100tcsg324-1"}]
set out  [file join $root syn out]
set rpt  [file join $root syn reports]
file mkdir $out $rpt

puts "== top $top  part $part"
read_verilog -sv [glob [file join $root rtl *.sv]]
read_xdc -mode out_of_context [file join $script_dir constraints.xdc]

synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy rebuilt
report_utilization    -file [file join $rpt ${top}_synth_utilization.rpt]

# opt_design's block-RAM power optimisation adds enable-gating logic in front of
# the RAMs (cells named *cooolgate*); it cost 1.2 ns on run 4. Timing first.
set_power_opt -exclude_cells [get_cells -hier -quiet -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]
opt_design
# Timing-driven directives (slower runs, better results), and a physical
# optimisation pass after routing as well as after placement.
place_design    -directive ExtraTimingOpt
phys_opt_design -directive AggressiveExplore
route_design    -directive AggressiveExplore
phys_opt_design -directive AggressiveExplore

report_timing_summary -max_paths 10 -report_unconstrained -file [file join $rpt ${top}_timing_summary.rpt]
report_timing -sort_by group -max_paths 10 -nworst 1 -file [file join $rpt ${top}_critical_paths.rpt]
report_utilization    -file [file join $rpt ${top}_utilization.rpt]
report_utilization    -hierarchical -file [file join $rpt ${top}_utilization_hier.rpt]
write_checkpoint -force [file join $out ${top}_post_route.dcp]

# Worst setup slack ending in each module, so a failing run shows every block
# that needs work, not only the single worst path.
file delete -force [file join $rpt ${top}_failing_paths.rpt]
set fh [open [file join $rpt ${top}_slack_by_module.rpt] w]
puts $fh [format "%-40s %10s %7s  %s" "module instance" "WNS (ns)" "levels" "worst path start -> end"]
set all_regs [get_cells -quiet -hier -filter {IS_SEQUENTIAL}]
foreach inst [lsort [get_cells -hier -filter {IS_PRIMITIVE == 0}]] {
    # Prefix match in plain Tcl: instance names contain brackets (g_way[0]),
    # which a -filter glob would read as a character class.
    set pre "$inst/"
    set n [string length $pre]
    set regs {}
    foreach c $all_regs { if {[string equal -length $n $pre $c]} { lappend regs $c } }
    if {[llength $regs] == 0} continue
    set p [get_timing_paths -quiet -setup -max_paths 1 -nworst 1 -to $regs]
    if {[llength $p] == 0} continue
    set line [format "%-40s %10.3f %7s  %s -> %s" $inst [get_property SLACK $p] \
              [get_property LOGIC_LEVELS $p] [get_property STARTPOINT_PIN $p] [get_property ENDPOINT_PIN $p]]
    puts $fh $line
    puts "== slack $line"
    # full path detail for every failing block
    if {[get_property SLACK $p] < 0} {
        report_timing -of_objects $p -file [file join $rpt ${top}_failing_paths.rpt] -append
    }
}
close $fh

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set period [get_property PERIOD [get_clocks clk]]
puts [format "== RESULT top=%s part=%s period=%.3fns WNS=%.3fns WHS=%.3fns %s" \
      $top $part $period $wns $whs [expr {$wns >= 0 && $whs >= 0 ? "TIMING MET" : "TIMING FAILED"}]]
puts [format "== Fmax estimate: %.1f MHz" [expr {1000.0 / ($period - $wns)}]]
