// -----------------------------------------------------------------------------
// skew_buffer -- per-lane programmable delay line.
//
// Lane i is delayed by (REVERSE ? LANES-1-i : i) cycles:
//
//   REVERSE=0  input skew    row r delayed r cycles, so that the activation for
//                            row r reaches PE(r,0) on the same cycle as the
//                            partial sum descending from PE(r-1,0).
//   REVERSE=1  output deskew column c delayed COLS-1-c cycles, undoing the c
//                            cycles the activation spent hopping east.
//
// Also used with W=1 to deskew the per-column valid bits, which keeps the
// control path structurally identical to the data path.
// -----------------------------------------------------------------------------
`default_nettype none

module skew_buffer #(
    parameter int LANES   = 8,
    parameter int W       = 8,
    parameter int REVERSE = 0
) (
    input  wire                clk,
    input  wire                rst_n,
    input  wire                en,
    input  wire  [LANES*W-1:0] din,
    output wire  [LANES*W-1:0] dout
);

    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : g_lane
            localparam int DLY = REVERSE ? (LANES - 1 - i) : i;

            if (DLY == 0) begin : g_bypass
                assign dout[i*W +: W] = din[i*W +: W];
            end else begin : g_delay
                logic [W-1:0] sr [0:DLY-1];
                integer k;
                always_ff @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (k = 0; k < DLY; k = k + 1) sr[k] <= '0;
                    end else if (en) begin
                        sr[0] <= din[i*W +: W];
                        for (k = 1; k < DLY; k = k + 1) sr[k] <= sr[k-1];
                    end
                end
                assign dout[i*W +: W] = sr[DLY-1];
            end
        end
    endgenerate

endmodule

`default_nettype wire
