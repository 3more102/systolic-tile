# -----------------------------------------------------------------------------
# Constraints -- Digilent Zybo Z7-10 (xc7z010clg400-1).
#
# Pin data from the official Digilent Zybo-Z7-Master.xdc. sysclk, btn[0],
# led[3:0] and the LD6 green channel were cross-checked against a known-good
# project built for this board.
#
# The design is single-clock and fully synchronous. Buttons and the switch are
# genuinely asynchronous and are resynchronised in selftest_shell, so cutting
# them is correct rather than a way to hide a real path.
# -----------------------------------------------------------------------------

## 125 MHz PL oscillator
set_property -dict { PACKAGE_PIN K17 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -period 8.000 -name sysclk -waveform {0.000 4.000} [get_ports { sysclk }]

## Buttons (read high when pressed)
set_property -dict { PACKAGE_PIN K18 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]

## Switch SW0
set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports { sw0 }]

## User LEDs LD0-LD3
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN M15 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN G14 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN D18 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Green channel of RGB LED LD6
set_property -dict { PACKAGE_PIN F17 IOSTANDARD LVCMOS33 } [get_ports { led6_g }]

## Asynchronous I/O -- resynchronised inside the design, no external timing spec
set_false_path -from [get_ports { btn[*] }]
set_false_path -from [get_ports { sw0 }]
set_false_path -to   [get_ports { led[*] }]
set_false_path -to   [get_ports { led6_g }]
