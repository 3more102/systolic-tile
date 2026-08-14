// -----------------------------------------------------------------------------
// tb_requant -- focused arithmetic test for the INT32 -> INT8 output stage.
//
// The top-level test proves the array multiplies and accumulates correctly, but
// it only ever uses one (mult, shift, relu) triple per run. This test streams
// 320 vectors back to back, each with its OWN config, which does double duty:
//
//   1. It covers the arithmetic corners -- round-half-up on negative values,
//      both saturation limits, relu, shift==0, and the widest multiply.
//   2. Because the config changes every cycle, it proves the config pipeline
//      inside requant is staged correctly. A design that used the raw `shift`
//      input at stage 2 instead of the twice-registered copy would pass a
//      constant-config test and fail here.
//
// Vectors come from model/gen_vectors.py; the expected value is whatever
// golden.requantize() produced, so this test cannot drift from the model.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_requant;

    localparam int LANES = 1;
    localparam int ACC_W = 32;
    localparam int MAXV  = 4096;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;

    logic                  in_valid;
    logic [ACC_W-1:0]      acc_in;
    logic [ACC_W-1:0]      bias;
    logic [15:0]           mult;
    logic [5:0]            shift;
    logic                  relu;
    wire                   out_valid;
    wire  [7:0]            y_out;
    wire                   sat_hit;

    requant #(
        .LANES (LANES),
        .ACC_W (ACC_W)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .in_valid  (in_valid),
        .acc_in    (acc_in),
        .bias      (bias),
        .mult      (mult),
        .shift     (shift),
        .relu      (relu),
        .out_valid (out_valid),
        .y_out     (y_out),
        .sat_hit   (sat_hit)
    );

    // vector layout: {acc[31:0], bias[31:0], mult[15:0], shift[7:0], relu[7:0], y[7:0]}
    logic [103:0] vec [0:MAXV-1];
    logic [15:0]  cnt [0:0];

    int    count, i, o, errors, clamps;
    string vecdir;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (o < count) begin
                if (y_out !== vec[o][7:0]) begin
                    errors = errors + 1;
                    if (errors <= 12)
                        $display("  FAIL vec %0d: acc=%0d bias=%0d mult=%0d shift=%0d relu=%0d -> got %0d want %0d",
                                 o, $signed(vec[o][103:72]), $signed(vec[o][71:40]),
                                 vec[o][39:24], vec[o][23:16], vec[o][15:8],
                                 $signed(y_out), $signed(vec[o][7:0]));
                end
            end else begin
                errors = errors + 1;
            end
            if (sat_hit) clamps = clamps + 1;
            o = o + 1;
        end
    end

    initial begin
        errors = 0; o = 0; clamps = 0;

        if (!$value$plusargs("vecdir=%s", vecdir)) vecdir = "vectors/requant";
        $readmemh($sformatf("%s/count.hex", vecdir), cnt);
        count = cnt[0];
        // Explicit range: reading into the full array would warn about the
        // unused tail on every run and bury real messages in CI logs.
        $readmemh($sformatf("%s/vectors.hex", vecdir), vec, 0, count - 1);

        $display("");
        $display("=== tb_requant : %0d vectors ===", count);

        rst_n    = 1'b0;
        in_valid = 1'b0;
        acc_in   = '0;
        bias     = '0;
        mult     = 16'd1;
        shift    = 6'd0;
        relu     = 1'b0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // One vector per cycle, config included -- see the header comment.
        for (i = 0; i < count; i = i + 1) begin
            @(negedge clk);
            in_valid = 1'b1;
            acc_in   = vec[i][103:72];
            bias     = vec[i][71:40];
            mult     = vec[i][39:24];
            shift    = vec[i][23:16];
            relu     = (vec[i][15:8] != 8'd0);
        end
        @(negedge clk);
        in_valid = 1'b0;

        repeat (16) @(posedge clk);

        if (o != count) begin
            $display("  FAIL: got %0d results, expected %0d", o, count);
            errors = errors + 1;
        end

        $display("    results checked : %0d / %0d", o, count);
        $display("    clamping beats  : %0d", clamps);
        if (errors == 0) $display("    RESULT: PASS");
        else             $display("    RESULT: FAIL (%0d errors)", errors);
        $display("");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("    RESULT: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
