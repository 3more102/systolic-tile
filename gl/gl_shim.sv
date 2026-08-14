// -----------------------------------------------------------------------------
// gl_shim -- lets tb_systolic_tile drive a synthesised netlist unchanged.
//
// The testbench instantiates `systolic_tile` with a parameter override list. A
// gate netlist has no parameters: everything was resolved at elaboration. This
// module takes that name and that parameter list, ignores the values, and wires
// the ports straight through to the netlist, which scripts/gatelevel.sh renames
// to systolic_tile_gates so the two can coexist.
//
// Ignoring the parameters is safe rather than sloppy, because ROWS and COLS
// still set the port widths here. If the netlist were built at a different
// geometry than the testbench binary, the widths would disagree and Icarus would
// refuse to elaborate -- which is exactly the error you want for that mistake.
//
// MAX_M is the one parameter with no such backstop: it sets the accumulator
// depth, not a port width. The driver passes the same value to yosys and to
// iverilog from a single variable so they cannot drift apart.
// -----------------------------------------------------------------------------
`default_nettype none

module systolic_tile #(
    parameter int ROWS       = 8,
    parameter int COLS       = 8,
    parameter int ACC_W      = 32,
    parameter int MAX_M      = 256,
    parameter int FIFO_DEPTH = 8
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     start,
    input  wire                     first_pass,
    input  wire                     last_pass,
    input  wire  [15:0]             cfg_m_len,
    input  wire  [15:0]             cfg_mult,
    input  wire  [5:0]              cfg_shift,
    input  wire                     cfg_relu,
    input  wire  [COLS*ACC_W-1:0]   cfg_bias,
    output wire                     busy,
    output wire                     done,

    input  wire                     w_valid,
    output wire                     w_ready,
    input  wire  [COLS*8-1:0]       w_data,

    input  wire                     a_valid,
    output wire                     a_ready,
    input  wire  [ROWS*8-1:0]       a_data,

    output wire                     y_valid,
    input  wire                     y_ready,
    output wire [COLS*8-1:0]        y_data,
    output wire                     y_last,

    output wire                     sat_hit
);

    systolic_tile_gates u_gates (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .first_pass (first_pass),
        .last_pass  (last_pass),
        .cfg_m_len  (cfg_m_len),
        .cfg_mult   (cfg_mult),
        .cfg_shift  (cfg_shift),
        .cfg_relu   (cfg_relu),
        .cfg_bias   (cfg_bias),
        .busy       (busy),
        .done       (done),
        .w_valid    (w_valid),
        .w_ready    (w_ready),
        .w_data     (w_data),
        .a_valid    (a_valid),
        .a_ready    (a_ready),
        .a_data     (a_data),
        .y_valid    (y_valid),
        .y_ready    (y_ready),
        .y_data     (y_data),
        .y_last     (y_last),
        .sat_hit    (sat_hit)
    );

endmodule

`default_nettype wire
