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

`ifdef FORMAL
    // Proven at the tile top by scripts/formal.sh, never standalone: both
    // properties below are statements about how systolic_tile drives wr_en, and
    // both are false for an arbitrary environment that writes whenever it likes.
    always_ff @(posedge clk) if (rst_n) begin
        // F1 -- no beat is ever silently dropped.
        //
        // The (count < DEPTH) mask in do_wr is the one place in this design
        // where a result can vanish with nothing to show for it: no counter
        // moves, no flag is raised, the FIFO simply does not take the beat.
        // Proving the mask is dead code is proving the whole backpressure
        // scheme. It is also exactly the caller contract in the header above --
        // drop the `&& en` at the instantiation and this assertion fires.
        assert (!(wr_en && count == DEPTH));

        // F2 -- wptr, rptr and count are three registers advanced by two
        // independent conditions. If they ever disagree the FIFO hands back the
        // wrong entry while still counting correctly, so every beat arrives, in
        // order, carrying the wrong data. Nothing that counts beats sees it.
        assert (count <= DEPTH);
        assert ((wptr - rptr) == count[AW-1:0]);
    end
`endif

endmodule

`default_nettype wire
