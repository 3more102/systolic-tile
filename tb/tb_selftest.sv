// -----------------------------------------------------------------------------
// tb_selftest -- simulates the exact logic that will run on the FPGA.
//
// The board build has no console: it reports a single pass/fail LED. That makes
// it worth proving in simulation that the self-test wrapper itself is right --
// otherwise a dark LED on hardware is ambiguous between "the tile is broken"
// and "the self-test harness is broken".
//
// Runs the whole sequence twice, clean and with hardware backpressure enabled,
// and additionally checks the probe read-back path that the boards use to walk
// the result bytes out to LEDs.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_selftest;

`include "selftest_params.svh"

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic       rst_n;
    logic       start;
    logic       bp_en;
    logic [7:0] probe_idx;
    wire        busy, done, pass, fail;
    wire  [7:0] probe_data;

    tile_selftest dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .bp_en      (bp_en),
        .probe_idx  (probe_idx),
        .busy       (busy),
        .done       (done),
        .pass       (pass),
        .fail       (fail),
        .probe_data (probe_data)
    );

    // Golden results, read independently of the DUT's own copy so the probe
    // check is a real comparison rather than the design agreeing with itself.
    logic [ST_COLS*8-1:0] y_ref [0:ST_Y_DEPTH-1];

    int errors, guard, beat, lane;
    logic [7:0] want;

    task automatic run_selftest(input logic use_bp);
        begin
            bp_en = use_bp;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            guard = 0;
            while (!busy && guard < 1000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (!busy) begin
                $display("  FAIL: self-test never started (bp_en=%0d)", use_bp);
                errors = errors + 1;
            end

            guard = 0;
            while (busy && guard < 200000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (busy) begin
                $display("  FAIL: self-test hung (bp_en=%0d)", use_bp);
                errors = errors + 1;
            end else if (!done || !pass || fail) begin
                $display("  FAIL: bp_en=%0d -> done=%b pass=%b fail=%b",
                         use_bp, done, pass, fail);
                errors = errors + 1;
            end else begin
                $display("    bp_en=%0d : pass asserted after %0d cycles",
                         use_bp, guard);
            end
        end
    endtask

    task automatic check_probe();
        begin
            for (beat = 0; beat < ST_Y_DEPTH; beat = beat + 1) begin
                for (lane = 0; lane < ST_COLS; lane = lane + 1) begin
                    probe_idx = (beat * ST_COLS) + lane;
                    #1;
                    want = y_ref[beat][lane*8 +: 8];
                    if (probe_data !== want) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("  FAIL probe beat %0d lane %0d: got %02h want %02h",
                                     beat, lane, probe_data, want);
                    end
                end
            end
        end
    endtask

    initial begin
        errors    = 0;
        probe_idx = 8'd0;
        $readmemh("selftest_y.hex", y_ref);

        $display("");
        $display("=== tb_selftest : M=%0d passes=%0d relu=%0d ===",
                 ST_M, ST_PASSES, ST_RELU);

        rst_n = 1'b0;
        start = 1'b0;
        bp_en = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        run_selftest(1'b0);
        check_probe();
        run_selftest(1'b1);
        check_probe();

        if (errors == 0) $display("    RESULT: PASS");
        else             $display("    RESULT: FAIL (%0d errors)", errors);
        $display("");
        $finish;
    end

    initial begin
        #10_000_000;
        $display("    RESULT: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
