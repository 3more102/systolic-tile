// -----------------------------------------------------------------------------
// pe_array -- ROWS x COLS weight-stationary systolic array of mac_pe cells.
//
// Port buses are flat (packed) so that the module stays portable across Icarus,
// Yosys, Quartus and Vivado; lane r of an 8-bit bus lives at bits [r*8 +: 8].
//
// Timing contract
// ---------------
//   * a_row_in must ALREADY be skewed (row r delayed r cycles).
//   * v_in is the valid of the row-0 activation, i.e. undelayed.
//   * column c produces its result ROWS+c cycles later, so v_col_out is
//     column-skewed and the caller must deskew it.
//
// Weight load order
// -----------------
// Weights shift in at the top of every column, one array row per w_shift pulse.
// The FIRST beat travels furthest, so it lands in row ROWS-1. The stream must
// therefore present array row ROWS-1 first and row 0 last. model/gen_vectors.py
// emits weights in exactly that order.
// -----------------------------------------------------------------------------
`default_nettype none

module pe_array #(
    parameter int ROWS  = 8,
    parameter int COLS  = 8,
    parameter int ACC_W = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     en,

    input  wire                     w_shift,
    input  wire                     w_commit,
    input  wire  [COLS*8-1:0]       w_col_in,   // one weight per column, top edge

    input  wire  [ROWS*8-1:0]       a_row_in,   // one activation per row, west edge
    input  wire                     v_in,       // valid of the row-0 activation

    output wire  [COLS*ACC_W-1:0]   s_col_out,  // bottom-edge partial sums
    output wire  [COLS-1:0]         v_col_out   // per-column valid (column-skewed)
);

    // Interconnect meshes. Declared as nets so a mix of continuous assignments
    // (edges) and module output ports (interior) is unambiguous in every tool.
    wire signed [7:0]       a_h [0:ROWS-1][0:COLS];   // west -> east
    wire signed [ACC_W-1:0] s_v [0:ROWS][0:COLS-1];   // north -> south
    wire                    v_v [0:ROWS][0:COLS-1];   // north -> south
    wire signed [7:0]       w_v [0:ROWS][0:COLS-1];   // north -> south

    genvar r, c;
    generate
        // ---- west edge -----------------------------------------------------
        for (r = 0; r < ROWS; r = r + 1) begin : g_west
            assign a_h[r][0] = a_row_in[r*8 +: 8];
        end

        // ---- north edge ----------------------------------------------------
        // Partial sums start at zero; weights enter the shadow chain here.
        for (c = 0; c < COLS; c = c + 1) begin : g_north
            assign s_v[0][c] = '0;
            assign w_v[0][c] = w_col_in[c*8 +: 8];
        end

        // The valid entering the top of column c must be delayed by c cycles,
        // matching the c cycles the activation spends hopping east to reach it.
        assign v_v[0][0] = v_in;
        for (c = 1; c < COLS; c = c + 1) begin : g_vskew
            logic v_q;
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n)  v_q <= 1'b0;
                else if (en) v_q <= v_v[0][c-1];
            end
            assign v_v[0][c] = v_q;
        end

        // ---- the array -----------------------------------------------------
        for (r = 0; r < ROWS; r = r + 1) begin : g_row
            for (c = 0; c < COLS; c = c + 1) begin : g_col
                mac_pe #(.ACC_W(ACC_W)) u_pe (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .en       (en),
                    .w_shift  (w_shift),
                    .w_commit (w_commit),
                    .w_in     (w_v[r][c]),
                    .w_out    (w_v[r+1][c]),
                    .a_in     (a_h[r][c]),
                    .a_out    (a_h[r][c+1]),
                    .s_in     (s_v[r][c]),
                    .s_out    (s_v[r+1][c]),
                    .v_in     (v_v[r][c]),
                    .v_out    (v_v[r+1][c])
                );
            end
        end

        // ---- south edge ----------------------------------------------------
        for (c = 0; c < COLS; c = c + 1) begin : g_south
            assign s_col_out[c*ACC_W +: ACC_W] = s_v[ROWS][c];
            assign v_col_out[c]                = v_v[ROWS][c];
        end
    endgenerate

endmodule

`default_nettype wire
