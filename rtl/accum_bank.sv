// -----------------------------------------------------------------------------
// accum_bank -- output accumulator that lets K exceed the array height.
//
// A K x N matmul is split into ceil(K/ROWS) passes. Each pass loads a fresh
// weight tile and re-streams the matching slice of activations, producing a
// partial result for every one of the M output rows. This block keeps a running
// INT32 accumulator per (output row, column) and only releases the result
// downstream on the final pass.
//
//   first_pass=1 -> overwrite the stored value (no stale data to clear)
//   last_pass=1  -> also emit the result on out_valid
//
// Beat addresses are a plain counter reset by `clr` at the start of each pass,
// so pass p beat m always lands on the same address as pass p-1 beat m.
//
// Two pipeline stages: stage 1 issues the RAM read, stage 2 adds and writes
// back. Because the address advances by one per beat, the write in stage 2 and
// the read in stage 1 never touch the same address, so no bypass is needed.
//
// DEPTH bounds the number of output rows M that a single run may stream.
// -----------------------------------------------------------------------------
`default_nettype none

module accum_bank #(
    parameter int LANES = 8,
    parameter int ACC_W = 32,
    parameter int DEPTH = 256
) (
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    en,

    input  wire                    clr,         // reset beat address (pass start)
    input  wire                    first_pass,
    input  wire                    last_pass,

    input  wire                    in_valid,
    input  wire  [LANES*ACC_W-1:0] in_data,

    output logic                   out_valid,
    output logic [LANES*ACC_W-1:0] out_data
);

    localparam int AW = (DEPTH <= 2) ? 1 : $clog2(DEPTH);

    logic [LANES*ACC_W-1:0] mem [0:DEPTH-1];
    logic [AW-1:0]          addr;

    // ---- stage 1: capture the beat, issue the RAM read -----------------------
    logic [AW-1:0]          addr_s1;
    logic [LANES*ACC_W-1:0] data_s1;
    logic                   v_s1, first_s1, last_s1;
    logic [LANES*ACC_W-1:0] q_s1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr     <= '0;
            addr_s1  <= '0;
            data_s1  <= '0;
            v_s1     <= 1'b0;
            first_s1 <= 1'b0;
            last_s1  <= 1'b0;
        end else if (en) begin
            if (clr)             addr <= '0;
            else if (in_valid)   addr <= addr + 1'b1;

            addr_s1  <= addr;
            data_s1  <= in_data;
            v_s1     <= in_valid;
            first_s1 <= first_pass;
            last_s1  <= last_pass;
        end
    end

    always_ff @(posedge clk) begin
        if (en) q_s1 <= mem[addr];
    end

    // ---- stage 2: accumulate lane-wise, write back, release on the last pass -
    wire [LANES*ACC_W-1:0] sum_s2;

    genvar g;
    generate
        for (g = 0; g < LANES; g = g + 1) begin : g_acc
            assign sum_s2[g*ACC_W +: ACC_W] =
                first_s1 ? data_s1[g*ACC_W +: ACC_W]
                         : data_s1[g*ACC_W +: ACC_W] + q_s1[g*ACC_W +: ACC_W];
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (en && v_s1) mem[addr_s1] <= sum_s2;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_data  <= '0;
        end else if (en) begin
            out_valid <= v_s1 && last_s1;
            out_data  <= sum_s2;
        end
    end

endmodule

`default_nettype wire
