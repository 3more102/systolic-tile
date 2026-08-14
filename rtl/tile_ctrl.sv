// -----------------------------------------------------------------------------
// tile_ctrl -- per-pass sequencer.
//
//   IDLE    wait for `start`, latch first_pass/last_pass for this pass
//   LOADW   accept ROWS weight beats and shift them down the shadow chain
//   COMMIT  one cycle of w_commit: shadow -> active, and clear the accumulator
//           beat address
//   COMPUTE accept m_len activation beats
//   DRAIN   hold for the full pipeline latency so the pass is completely
//           flushed before the next `start` can change first/last
//
// Every state that has an observable side effect is qualified with `en`, so a
// stall never lets the FSM run ahead of the frozen datapath. That includes
// COMMIT: without the guard, a stall on the commit cycle would advance the
// state machine while the PEs ignored w_commit, and the array would compute
// with the previous tile's weights.
//
// States are localparams rather than an enum purely for tool portability
// (Quartus 18.1 / Icarus / Yosys all agree on this form).
// -----------------------------------------------------------------------------
`default_nettype none

module tile_ctrl #(
    parameter int ROWS = 8,
    parameter int COLS = 8
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         en,

    input  wire         start,
    input  wire         first_pass_in,
    input  wire         last_pass_in,
    input  wire  [15:0] m_len,          // output rows this pass; must be >= 1

    input  wire         w_valid,
    output wire         w_ready,
    output wire         w_shift,
    output wire         w_commit,

    input  wire         a_valid,
    output wire         a_ready,
    output wire         a_beat,         // activation beat actually accepted

    output wire         acc_clr,
    output logic        acc_first,
    output logic        acc_last,

    output wire         busy,
    output logic        done
);

    // Worst-case fill of the whole pipeline, with slack: input skew, the array
    // plus its column skew, the deskew, accum_bank and requant.
    localparam int DRAIN_CYCLES = ROWS + COLS + 12;

    localparam int WCW = $clog2(ROWS + 1);
    localparam int DCW = $clog2(DRAIN_CYCLES + 1);

    localparam logic [2:0] S_IDLE    = 3'd0;
    localparam logic [2:0] S_LOADW   = 3'd1;
    localparam logic [2:0] S_COMMIT  = 3'd2;
    localparam logic [2:0] S_COMPUTE = 3'd3;
    localparam logic [2:0] S_DRAIN   = 3'd4;

    logic [2:0]     state;
    logic [WCW-1:0] wcnt;
    logic [15:0]    mcnt;
    logic [DCW-1:0] dcnt;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            wcnt      <= '0;
            mcnt      <= '0;
            dcnt      <= '0;
            acc_first <= 1'b0;
            acc_last  <= 1'b0;
            done      <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        acc_first <= first_pass_in;
                        acc_last  <= last_pass_in;
                        wcnt      <= '0;
                        state     <= S_LOADW;
                    end
                end

                S_LOADW: begin
                    if (en && w_valid) begin
                        if (wcnt == (ROWS - 1)) state <= S_COMMIT;
                        else                    wcnt  <= wcnt + 1'b1;
                    end
                end

                S_COMMIT: begin
                    if (en) begin
                        mcnt  <= '0;
                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (en && a_valid) begin
                        if (mcnt == m_len - 16'd1) begin
                            dcnt  <= DRAIN_CYCLES;
                            state <= S_DRAIN;
                        end else begin
                            mcnt <= mcnt + 16'd1;
                        end
                    end
                end

                S_DRAIN: begin
                    if (en) begin
                        if (dcnt == '0) begin
                            state <= S_IDLE;
                            done  <= 1'b1;
                        end else begin
                            dcnt <= dcnt - 1'b1;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign w_ready  = (state == S_LOADW)   && en;
    assign w_shift  = (state == S_LOADW)   && en && w_valid;
    assign w_commit = (state == S_COMMIT)  && en;
    assign acc_clr  = (state == S_COMMIT)  && en;
    assign a_ready  = (state == S_COMPUTE) && en;
    assign a_beat   = (state == S_COMPUTE) && en && a_valid;
    assign busy     = (state != S_IDLE);

`ifdef FORMAL
    // C1 -- nothing observable happens while the datapath is frozen.
    //
    // The FSM state is deliberately *not* asserted stable. S_IDLE -> S_LOADW on
    // `start` is the one transition not qualified with `en`, and it is safe
    // precisely because every output below is. Writing the freeze property
    // exactly is what makes that exception explicit rather than a comment.
    always_ff @(posedge clk) if (rst_n && !en)
        assert (!(w_ready || w_shift || w_commit || acc_clr || a_ready || a_beat));
`endif

endmodule

`default_nettype wire
