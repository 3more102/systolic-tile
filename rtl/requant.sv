// -----------------------------------------------------------------------------
// requant -- INT32 accumulator back down to INT8.
//
//   y = clamp( (acc + bias) * mult  rounded>> shift )
//
// with clamp bounds [-128,127], or [0,127] when relu is set. Rounding is
// round-half-up on the signed value: add 1<<(shift-1) before the arithmetic
// right shift. Verilog's >>> on a signed operand and Python's >> on an int are
// both floor shifts, so this is bit-exact with model/golden.py:requantize().
//
// Three pipeline stages (bias add / multiply / shift+saturate). The multiply is
// the widest operation in the design, so it gets a stage to itself -- that is
// what keeps the tile off the critical path on a -1 speed grade part.
//
// `mult` is unsigned so the multiplier is 33x17 signed rather than 33x32.
// Requires shift >= 1 for rounding to mean anything; shift == 0 is treated as
// a plain truncating pass-through.
// -----------------------------------------------------------------------------
`default_nettype none

module requant #(
    parameter int LANES = 8,
    parameter int ACC_W = 32
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,

    input  wire                    in_valid,
    input  wire  [LANES*ACC_W-1:0] acc_in,
    input  wire  [LANES*ACC_W-1:0] bias,
    input  wire  [15:0]            mult,
    input  wire  [5:0]             shift,
    input  wire                    relu,

    output logic                   out_valid,
    output wire  [LANES*8-1:0]     y_out,
    output logic                   sat_hit      // any lane clamped on this beat
);

    localparam int BW = ACC_W + 1;    // acc + bias
    localparam int PW = BW + 17;      // (acc + bias) * mult

    // ---- control / config pipeline ------------------------------------------
    logic        v0, v1;
    logic [5:0]  shift0, shift1;
    logic        relu0, relu1;
    logic [15:0] mult0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0; v1 <= 1'b0; out_valid <= 1'b0;
            shift0 <= '0; shift1 <= '0;
            relu0  <= 1'b0; relu1 <= 1'b0;
            mult0  <= '0;
        end else if (en) begin
            v0 <= in_valid;  shift0 <= shift; relu0 <= relu; mult0 <= mult;
            v1 <= v0;        shift1 <= shift0; relu1 <= relu0;
            out_valid <= v1;
        end
    end

    wire [LANES-1:0] sat_lane;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_lane
            localparam signed [PW-1:0] MAXV =  127;
            localparam signed [PW-1:0] MINV = -128;

            // -- stage 0: bias add ---------------------------------------------
            wire signed [ACC_W-1:0] acc_g  = $signed(acc_in[g*ACC_W +: ACC_W]);
            wire signed [ACC_W-1:0] bias_g = $signed(bias  [g*ACC_W +: ACC_W]);
            wire signed [BW-1:0]    biased = acc_g + bias_g;

            logic signed [BW-1:0] biased_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)  biased_q <= '0;
                else if (en) biased_q <= biased;
            end

            // -- stage 1: multiply ---------------------------------------------
            wire signed [16:0]   mult_s = $signed({1'b0, mult0});
            wire signed [PW-1:0] prod   = biased_q * mult_s;

            logic signed [PW-1:0] prod_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)  prod_q <= '0;
                else if (en) prod_q <= prod;
            end

            // -- stage 2: round, arithmetic shift, saturate ---------------------
            wire [PW-1:0]        one = {{(PW-1){1'b0}}, 1'b1};
            wire signed [PW-1:0] rnd = (shift1 == 6'd0) ? {PW{1'b0}}
                                                        : $signed(one << (shift1 - 6'd1));
            wire signed [PW-1:0] shifted  = (prod_q + rnd) >>> shift1;
            wire signed [PW-1:0] lo_limit = relu1 ? {PW{1'b0}} : MINV;

            wire hi_clamp = (shifted > MAXV);
            wire lo_clamp = (shifted < lo_limit);

            wire signed [7:0] sat = hi_clamp ? 8'sd127
                                  : lo_clamp ? lo_limit[7:0]
                                             : shifted[7:0];

            logic signed [7:0] y_q;
            logic              sat_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    y_q   <= 8'sd0;
                    sat_q <= 1'b0;
                end else if (en) begin
                    y_q   <= sat;
                    sat_q <= hi_clamp || lo_clamp;
                end
            end

            assign y_out[g*8 +: 8] = y_q;
            assign sat_lane[g]     = sat_q;
        end
    endgenerate

    always_comb sat_hit = out_valid && (|sat_lane);

endmodule

`default_nettype wire
