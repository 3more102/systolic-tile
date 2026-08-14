// -----------------------------------------------------------------------------
// de10_standard_top -- Terasic DE10-Standard (Cyclone V 5CSXFC6D6F31C6).
//
// Pure pin mapping; all behaviour is in selftest_shell / tile_selftest.
//
//   KEY[0]      reset       (active low, idles high)
//   KEY[1]      re-run the self-test
//   KEY[2] held enable hardware backpressure during the run
//   SW[7:0]     which result byte to show, as beat*8 + lane
//   LEDR[7:0]   that result byte
//   LEDR[8]     PASS  -- the tile matched model/golden.py bit for bit
//   LEDR[9]     FAIL
//
// The self-test starts itself about a millisecond after power-on, so a freshly
// programmed board lights LEDR[8] with no interaction. Both status LEDs dark
// means it is still running (or was never started).
//
// Only the pins actually used are declared, so the build has neither an
// unconstrained port nor a port with no load.
// -----------------------------------------------------------------------------
`default_nettype none

module de10_standard_top (
    input  wire        CLOCK_50,
    input  wire [2:0]  KEY,
    input  wire [7:0]  SW,
    output wire [9:0]  LEDR
);

    wire       busy, done, pass, fail;
    wire [7:0] probe_data;

    selftest_shell u_shell (
        .clk        (CLOCK_50),
        .arst_n     (KEY[0]),      // DE10 push-buttons idle high, press low
        .start_btn  (~KEY[1]),
        .bp_en_raw  (~KEY[2]),
        .probe_idx  (SW),
        .busy       (busy),
        .done       (done),
        .pass       (pass),
        .fail       (fail),
        .probe_data (probe_data)
    );

    assign LEDR[7:0] = probe_data;
    assign LEDR[8]   = pass;
    assign LEDR[9]   = fail;

endmodule

`default_nettype wire
