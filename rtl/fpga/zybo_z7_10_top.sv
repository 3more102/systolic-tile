// -----------------------------------------------------------------------------
// zybo_z7_10_top -- Digilent Zybo Z7-10 (Zynq-7010, xc7z010clg400-1).
//
// Pure pin mapping; all behaviour is in selftest_shell / tile_selftest.
//
//   btn[0]      reset       (Zybo buttons read high when pressed)
//   btn[1]      re-run the self-test
//   sw0         enable hardware backpressure during the run
//   led[0]      busy
//   led[1]      done
//   led[2]      PASS  -- the tile matched model/golden.py bit for bit
//   led[3]      FAIL
//   led6_g      PASS, mirrored onto the green channel of RGB LED LD6
//
// The Zybo has only four user LEDs, so unlike the DE10 build there is no result
// read-back here -- the four LEDs are status only, and the PASS LED is the
// actual claim: the tile reproduced model/golden.py bit for bit on hardware.
//
// Nothing here touches PS resources, so this runs from a bare PL bitstream with
// no boot image, first-stage bootloader or PS configuration.
// -----------------------------------------------------------------------------
`default_nettype none

module zybo_z7_10_top (
    input  wire       sysclk,      // 125 MHz PL oscillator
    input  wire [1:0] btn,
    input  wire       sw0,
    output wire [3:0] led,
    output wire       led6_g
);

    wire busy, done, pass, fail;

    selftest_shell u_shell (
        .clk        (sysclk),
        .arst_n     (~btn[0]),     // Zybo buttons are active high
        .start_btn  (btn[1]),
        .bp_en_raw  (sw0),
        .probe_idx  (8'd0),
        .busy       (busy),
        .done       (done),
        .pass       (pass),
        .fail       (fail),
        .probe_data (/* unused: only four LEDs on this board */)
    );

    assign led[0] = busy;
    assign led[1] = done;
    assign led[2] = pass;
    assign led[3] = fail;
    assign led6_g = pass;

endmodule

`default_nettype wire
