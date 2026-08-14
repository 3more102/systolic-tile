// -----------------------------------------------------------------------------
// systolic_tile -- INT8 weight-stationary matmul tile.
//
//   C[M][N] = requant( sum_k A[M][K] * W[K][N] + bias[N] )
//
// The array is ROWS x COLS. K is tiled into ceil(K/ROWS) passes; N beyond COLS
// is handled by re-running the tile with a different weight block. Everything
// is INT8 in, INT32 accumulate, INT8 out.
//
// Streams
// -------
//   weights      ROWS beats per pass, COLS bytes each, array row ROWS-1 FIRST
//   activations  cfg_m_len beats per pass, ROWS bytes each, row-major in M
//   results      cfg_m_len beats, COLS bytes each, released on the LAST pass
//
// Per-run sequence (host side):
//   for p in 0..PASSES-1:
//       pulse start with first_pass=(p==0), last_pass=(p==PASSES-1)
//       push ROWS weight beats, then cfg_m_len activation beats
//       wait for done
//
// Backpressure
// ------------
// y_ready is honoured through a global clock enable derived from the output
// FIFO occupancy. Gaps in a_valid are also legal at any time: the input skew
// buffer applies a fixed per-lane delay, so a bubble shifts a whole beat's
// diagonal wavefront together and alignment is preserved.
//
// Bit-exactness with model/golden.py is the acceptance criterion; tb/ checks it
// beat by beat.
// -----------------------------------------------------------------------------
`default_nettype none

module systolic_tile #(
    parameter int ROWS       = 8,    // array height  = K tile size
    parameter int COLS       = 8,    // array width   = N output channels
    parameter int ACC_W      = 32,
    parameter int MAX_M      = 256,  // accumulator depth = max output rows
    parameter int FIFO_DEPTH = 8
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- run control --------------------------------------------------------
    input  wire                     start,
    input  wire                     first_pass,
    input  wire                     last_pass,
    input  wire  [15:0]             cfg_m_len,   // output rows this pass, >= 1
    input  wire  [15:0]             cfg_mult,    // requant multiplier (unsigned)
    input  wire  [5:0]              cfg_shift,   // requant right shift
    input  wire                     cfg_relu,
    input  wire  [COLS*ACC_W-1:0]   cfg_bias,
    output wire                     busy,
    output wire                     done,

    // ---- weight stream ------------------------------------------------------
    input  wire                     w_valid,
    output wire                     w_ready,
    input  wire  [COLS*8-1:0]       w_data,

    // ---- activation stream --------------------------------------------------
    input  wire                     a_valid,
    output wire                     a_ready,
    input  wire  [ROWS*8-1:0]       a_data,

    // ---- result stream ------------------------------------------------------
    output wire                     y_valid,
    input  wire                     y_ready,
    output wire [COLS*8-1:0]        y_data,
    output wire                     y_last,

    // ---- status -------------------------------------------------------------
    output wire                     sat_hit      // a lane clamped on this beat
);

    // -------------------------------------------------------------------------
    // Array-wide clock enable. Everything upstream of the output FIFO freezes
    // together, which is what makes backpressure safe in a systolic pipeline.
    // -------------------------------------------------------------------------
    wire stall;
    wire en = ~stall;

    // -------------------------------------------------------------------------
    // Sequencer
    // -------------------------------------------------------------------------
    wire w_shift, w_commit, a_beat, acc_clr, acc_first, acc_last;

    tile_ctrl #(
        .ROWS (ROWS),
        .COLS (COLS)
    ) u_ctrl (
        .clk           (clk),
        .rst_n         (rst_n),
        .en            (en),
        .start         (start),
        .first_pass_in (first_pass),
        .last_pass_in  (last_pass),
        .m_len         (cfg_m_len),
        .w_valid       (w_valid),
        .w_ready       (w_ready),
        .w_shift       (w_shift),
        .w_commit      (w_commit),
        .a_valid       (a_valid),
        .a_ready       (a_ready),
        .a_beat        (a_beat),
        .acc_clr       (acc_clr),
        .acc_first     (acc_first),
        .acc_last      (acc_last),
        .busy          (busy),
        .done          (done)
    );

    // -------------------------------------------------------------------------
    // Input skew: row r delayed r cycles. Activations are zeroed on bubble
    // cycles so waveforms stay readable; the array discards them anyway because
    // their valid is low and each beat starts a fresh partial sum at the top of
    // the column.
    // -------------------------------------------------------------------------
    wire [ROWS*8-1:0] a_mux = a_beat ? a_data : {ROWS*8{1'b0}};
    wire [ROWS*8-1:0] a_skewed;

    skew_buffer #(
        .LANES   (ROWS),
        .W       (8),
        .REVERSE (0)
    ) u_skew_in (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .din   (a_mux),
        .dout  (a_skewed)
    );

    // -------------------------------------------------------------------------
    // The array
    // -------------------------------------------------------------------------
    wire [COLS*ACC_W-1:0] s_col;
    wire [COLS-1:0]       v_col;

    pe_array #(
        .ROWS  (ROWS),
        .COLS  (COLS),
        .ACC_W (ACC_W)
    ) u_array (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .w_shift   (w_shift),
        .w_commit  (w_commit),
        .w_col_in  (w_data),
        .a_row_in  (a_skewed),
        .v_in      (a_beat),
        .s_col_out (s_col),
        .v_col_out (v_col)
    );

    // -------------------------------------------------------------------------
    // Output deskew: column c delayed COLS-1-c cycles. The valid bits go
    // through a structurally identical delay line, so control can never drift
    // away from data.
    // -------------------------------------------------------------------------
    wire [COLS*ACC_W-1:0] s_deskew;
    wire [COLS-1:0]       v_deskew;

    skew_buffer #(
        .LANES   (COLS),
        .W       (ACC_W),
        .REVERSE (1)
    ) u_skew_out_d (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .din   (s_col),
        .dout  (s_deskew)
    );

    skew_buffer #(
        .LANES   (COLS),
        .W       (1),
        .REVERSE (1)
    ) u_skew_out_v (
        .clk   (clk),
        .rst_n (rst_n),
        .en    (en),
        .din   (v_col),
        .dout  (v_deskew)
    );

    // After deskew every lane carries the same valid; lane 0 is representative.
    wire acc_in_valid = v_deskew[0];

    // -------------------------------------------------------------------------
    // Cross-pass accumulation
    // -------------------------------------------------------------------------
    wire                  acc_valid;
    wire [COLS*ACC_W-1:0] acc_data;

    accum_bank #(
        .LANES (COLS),
        .ACC_W (ACC_W),
        .DEPTH (MAX_M)
    ) u_acc (
        .clk        (clk),
        .rst_n      (rst_n),
        .en         (en),
        .clr        (acc_clr),
        .first_pass (acc_first),
        .last_pass  (acc_last),
        .in_valid   (acc_in_valid),
        .in_data    (s_deskew),
        .out_valid  (acc_valid),
        .out_data   (acc_data)
    );

    // -------------------------------------------------------------------------
    // Requantisation
    // -------------------------------------------------------------------------
    wire              rq_valid;
    wire [COLS*8-1:0] rq_data;
    wire              rq_sat;

    requant #(
        .LANES (COLS),
        .ACC_W (ACC_W)
    ) u_requant (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (en),
        .in_valid  (acc_valid),
        .acc_in    (acc_data),
        .bias      (cfg_bias),
        .mult      (cfg_mult),
        .shift     (cfg_shift),
        .relu      (cfg_relu),
        .out_valid (rq_valid),
        .y_out     (rq_data),
        .sat_hit   (rq_sat)
    );

    assign sat_hit = rq_sat && en;

    // -------------------------------------------------------------------------
    // y_last is derived by counting released beats rather than by matching the
    // pipeline latency by hand -- correct by construction if the pipeline depth
    // ever changes.
    // -------------------------------------------------------------------------
    logic [15:0] ycnt;
    wire         rq_last = (ycnt == cfg_m_len - 16'd1);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                   ycnt <= 16'd0;
        else if (en && rq_valid)      ycnt <= rq_last ? 16'd0 : ycnt + 16'd1;
    end

    // -------------------------------------------------------------------------
    // Output FIFO. wr_en is qualified with `en` -- a frozen requant stage holds
    // its valid high, so an unqualified write would duplicate the beat.
    // -------------------------------------------------------------------------
    out_fifo #(
        .W     (COLS*8 + 1),
        .DEPTH (FIFO_DEPTH)
    ) u_fifo (
        .clk      (clk),
        .rst_n    (rst_n),
        .wr_en    (rq_valid && en),
        .wr_data  ({rq_last, rq_data}),
        .stall    (stall),
        .rd_valid (y_valid),
        .rd_data  ({y_last, y_data}),
        .rd_ready (y_ready)
    );

endmodule

`default_nettype wire
