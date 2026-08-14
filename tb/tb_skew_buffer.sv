// -----------------------------------------------------------------------------
// tb_skew_buffer -- proves the per-lane delays are exactly right.
//
// The skew and deskew delays are the whole reason a systolic array produces
// aligned results, and an off-by-one there does not crash anything: it quietly
// pairs each activation with the wrong partial sum and every output is subtly
// wrong. That failure is painful to debug from the top level, so it is pinned
// down here directly.
//
// Method: drive a timestamp onto every lane, then assert that lane i's output
// at cycle t is the timestamp from cycle t-DLY, with DLY the delay the module
// is supposed to implement. Both directions (skew and deskew) are checked, and
// the test also verifies the delays freeze while `en` is low.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_skew_buffer;

    localparam int LANES = 6;
    localparam int W     = 8;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, en;
    logic [LANES*W-1:0] din;
    wire  [LANES*W-1:0] dout_fwd, dout_rev;

    skew_buffer #(.LANES(LANES), .W(W), .REVERSE(0)) u_fwd (
        .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_fwd));

    skew_buffer #(.LANES(LANES), .W(W), .REVERSE(1)) u_rev (
        .clk(clk), .rst_n(rst_n), .en(en), .din(din), .dout(dout_rev));

    int errors, t, i;
    logic [W-1:0]       history [0:255];   // history[t] = timestamp driven at cycle t
    logic [LANES*W-1:0] frozen_fwd, frozen_rev;

    task automatic check(input int cycle);
        int lane, delay;
        logic [W-1:0] got, want;
        begin
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                // forward: lane i delayed i cycles
                delay = lane;
                got   = dout_fwd[lane*W +: W];
                if (cycle >= delay) begin
                    want = history[cycle - delay];
                    if (got !== want) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("  FAIL fwd cycle %0d lane %0d: got %02h want %02h",
                                     cycle, lane, got, want);
                    end
                end

                // reverse: lane i delayed LANES-1-i cycles
                delay = LANES - 1 - lane;
                got   = dout_rev[lane*W +: W];
                if (cycle >= delay) begin
                    want = history[cycle - delay];
                    if (got !== want) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("  FAIL rev cycle %0d lane %0d: got %02h want %02h",
                                     cycle, lane, got, want);
                    end
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        $display("");
        $display("=== tb_skew_buffer : LANES=%0d W=%0d ===", LANES, W);

        rst_n = 1'b0;
        en    = 1'b1;
        din   = '0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // ---- part 1: free-running, one new timestamp per cycle --------------
        // din for cycle t is driven at the negedge and sampled by the posedge in
        // the middle of that cycle, so the outputs are inspected just after the
        // negedge -- before the edge that captures the new value.
        for (t = 0; t < 64; t = t + 1) begin
            @(negedge clk);
            history[t] = t[W-1:0];
            din        = {LANES{t[W-1:0]}};
            #1;
            check(t);
        end

        // ---- part 2: freeze -- delayed lanes must not advance ---------------
        // Lane 0 of the forward buffer and lane LANES-1 of the reverse buffer
        // are zero-delay pass-throughs by construction, so they are expected to
        // follow din even while en is low; every other lane must hold.
        @(negedge clk);
        #1;
        frozen_fwd = dout_fwd;
        frozen_rev = dout_rev;
        en  = 1'b0;
        din = {LANES{8'hA5}};
        repeat (5) begin
            @(negedge clk);
            #1;
            for (i = 0; i < LANES; i = i + 1) begin
                if (i != 0 && dout_fwd[i*W +: W] !== frozen_fwd[i*W +: W]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("  FAIL freeze fwd lane %0d advanced while en=0", i);
                end
                if (i != LANES-1 && dout_rev[i*W +: W] !== frozen_rev[i*W +: W]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("  FAIL freeze rev lane %0d advanced while en=0", i);
                end
            end
        end
        @(negedge clk);
        en = 1'b1;

        if (errors == 0) $display("    RESULT: PASS");
        else             $display("    RESULT: FAIL (%0d errors)", errors);
        $display("");
        $finish;
    end

    initial begin
        #200_000;
        $display("    RESULT: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
