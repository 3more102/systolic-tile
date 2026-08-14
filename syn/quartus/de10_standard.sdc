# -----------------------------------------------------------------------------
# Timing constraints -- Terasic DE10-Standard.
#
# The design is single-clock and fully synchronous, so the whole constraint set
# is one create_clock plus the I/O exceptions. Buttons and switches are
# genuinely asynchronous and are synchronised in selftest_shell, so cutting them
# is correct rather than a way to hide a real path. LEDs drive nothing that
# cares about timing.
# -----------------------------------------------------------------------------

create_clock -name CLOCK_50 -period 20.000 [get_ports CLOCK_50]

derive_clock_uncertainty

# Asynchronous inputs -- resynchronised inside the design.
set_false_path -from [get_ports {KEY[*]}] -to [all_registers]
set_false_path -from [get_ports {SW[*]}]  -to [all_registers]

# Status outputs -- no external setup/hold requirement.
set_false_path -from [all_registers] -to [get_ports {LEDR[*]}]
