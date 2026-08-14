// -----------------------------------------------------------------------------
// selftest_shell -- board-independent glue around tile_selftest.
//
// Everything that is about "being on a board" rather than about the tile lives
// here: reset synchronisation, input synchronisation, and a power-on start so
// the design reports a verdict without anyone pressing a button. The board tops
// are then pure pin mapping, which is what makes the same design build for both
// a Cyclone V and a Zynq without a single shared line of vendor IP.
//
// No debouncer: a bouncing start button can only re-trigger a run, and
// tile_selftest ignores `start` unless it is idle. Re-running a self-test is
// harmless, so the gate count is better spent elsewhere.
// -----------------------------------------------------------------------------
`default_nettype none

module selftest_shell (
    input  wire       clk,
    input  wire       arst_n,      // raw asynchronous reset, active low
    input  wire       start_btn,   // active high, unsynchronised
    input  wire       bp_en_raw,   // active high, unsynchronised
    input  wire [7:0] probe_idx,

    output wire       busy,
    output wire       done,
    output wire       pass,
    output wire       fail,
    output wire [7:0] probe_data
);

    // ---- reset synchroniser: assert asynchronously, release synchronously ---
    logic [1:0] rst_sync;
    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) rst_sync <= 2'b00;
        else         rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_n = rst_sync[1];

    // ---- input synchronisers ------------------------------------------------
    logic [2:0] btn_sync;
    logic [1:0] bp_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_sync <= 3'b000;
            bp_sync  <= 2'b00;
        end else begin
            btn_sync <= {btn_sync[1:0], start_btn};
            bp_sync  <= {bp_sync[0],    bp_en_raw};
        end
    end
    wire btn_rise = btn_sync[1] & ~btn_sync[2];

    // ---- power-on start -----------------------------------------------------
    // ~0.5 ms at 125 MHz, ~1.3 ms at 50 MHz: long enough for the ROMs to be
    // settled and for a human to see the LEDs change state on power-up.
    logic [15:0] boot_cnt;
    logic        booted;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boot_cnt <= 16'd0;
            booted   <= 1'b0;
        end else if (!booted) begin
            if (boot_cnt == 16'hFFFF) booted   <= 1'b1;
            else                      boot_cnt <= boot_cnt + 16'd1;
        end
    end
    wire boot_pulse = !booted && (boot_cnt == 16'hFFFF);

    tile_selftest u_selftest (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (boot_pulse | btn_rise),
        .bp_en      (bp_sync[1]),
        .probe_idx  (probe_idx),
        .busy       (busy),
        .done       (done),
        .pass       (pass),
        .fail       (fail),
        .probe_data (probe_data)
    );

endmodule

`default_nettype wire
