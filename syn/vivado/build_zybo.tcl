# -----------------------------------------------------------------------------
# Zybo Z7-10 build.
#   vivado -mode batch -nojournal -nolog -source build_zybo.tcl
#
# Non-project mode on purpose: no .xpr to commit, no generated project state to
# drift, and the whole build is one readable script.
#
# -include_dirs covers both `include "selftest_params.svh"` and the ROM
# $readmemh calls in tile_selftest.sv.
# -----------------------------------------------------------------------------

set part   xc7z010clg400-1
set top    zybo_z7_10_top
set outdir [file normalize build]

file mkdir $outdir

read_verilog -sv [list \
    ../../rtl/mac_pe.sv \
    ../../rtl/skew_buffer.sv \
    ../../rtl/pe_array.sv \
    ../../rtl/accum_bank.sv \
    ../../rtl/requant.sv \
    ../../rtl/out_fifo.sv \
    ../../rtl/tile_ctrl.sv \
    ../../rtl/systolic_tile.sv \
    ../../rtl/fpga/tile_selftest.sv \
    ../../rtl/fpga/selftest_shell.sv \
    ../../rtl/fpga/zybo_z7_10_top.sv \
]

read_xdc zybo_z7_10.xdc

# Timing-focused directives. These are NOT what closes 125 MHz -- the
# `(* use_dsp = "yes" *)` on mac_pe is, by moving the PE multiply-accumulate out
# of fabric and into a DSP48E1. Tried on their own against the fabric mapping
# these directives actually made the critical path slightly worse (-0.111 ns vs
# -0.096 ns). They are kept because this is the combination that was measured at
# WNS +0.508 ns; the trade is roughly 3x the implementation runtime.
# See docs/architecture.md, "Timing".
synth_design -top $top -part $part \
    -include_dirs [list [file normalize ../../rtl/fpga]] \
    -directive PerformanceOptimized
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/post_synth_util.rpt

opt_design       -directive ExploreWithRemap
place_design     -directive ExtraTimingOpt
phys_opt_design  -directive AggressiveExplore
route_design     -directive Explore

write_checkpoint -force $outdir/post_route.dcp
report_utilization      -file $outdir/utilization.rpt
report_timing_summary   -file $outdir/timing_summary.rpt
report_clock_utilization -file $outdir/clock_util.rpt

write_bitstream -force $outdir/$top.bit

# Fail the build loudly on a timing violation rather than quietly shipping a
# bitstream that does not meet 125 MHz.
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts ""
puts "==================================================="
puts "  setup WNS : $wns ns"
puts "  hold  WHS : $whs ns"
puts "  bitstream : build/$top.bit"
puts "==================================================="

if {$wns < 0 || $whs < 0} {
    puts "TIMING FAILED"
    exit 1
}
puts "TIMING MET"
