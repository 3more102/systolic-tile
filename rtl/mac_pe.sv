// -----------------------------------------------------------------------------
// mac_pe -- one processing element of the weight-stationary systolic array.
//
// Dataflow (see docs/architecture.md):
//   * activations enter from the WEST and leave to the EAST one cycle later
//   * partial sums enter from the NORTH and leave to the SOUTH one cycle later
//   * weights shift NORTH->SOUTH down a dedicated shadow chain and are then
//     committed into the active register, so the next weight tile can be
//     pre-loaded while the current one is still computing.
//
// Every register is gated by `en`, the array-wide clock enable that freezes the
// whole pipeline when the output FIFO fills up. The weight chain is gated too,
// so a stall can never corrupt a preload that is halfway down the array.
// -----------------------------------------------------------------------------
`default_nettype none

// use_dsp forces the multiply-accumulate into a hard DSP block. This is what
// closes 125 MHz on the Zynq-7010: `s_in + a_in*w_active` maps onto a DSP48E1
// as A*B + C -> P, replacing a twelve-level fabric path (8x8 multiply feeding a
// 32-bit carry chain) with one hard macro. Worth 0.6 ns of slack and a 3.4x cut
// in LUTs -- see docs/architecture.md, "Timing".
//
// Left unconditional on purpose. Quartus does not recognise the attribute and
// logs "Warning (10335): Unrecognized synthesis attribute" -- harmless, since it
// already packs two 8x8 MACs per Cyclone V DSP without being asked. Hiding it
// behind an `ifdef would trade that one warning for a silent timing failure the
// day someone builds for Vivado without the define.
(* use_dsp = "yes" *)
module mac_pe #(
    parameter int ACC_W = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     en,

    // weight shadow chain (north -> south)
    input  wire                     w_shift,
    input  wire                     w_commit,
    input  wire  signed [7:0]       w_in,
    output wire  signed [7:0]       w_out,

    // activations (west -> east)
    input  wire  signed [7:0]       a_in,
    output logic signed [7:0]       a_out,

    // partial sums (north -> south)
    input  wire  signed [ACC_W-1:0] s_in,
    output logic signed [ACC_W-1:0] s_out,

    // valid, delay-matched to the partial-sum path
    input  wire                     v_in,
    output logic                    v_out
);

    logic signed [7:0] w_shadow;
    logic signed [7:0] w_active;

    assign w_out = w_shadow;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)              w_shadow <= 8'sd0;
        else if (en && w_shift)  w_shadow <= w_in;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)              w_active <= 8'sd0;
        else if (en && w_commit) w_active <= w_shadow;
    end

    // 8x8 signed multiply. The 16-bit assignment context makes this a
    // full-width product; assigning that to a wider signed net sign-extends it.
    wire signed [15:0]      prod;
    wire signed [ACC_W-1:0] prod_ext;
    assign prod     = a_in * w_active;
    assign prod_ext = prod;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= 8'sd0;
            s_out <= '0;
            v_out <= 1'b0;
        end else if (en) begin
            a_out <= a_in;
            s_out <= s_in + prod_ext;
            v_out <= v_in;
        end
    end

endmodule

`default_nettype wire
