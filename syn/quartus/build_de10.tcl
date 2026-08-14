# -----------------------------------------------------------------------------
# DE10-Standard build.   Run:  quartus_sh -t build_de10.tcl
#
# The project is created from scratch every time rather than committing a .qsf,
# so a fresh clone builds identically and there is no generated file to drift
# out of sync with the sources.
#
# PIN ASSIGNMENTS
# ---------------
# These follow the DE10-Standard User Manual. CLOCK_50, KEY[0] and LEDR[2:0]
# were cross-checked against a known-good project built for this board; the
# remainder come from the same pin table but have not been verified on hardware.
# Diff against Terasic's DE10_Standard_golden_top.qsf before programming a board
# you care about.
# -----------------------------------------------------------------------------

package require ::quartus::project
package require ::quartus::flow

set proj de10_standard
set top  de10_standard_top

project_new -overwrite $proj

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSXFC6D6F31C6
set_global_assignment -name TOP_LEVEL_ENTITY $top
set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files

# Lets `include "selftest_params.svh"` and the ROM $readmemh calls resolve.
set_global_assignment -name SEARCH_PATH ../../rtl/fpga

foreach f {
    ../../rtl/mac_pe.sv
    ../../rtl/skew_buffer.sv
    ../../rtl/pe_array.sv
    ../../rtl/accum_bank.sv
    ../../rtl/requant.sv
    ../../rtl/out_fifo.sv
    ../../rtl/tile_ctrl.sv
    ../../rtl/systolic_tile.sv
    ../../rtl/fpga/tile_selftest.sv
    ../../rtl/fpga/selftest_shell.sv
    ../../rtl/fpga/de10_standard_top.sv
} {
    set_global_assignment -name SYSTEMVERILOG_FILE $f
}

set_global_assignment -name SDC_FILE de10_standard.sdc

# Board convention: never drive an unused pin on a DE-series board.
set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"

# ---- pins -------------------------------------------------------------------
set_location_assignment PIN_AF14 -to CLOCK_50

set_location_assignment PIN_AJ4  -to KEY[0]
set_location_assignment PIN_AK4  -to KEY[1]
set_location_assignment PIN_AA14 -to KEY[2]

set_location_assignment PIN_AB30 -to SW[0]
set_location_assignment PIN_Y27  -to SW[1]
set_location_assignment PIN_AB28 -to SW[2]
set_location_assignment PIN_AC30 -to SW[3]
set_location_assignment PIN_W25  -to SW[4]
set_location_assignment PIN_V25  -to SW[5]
set_location_assignment PIN_AC28 -to SW[6]
set_location_assignment PIN_AD30 -to SW[7]

set_location_assignment PIN_AA24 -to LEDR[0]
set_location_assignment PIN_AB23 -to LEDR[1]
set_location_assignment PIN_AC23 -to LEDR[2]
set_location_assignment PIN_AD24 -to LEDR[3]
set_location_assignment PIN_AG25 -to LEDR[4]
set_location_assignment PIN_AF25 -to LEDR[5]
set_location_assignment PIN_AE24 -to LEDR[6]
set_location_assignment PIN_AF24 -to LEDR[7]
set_location_assignment PIN_AB22 -to LEDR[8]
set_location_assignment PIN_AC22 -to LEDR[9]

foreach p {CLOCK_50} {
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to $p
}
for {set i 0} {$i < 3} {incr i} {
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to KEY[$i]
}
for {set i 0} {$i < 8} {incr i} {
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to SW[$i]
}
for {set i 0} {$i < 10} {incr i} {
    set_instance_assignment -name IO_STANDARD "3.3-V LVTTL" -to LEDR[$i]
}

export_assignments

if {[catch {execute_flow -compile} err]} {
    puts "BUILD FAILED: $err"
    project_close
    exit 1
}

project_close
puts ""
puts "build complete -- reports in syn/quartus/output_files/"
puts "  Fmax:        output_files/$proj.sta.rpt"
puts "  utilisation: output_files/$proj.fit.rpt"
puts "  bitstream:   output_files/$proj.sof"
