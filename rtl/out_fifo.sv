// -----------------------------------------------------------------------------
// out_fifo -- small synchronous FIFO that decouples the tile from its consumer.
//
// Its occupancy drives `stall`, and the tile turns that into the array-wide
// clock enable en = ~stall. Freezing every producer register at once is what
// makes backpressure tractable in a systolic array: the diagonal wavefront
// keeps its relative alignment because nothing advances.
//
// The one rule callers must follow: `wr_en` has to be qualified with `en`.
// A frozen producer holds its valid high, so an unqualified write would push
// the same beat in on every stalled cycle.
//
// Depth 8 with a threshold of DEPTH-2 leaves room for the beat already in the
// last pipeline register when stall asserts, for any ROWS/COLS.
// -----------------------------------------------------------------------------
`default_nettype none

module out_fifo #(
    parameter int W     = 8,
    parameter int DEPTH = 8
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire          wr_en,     // must already be qualified with `en`
    input  wire  [W-1:0] wr_data,
    output wire          stall,

    output wire          rd_valid,
    output wire  [W-1:0] rd_data,
    input  wire          rd_ready
);

    localparam int AW = $clog2(DEPTH);

    logic [W-1:0]  mem [0:DEPTH-1];
    logic [AW-1:0] wptr, rptr;
    logic [AW:0]   count;

    wire do_wr = wr_en    && (count < DEPTH);
    wire do_rd = rd_valid && rd_ready;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wptr  <= '0;
            rptr  <= '0;
            count <= '0;
        end else begin
            if (do_wr) begin
                mem[wptr] <= wr_data;
                wptr      <= wptr + 1'b1;
            end
            if (do_rd) rptr <= rptr + 1'b1;

            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: count <= count;
            endcase
        end
    end

    assign rd_valid = (count != '0);
    assign rd_data  = mem[rptr];
    assign stall    = (count >= (DEPTH - 2));

endmodule

`default_nettype wire
