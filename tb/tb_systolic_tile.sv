// -----------------------------------------------------------------------------
// tb_systolic_tile -- self-checking top-level testbench.
//
// Drives one matmul case end to end and compares every output beat against
// model/golden.py. Nothing here is hand-written: stimulus AND expected results
// both come from the generator, so a mismatch is always a real RTL/model
// divergence rather than a stale expectation baked into the test.
//
// Plusargs
//   +case=<dir>  vector directory (default vectors/basic)
//   +bp=1        random backpressure on y_ready and random bubbles on a_valid.
//                These are the stall and gap paths a clean stream never
//                touches, and they are where a systolic array is most likely to
//                lose its diagonal alignment.
//   +vcd         dump waves to waves.vcd
//
// Sampling discipline: stimulus is driven on negedge, handshakes are sampled on
// negedge (every ready is registered-derived and therefore stable there), and
// the result monitor sits on posedge where it observes pre-edge values. That
// keeps the testbench free of races without needing clocking blocks, which not
// every simulator in the flow supports.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module tb_systolic_tile;

    localparam int ROWS  = 8;
    localparam int COLS  = 8;
    localparam int ACC_W = 32;
    localparam int MAXB  = 8192;

    // ------------------------------------------------------------------ clock
    logic clk = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz

    logic rst_n;

    // ----------------------------------------------------------------- DUT io
    logic                  start, first_pass, last_pass;
    logic [15:0]           cfg_m_len, cfg_mult;
    logic [5:0]            cfg_shift;
    logic                  cfg_relu;
    logic [COLS*ACC_W-1:0] cfg_bias;
    wire                   busy, done;

    logic                  w_valid;
    wire                   w_ready;
    logic [COLS*8-1:0]     w_data;

    logic                  a_valid;
    wire                   a_ready;
    logic [ROWS*8-1:0]     a_data;

    wire                   y_valid;
    wire                   y_ready;
    wire [COLS*8-1:0]      y_data;
    wire                   y_last;
    wire                   sat_hit;

    systolic_tile #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .ACC_W      (ACC_W),
        .MAX_M      (256),
        .FIFO_DEPTH (8)
    ) dut (
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

    // ---------------------------------------------------------------- vectors
    string                 casedir;
    int                    bp_mode;
    logic [15:0]           meta     [0:6];
    logic [ROWS*8-1:0]     a_mem    [0:MAXB-1];
    logic [COLS*8-1:0]     w_mem    [0:MAXB-1];
    logic [COLS*ACC_W-1:0] bias_mem [0:0];
    logic [COLS*8-1:0]     y_mem    [0:MAXB-1];

    int M, K, N, PASSES, MULT, SHIFT, RELU;
    int p, i, guard;

    // --------------------------------------------- deterministic randomisation
    // A plain LFSR rather than $random so the stimulus is identical on every
    // simulator, which matters when the same test is run under Icarus in CI and
    // ModelSim locally.
    logic [15:0] lfsr;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[14:0],
                             lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    // bp=0 never stalls, bp=1 accepts ~1/2 the time, bp=2 ~1/4 -- only the
    // aggressive mode reliably fills the output FIFO and exercises the
    // array-wide freeze.
    assign y_ready = (bp_mode == 0) ? 1'b1
                   : (bp_mode == 1) ? lfsr[0]
                                    : (lfsr[0] & lfsr[7]);

    // ---------------------------------------------------- monitor + coverage
    int y_count, errors, extra_beats;
    int stall_cycles, bubble_cycles, sat_beats;
    int cur_pass;

    // Measured pipeline latency: cycles from the first activation beat of the
    // last pass being accepted to the first result beat leaving the tile. Only
    // meaningful with bp=0, since a stall inflates it by construction.
    int cycle_count, first_a_cycle, first_y_cycle;

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count = cycle_count + 1;
            if (a_valid && a_ready && cur_pass == PASSES - 1 && first_a_cycle < 0)
                first_a_cycle = cycle_count;

            if (y_valid && y_ready) begin
                if (first_y_cycle < 0) first_y_cycle = cycle_count;
                if (cur_pass != PASSES - 1) begin
                    errors = errors + 1;
                    if (errors <= 12)
                        $display("  FAIL: result beat emitted during pass %0d (results must appear only on the last pass)",
                                 cur_pass);
                end
                if (y_count < M) begin
                    if (y_data !== y_mem[y_count]) begin
                        errors = errors + 1;
                        if (errors <= 12)
                            $display("  FAIL beat %0d: got %h want %h",
                                     y_count, y_data, y_mem[y_count]);
                    end
                    if (y_last !== ((y_count == M - 1) ? 1'b1 : 1'b0)) begin
                        errors = errors + 1;
                        if (errors <= 12)
                            $display("  FAIL beat %0d: y_last=%b want %b",
                                     y_count, y_last, (y_count == M - 1));
                    end
                end else begin
                    extra_beats = extra_beats + 1;
                end
                y_count = y_count + 1;
            end

            if (sat_hit)                        sat_beats     = sat_beats + 1;
            if (busy && !dut.en)                stall_cycles  = stall_cycles + 1;
            if (busy && dut.en && a_ready && !a_valid)
                                                bubble_cycles = bubble_cycles + 1;
        end
    end

    // ---------------------------------------------------------------- drivers
    task automatic put_w(input logic [COLS*8-1:0] d);
        begin
            @(negedge clk);
            w_valid = 1'b1;
            w_data  = d;
            while (!w_ready) @(negedge clk);
            @(posedge clk);
        end
    endtask

    task automatic put_a(input logic [ROWS*8-1:0] d);
        begin
            @(negedge clk);
            if (bp_mode != 0) begin
                // ~25% chance of opening a gap, then geometrically distributed
                // length. Bubbles must not disturb the diagonal wavefront.
                a_valid = 1'b0;
                while (lfsr[3] & lfsr[5]) @(negedge clk);
            end
            a_valid = 1'b1;
            a_data  = d;
            while (!a_ready) @(negedge clk);
            @(posedge clk);
        end
    endtask

    task automatic drive_pass(input int pass_num);
        int j;
        begin
            cur_pass = pass_num;

            @(negedge clk);
            start      = 1'b1;
            first_pass = (pass_num == 0);
            last_pass  = (pass_num == PASSES - 1);
            @(negedge clk);
            start = 1'b0;

            for (j = 0; j < ROWS; j = j + 1) put_w(w_mem[pass_num*ROWS + j]);
            @(negedge clk);
            w_valid = 1'b0;

            for (j = 0; j < M; j = j + 1) put_a(a_mem[pass_num*M + j]);
            @(negedge clk);
            a_valid = 1'b0;

            @(posedge done);
        end
    endtask

    // ------------------------------------------------------------------- main
    initial begin
        errors = 0; y_count = 0; extra_beats = 0;
        stall_cycles = 0; bubble_cycles = 0; sat_beats = 0; cur_pass = 0;
        cycle_count = 0; first_a_cycle = -1; first_y_cycle = -1;

        if (!$value$plusargs("case=%s", casedir)) casedir = "vectors/basic";
        if (!$value$plusargs("bp=%d", bp_mode))   bp_mode = 0;
        if ($test$plusargs("vcd")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, tb_systolic_tile);
        end

        $readmemh($sformatf("%s/meta.hex", casedir), meta);
        M      = meta[0];  K     = meta[1];  N    = meta[2];
        PASSES = meta[3];  MULT  = meta[4];  SHIFT = meta[5];  RELU = meta[6];

        // Explicit ranges: reading into the full arrays would warn about the
        // unused tail on every run and bury real messages in CI logs.
        $readmemh($sformatf("%s/a.hex",    casedir), a_mem, 0, PASSES*M - 1);
        $readmemh($sformatf("%s/w.hex",    casedir), w_mem, 0, PASSES*ROWS - 1);
        $readmemh($sformatf("%s/bias.hex", casedir), bias_mem);
        $readmemh($sformatf("%s/y.hex",    casedir), y_mem, 0, M - 1);

        $display("");
        $display("=== tb_systolic_tile : %0s ===", casedir);
        $display("    M=%0d K=%0d N=%0d passes=%0d mult=%0d shift=%0d relu=%0d bp=%0d",
                 M, K, N, PASSES, MULT, SHIFT, RELU, bp_mode);

        if (N != COLS) begin
            $display("  FAIL: case N=%0d does not match COLS=%0d", N, COLS);
            errors = errors + 1;
        end
        if (K != PASSES * ROWS) begin
            $display("  FAIL: case K=%0d is not passes(%0d) * ROWS(%0d)",
                     K, PASSES, ROWS);
            errors = errors + 1;
        end
        if (M < 1) begin
            $display("  FAIL: M must be >= 1");
            errors = errors + 1;
        end

        cfg_m_len = M;
        cfg_mult  = MULT;
        cfg_shift = SHIFT;
        cfg_relu  = (RELU != 0);
        cfg_bias  = bias_mem[0];

        rst_n      = 1'b0;
        start      = 1'b0;
        first_pass = 1'b0;
        last_pass  = 1'b0;
        w_valid    = 1'b0;
        a_valid    = 1'b0;
        w_data     = '0;
        a_data     = '0;
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        if (errors == 0) begin
            for (p = 0; p < PASSES; p = p + 1) drive_pass(p);

            // With backpressure the tile can report `done` while results are
            // still sitting in the output FIFO, so wait for the stream itself.
            guard = 0;
            while (y_count < M && guard < 200000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end

        repeat (20) @(posedge clk);

        if (y_count != M) begin
            $display("  FAIL: got %0d result beats, expected %0d", y_count, M);
            errors = errors + 1;
        end
        if (extra_beats != 0) begin
            $display("  FAIL: %0d result beats past the end of the stream",
                     extra_beats);
            errors = errors + 1;
        end

        $display("    beats checked  : %0d / %0d", y_count, M);
        if (bp_mode == 0 && first_a_cycle >= 0 && first_y_cycle >= 0)
            $display("    pipeline depth : %0d cycles (first activation -> first result)",
                     first_y_cycle - first_a_cycle);
        $display("    stall cycles   : %0d", stall_cycles);
        $display("    input bubbles  : %0d", bubble_cycles);
        $display("    clamping beats : %0d", sat_beats);
        if (errors == 0) $display("    RESULT: PASS");
        else             $display("    RESULT: FAIL (%0d errors)", errors);
        $display("");
        $finish;
    end

    // --------------------------------------------------------------- watchdog
    initial begin
        #5_000_000;
        $display("    RESULT: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
