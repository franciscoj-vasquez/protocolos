// =============================================================================
// Testbench : tb_lfsr_system_channel
// DUTs      : lfsr_generator + channel_delay + lfsr_checker
//
// This file holds only the shared infrastructure (DUT instances, clock,
// o_lock monitor, and the reset/send helper tasks). Each test (C0..C6) lives
// in its own file under tests/, named after what it verifies, and is pulled
// in via `include as a task (test_C0, test_C1, ...) — the tasks need direct
// access to this module's signals, so `include is used instead of separate
// compilation. See the `include list below for the C0..C6 <-> filename map.
//
// Test selection happens at run time via a +TEST=<name> plusarg, dispatched
// through the case statement at the bottom of this file:
//   vvp sim_chan.vvp +TEST=C3     -> runs only test C3
//   vvp sim_chan.vvp              -> runs the full suite (equivalent to
//                                     +TEST=ALL)
// =============================================================================

`timescale 1ns / 1ps

module tb_lfsr_system_channel;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD       = 100;
    localparam DATA_WIDTH       = 16;
    localparam DEFAULT_SEED     = 16'hFFFF;
    localparam MAX_PERIOD       = (1 << DATA_WIDTH) - 1;   // 65 535
    localparam LOCK_THRESHOLD   = 5;
    localparam UNLOCK_THRESHOLD = 3;
    localparam MAX_DELAY        = 31;
    localparam DELAY_WIDTH      = 5;

    localparam RST_MIN_NS = 1_000;
    localparam RST_MAX_NS = 250_000;

    localparam CYCLES_TO_LOCK = 1 + LOCK_THRESHOLD;

    // =========================================================================
    // Signals
    // =========================================================================
    reg                    i_clk;

    // Generator
    reg                    gen_rst;
    reg                    gen_soft_rst;
    reg  [DATA_WIDTH-1:0]  i_seed;
    wire [DATA_WIDTH-1:0]  gen_o_data;
    wire                   gen_o_valid;

    // i_valid control — can be forced to 1/0 or random (when rand_valid_en=1)
    reg                    forced_valid;
    reg                    rand_valid;
    reg                    rand_valid_en;
    wire                   i_valid = rand_valid_en ? rand_valid : forced_valid;

    // Channel
    reg                    chan_rst;
    reg  [DELAY_WIDTH-1:0] chan_delay;
    wire [DATA_WIDTH-1:0]  chan_o_data;
    wire                   chan_o_valid;

    // Checker
    reg                    chk_rst;
    reg                    inject_error;
    wire                   o_lock;

    // =========================================================================
    // Instances
    // =========================================================================
    lfsr_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .DEFAULT_SEED(DEFAULT_SEED)
    ) u_gen (
        .i_clk       (i_clk),
        .i_rst       (gen_rst),
        .i_soft_reset(gen_soft_rst),
        .i_valid     (i_valid),
        .i_seed      (i_seed),
        .o_data      (gen_o_data),
        .o_valid     (gen_o_valid)
    );

    // inject_error feeds directly into the channel's port (i_inject_error);
    channel_delay #(
        .DATA_WIDTH  (DATA_WIDTH),
        .MAX_DELAY   (MAX_DELAY),
        .DELAY_WIDTH (DELAY_WIDTH)
    ) u_chan (
        .i_clk          (i_clk),
        .i_rst          (chan_rst),
        .i_data         (gen_o_data),
        .i_valid        (gen_o_valid),
        .i_inject_error (inject_error),
        .i_delay        (chan_delay),
        .o_data         (chan_o_data),
        .o_valid        (chan_o_valid)
    );

    lfsr_checker #(
        .DATA_WIDTH       (DATA_WIDTH),
        .LOCK_THRESHOLD   (LOCK_THRESHOLD),
        .UNLOCK_THRESHOLD (UNLOCK_THRESHOLD)
    ) u_chk (
        .i_clk   (i_clk),
        .i_rst   (chk_rst),
        .i_valid (chan_o_valid),
        .i_data  (chan_o_data),
        .o_lock  (o_lock)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial i_clk = 1'b0;
    always  #(CLK_PERIOD / 2) i_clk = ~i_clk;

    // =========================================================================
    // Random valid process — active only when rand_valid_en=1 (same
    // mechanism as tb_lfsr_generator.v)
    // =========================================================================
    initial rand_valid = 1'b0;
    always @(posedge i_clk) begin
        if (rand_valid_en)
            rand_valid <= $urandom_range(0, 1);
    end

    // =========================================================================
    // o_lock monitor
    // =========================================================================
    reg prev_lock;
    initial prev_lock = 1'b0;

    always @(o_lock) begin
        $display("[LOCK MONITOR] t=%0t ns  |  o_lock: %0b -> %0b  (chan_delay=%0d)",
                 $time, prev_lock, o_lock, chan_delay);
        prev_lock = o_lock;
    end

    // =========================================================================
    // Reset tasks
    // =========================================================================
    task reset_generator;
        integer rnd;
        begin
            rnd     = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS;
            gen_rst = 1'b1;
            #(rnd);
            @(negedge i_clk);
            gen_rst = 1'b0;
            @(posedge i_clk); #1;
        end
    endtask

    task reset_checker;
        integer rnd;
        begin
            rnd     = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS;
            chk_rst = 1'b1;
            #(rnd);
            @(negedge i_clk);
            chk_rst = 1'b0;
            @(posedge i_clk); #1;
        end
    endtask

    // =========================================================================
    // Task: set_channel_delay — changes the channel latency safely.
    //   Pulses chan_rst together with the chan_delay change so the channel
    //   starts out "empty" at the new distance (avoids mixing in-flight
    //   data with different delays — analogous to reconnecting the cable).
    // =========================================================================
    task set_channel_delay;
        input [DELAY_WIDTH-1:0] new_delay;
        begin
            @(negedge i_clk);
            chan_rst   = 1'b1;
            chan_delay = new_delay;
            @(posedge i_clk); #1;
            @(negedge i_clk);
            chan_rst   = 1'b0;
            @(posedge i_clk); #1;
            $display("    [set_channel_delay] delay = %0d cycles", new_delay);
        end
    endtask

    task randomize_channel_delay;
        reg [DELAY_WIDTH-1:0] d;
        begin
            d = $urandom_range(0, MAX_DELAY);
            set_channel_delay(d);
        end
    endtask

    // =========================================================================
    // Task: send_valid / send_invalid — 50/50 random gating of i_valid
    //   until n data words are delivered, with the drain generalized to
    //   (chan_delay + 1) cycles (see file header).
    // =========================================================================
    task send_valid;
        input integer n;
        integer sent;
        reg     sampled;
        begin
            inject_error  = 1'b0;
            rand_valid_en = 1'b1;
            #1;   // let the i_valid mux settle (rand_valid_en just changed)
            sent          = 0;
            while (sent < n) begin
                sampled = i_valid;   // value that will be sampled on the next posedge
                @(posedge i_clk); #1;
                if (sampled) sent = sent + 1;
            end
            rand_valid_en = 1'b0;
            forced_valid  = 1'b0;
            repeat (chan_delay + 1) @(posedge i_clk);   // drain: generator + channel
            #1;
        end
    endtask

    task send_invalid;
        input integer n;
        integer sent;
        reg     sampled;
        begin
            inject_error  = 1'b1;
            rand_valid_en = 1'b1;
            #1;   // let the i_valid mux settle (rand_valid_en just changed)
            sent          = 0;
            while (sent < n) begin
                sampled = i_valid;   // value that will be sampled on the next posedge
                @(posedge i_clk); #1;
                if (sampled) sent = sent + 1;
            end
            rand_valid_en = 1'b0;
            forced_valid  = 1'b0;
            repeat (chan_delay + 1) @(posedge i_clk);   // drain: generator + channel
            inject_error  = 1'b0;
            #1;
        end
    endtask

    task lock_checker;
        begin
            reset_checker();
            send_valid(CYCLES_TO_LOCK);
        end
    endtask

    // =========================================================================
    // Test bodies — one task per file, named after the test it implements.
    // =========================================================================
    `include "tests/test_direct_connection.v"          // C0
    `include "tests/test_fixed_distances.v"             // C1
    `include "tests/test_max_delay_traffic.v"           // C2
    `include "tests/test_lock_unlock_boundaries.v"      // C3
    `include "tests/test_random_distance_transitions.v" // C4
    `include "tests/test_chained_transitions.v"         // C5
    `include "tests/test_reset_mid_traffic.v"           // C6

    // =========================================================================
    // Test dispatch — selects which test(s) to run via a +TEST=<name>
    // plusarg. No plusarg (or +TEST=ALL) runs the full suite C0..C6 in
    // order, matching the original behaviour of this testbench.
    // =========================================================================
    reg [8*8-1:0] test_name;

    initial begin

        gen_rst       = 1'b0;
        gen_soft_rst  = 1'b0;
        chk_rst       = 1'b0;
        chan_rst      = 1'b0;
        chan_delay    = {DELAY_WIDTH{1'b0}};
        forced_valid  = 1'b0;
        rand_valid_en = 1'b0;
        i_seed        = DEFAULT_SEED;
        inject_error  = 1'b0;

        reset_generator();
        set_channel_delay(0);
        reset_checker();

        if (!$value$plusargs("TEST=%s", test_name))
            test_name = "ALL";

        case (test_name)
            "C0":  test_C0();
            "C1":  test_C1();
            "C2":  test_C2();
            "C3":  test_C3();
            "C4":  test_C4();
            "C5":  test_C5();
            "C6":  test_C6();
            "ALL": begin
                test_C0();
                test_C1();
                test_C2();
                test_C3();
                test_C4();
                test_C5();
                test_C6();
            end
            default:
                $display("[ERROR] Unknown +TEST=%0s (expected C0..C6 or ALL)", test_name);
        endcase

        $display("\n[DONE] System simulation with channel complete.\n");
        $finish;
    end

endmodule
