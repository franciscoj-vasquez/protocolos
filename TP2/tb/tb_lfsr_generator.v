// =============================================================================
// Testbench : tb_lfsr_generator
// DUT       : lfsr_generator
//
// Activity 2 — infrastructure:
//   · 10 MHz clock (period = 100 ns)
//   · task_set_seed       : changes i_seed at runtime
//   · task_async_reset    : asserts i_rst for a random duration in [1us, 250us]
//   · task_soft_reset     : asserts i_soft_reset for a random duration in [1us, 250us]
//   · random valid        : process that randomizes rand_valid every cycle;
//                           i_valid is a wire that selects between forced_valid
//
// Activity 3 — tests:
//   · TEST 0a: i_rst        → o_data == DEFAULT_SEED, o_valid == 0
//   · TEST 0b: i_soft_reset → o_data == i_seed, o_valid == 0
//   · TEST 0c: priority     → i_soft_reset wins over simultaneous i_valid;
//              o_valid == 0 because there was no real sequence advance
//   · TEST 1 : periodicity with DEFAULT_SEED (expected: 65 535)
//   · TEST 2 : periodicity with 5 distinct random seeds
//   · TEST 3 : valid gating — output must not advance without i_valid; o_valid
//              must stay at 0
//   · TEST 4 : random valid — o_data vs. reference model under intermittent
//              i_valid (exercises rand_valid/rand_valid_en from Activity 2)
//              and o_valid vs. the i_valid sampled one cycle earlier
// =============================================================================

`timescale 1ns / 1ps

module tb_lfsr_generator;

    // =========================================================================
    // Simulation parameters
    // =========================================================================
    localparam CLK_PERIOD   = 100;          // 100 ns → 10 MHz
    localparam DATA_WIDTH   = 16;
    localparam DEFAULT_SEED = 16'hFFFF;
    localparam MAX_PERIOD   = (1 << DATA_WIDTH) - 1;   // 65 535
    localparam SAFETY_LIMIT = MAX_PERIOD + 100;        // anti-hang margin, scales with DATA_WIDTH

    localparam RST_MIN_NS   = 1_000;        // 1 us
    localparam RST_MAX_NS   = 250_000;      // 250 us

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg                    i_clk;
    reg                    i_rst;
    reg                    i_soft_reset;
    reg  [DATA_WIDTH-1:0]  i_seed;
    wire [DATA_WIDTH-1:0]  o_data;
    wire                   o_valid;

    // =========================================================================
    // i_valid control
    //   forced_valid : driven by the test sequences (initial block)
    //   rand_valid   : randomized by the always-on process (always block)
    //   i_valid      : wire that selects between both based on rand_valid_en
    // =========================================================================
    reg  forced_valid;
    reg  rand_valid;
    reg  rand_valid_en;

    wire i_valid = rand_valid_en ? rand_valid : forced_valid; // mux for random or fixed valid tests

    // =========================================================================
    // DUT instance
    // =========================================================================
    lfsr_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .DEFAULT_SEED(DEFAULT_SEED)
    ) dut (
        .i_clk       (i_clk),
        .i_rst       (i_rst),
        .i_soft_reset(i_soft_reset),
        .i_valid     (i_valid),
        .i_seed      (i_seed),
        .o_data      (o_data),
        .o_valid     (o_valid)
    );

    // =========================================================================
    // Activity 2 -- Clock generation — 10 MHz
    // =========================================================================
    initial i_clk = 1'b0;
    always  #(CLK_PERIOD / 2) i_clk = ~i_clk; // every 50 ns → clock edge

    // =========================================================================
    // Activity 2 -- Random valid process — active only when rand_valid_en=1
    // =========================================================================
    initial rand_valid = 1'b0; // initial value
    always @(posedge i_clk) begin
        if (rand_valid_en)
            rand_valid <= $urandom_range(0, 1);
    end

    // =========================================================================
    // Reference model (TEST 4) — same Galois topology as the DUT.
    // Lets us predict o_data cycle by cycle under intermittent i_valid
    // without depending on the DUT itself.
    // =========================================================================
    function [DATA_WIDTH-1:0] lfsr_step;
        input [DATA_WIDTH-1:0] s;
        reg fb;
        begin
            fb              = s[DATA_WIDTH-1];
            lfsr_step[0]    = fb;
            lfsr_step[1]    = s[0];
            lfsr_step[2]    = s[1];
            lfsr_step[3]    = s[2];
            lfsr_step[4]    = s[3];
            lfsr_step[5]    = s[4];
            lfsr_step[6]    = s[5];
            lfsr_step[7]    = s[6];
            lfsr_step[8]    = s[7];
            lfsr_step[9]    = s[8];
            lfsr_step[10]   = s[9];
            lfsr_step[11]   = s[10] ^ fb;
            lfsr_step[12]   = s[11];
            lfsr_step[13]   = s[12] ^ fb;
            lfsr_step[14]   = s[13] ^ fb;
            lfsr_step[DATA_WIDTH-1] = s[DATA_WIDTH-2];
        end
    endfunction

    // =========================================================================
    // Activity 2 -- Task: task_set_seed — updates i_seed
    // =========================================================================
    task task_set_seed;
        input [DATA_WIDTH-1:0] new_seed;
        begin
            i_seed = new_seed;
            $display("    [task_set_seed] i_seed = 0x%04X", new_seed);
        end
    endtask

    // =========================================================================
    // Activity 2 -- Task: task_async_reset — asserts i_rst for a random duration [1us, 250us]
    // =========================================================================
    task task_async_reset;
        integer rand_ns;
        begin
            rand_ns = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS; // random, modulo and offset
            $display("    [task_async_reset] i_rst active for %0d ns", rand_ns);
            i_rst = 1'b1;
            #(rand_ns);
            @(negedge i_clk); // avoid race condition
            i_rst = 1'b0;
            @(posedge i_clk);
            #1;
        end
    endtask

    // =========================================================================
    // Activity 2 -- Task: task_soft_reset — asserts i_soft_reset for a random duration [1us, 250us]
    // =========================================================================
    task task_soft_reset;
        integer rand_ns;
        begin
            rand_ns = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS;
            $display("    [task_soft_reset] i_soft_reset active for %0d ns (seed=0x%04X)",
                     rand_ns, i_seed);
            i_soft_reset = 1'b1;
            #(rand_ns);
            @(negedge i_clk); // avoid race condition
            i_soft_reset = 1'b0;
            @(posedge i_clk);
            #1;
        end
    endtask

    // =========================================================================
    // Test helper variables
    // =========================================================================
    integer              count;
    integer              idx;
    reg [DATA_WIDTH-1:0] initial_state;
    reg [DATA_WIDTH-1:0] rand_seed_val;
    reg [DATA_WIDTH-1:0] known_seed;
    integer              fail_flag;
    reg [DATA_WIDTH-1:0] ref_model;
    reg                  sampled_valid;

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin

        // ---- Initial signal state ----
        i_rst         = 1'b0;
        i_soft_reset  = 1'b0;
        forced_valid  = 1'b0;
        rand_valid_en = 1'b0;
        i_seed        = DEFAULT_SEED;

        // =====================================================================
        // TEST 0a: Async reset — o_data must be DEFAULT_SEED
        //   Directly verifies that i_rst loads the parameter's fixed seed.
        // =====================================================================
        $display("\n[TEST 0a] Async reset — o_data must be DEFAULT_SEED (0x%04X)", DEFAULT_SEED);

        task_async_reset();

        if (o_data === DEFAULT_SEED)
            $display("  PASS: o_data = 0x%04X", o_data);
        else
            $display("  FAIL: expected=0x%04X, got=0x%04X", DEFAULT_SEED, o_data);

        if (o_valid === 1'b0)
            $display("  PASS: o_valid = 0 after i_rst (no real advance)");
        else
            $display("  FAIL: o_valid = %0b after i_rst (expected 0)", o_valid);

        // =====================================================================
        // TEST 0b: Soft reset — o_data must be i_seed once the reset ends
        //   Verifies that i_soft_reset loads the value configured in i_seed.
        // =====================================================================
        $display("\n[TEST 0b] Soft reset — o_data must be i_seed (0xA5C3)");

        known_seed = 16'hA5C3;
        task_set_seed(known_seed);
        task_soft_reset();

        if (o_data === known_seed)
            $display("  PASS: o_data = 0x%04X", o_data);
        else
            $display("  FAIL: expected=0x%04X, got=0x%04X", known_seed, o_data);

        if (o_valid === 1'b0)
            $display("  PASS: o_valid = 0 after i_soft_reset (no real advance)");
        else
            $display("  FAIL: o_valid = %0b after i_soft_reset (expected 0)", o_valid);

        // =====================================================================
        // TEST 0c: Priority i_soft_reset > i_valid
        //   With both signals asserted on the same edge, i_soft_reset must
        //   win: the LFSR must load i_seed, NOT advance to lfsr_next.
        // =====================================================================
        $display("\n[TEST 0c] Priority: i_soft_reset must win over simultaneous i_valid");

        task_async_reset();           // LFSR = DEFAULT_SEED
        known_seed   = 16'hBEEF;
        i_seed       = known_seed;

        // Assert both in the same clock cycle
        i_soft_reset = 1'b1;
        forced_valid = 1'b1;
        @(posedge i_clk); #1;        // here the DUT must load i_seed, not advance
        i_soft_reset = 1'b0;
        forced_valid = 1'b0;

        if (o_data === known_seed)
            $display("  PASS: i_soft_reset won — o_data = 0x%04X (= i_seed)", o_data);
        else
            $display("  FAIL: o_data = 0x%04X (expected 0x%04X); i_soft_reset did not take priority",
                     o_data, known_seed);

        // o_valid must reflect that this data is a reseed, not a PRBS
        // advance, even though i_valid was 1 on the same edge: this is the
        // key proof that o_valid "travels with" the data instead of
        // echoing i_valid.
        if (o_valid === 1'b0)
            $display("  PASS: o_valid = 0 — reflects that there was NO real advance despite i_valid=1");
        else
            $display("  FAIL: o_valid = %0b (expected 0); a reseeded data word must not be marked valid",
                     o_valid);

        // =====================================================================
        // Activity 3 -- TEST 1: Periodicity with DEFAULT_SEED
        //   The LFSR is advanced cycle by cycle and counted until it returns
        //   to the initial state. For a maximal-length 16-bit LFSR, the
        //   period = 65 535.
        // =====================================================================
        $display("\n[TEST 1] Periodicity — DEFAULT_SEED = 0x%04X", DEFAULT_SEED);

        task_async_reset(); // initial value = DEFAULT_SEED
        forced_valid  = 1'b1; // enable the advance on every cycle
        initial_state = o_data;
        count         = 0;

        @(posedge i_clk); #1; count = 1;

        while (o_data !== initial_state) begin
            if (count >= SAFETY_LIMIT) begin
                $display("  FAIL: period exceeded the safety limit");
                $finish;
            end
            @(posedge i_clk); #1;
            count = count + 1;
        end
        // o_data returned to the initial state → end of period measurement

        if (count === MAX_PERIOD)
            $display("  PASS: period = %0d  (2^%0d - 1 confirmed)", count, DATA_WIDTH);
        else
            $display("  FAIL: expected = %0d, measured = %0d", MAX_PERIOD, count);

        forced_valid = 1'b0;

        // =====================================================================
        // Activity 3 -- TEST 2: Periodicity with random seeds
        //   For each seed: (a) async reset, (b) soft reset with random seed,
        //   (c) period measurement. Any seed ≠ 0 → period = 65 535.
        // =====================================================================
        $display("\n[TEST 2] Periodicity with 5 random seeds");

        for (idx = 0; idx < 5; idx = idx + 1) begin
            rand_seed_val = ($urandom & 16'hFFFF); // random 16-bit seed
            if (rand_seed_val == 16'h0000) rand_seed_val = 16'h0001; // would be a corner case, better to avoid it

            task_async_reset();
            task_set_seed(rand_seed_val);
            task_soft_reset();

            forced_valid  = 1'b1;
            initial_state = o_data;
            count         = 0;

            @(posedge i_clk); #1; count = 1;

            while (o_data !== initial_state) begin
                if (count >= SAFETY_LIMIT) begin
                    $display("  FAIL [seed=0x%04X]: period exceeded %0d", rand_seed_val, SAFETY_LIMIT);
                    count = -1;
                    initial_state = o_data;   // forces exit from the while loop
                end else begin
                    @(posedge i_clk); #1;
                    count = count + 1;
                end
            end

            // o_data returned to the initial state → end of period measurement
            if (count === MAX_PERIOD)
                $display("  PASS [seed=0x%04X] → period = %0d", rand_seed_val, count);
            else if (count !== -1)
                $display("  FAIL [seed=0x%04X] → expected=%0d, measured=%0d",
                         rand_seed_val, MAX_PERIOD, count);

            forced_valid = 1'b0;
            task_async_reset();
        end

        // =====================================================================
        // Extra -- TEST 3: Valid gating
        //   With i_valid=0 the LFSR state must remain constant.
        // =====================================================================
        $display("\n[TEST 3] Valid gating — output must hold without i_valid");

        task_async_reset();
        initial_state = o_data;
        forced_valid  = 1'b0;

        repeat (50) @(posedge i_clk); #1;

        if (o_data === initial_state)
            $display("  PASS: output stayed constant for 50 cycles without i_valid");
        else
            $display("  FAIL: output changed without i_valid — initial state=0x%04X, current=0x%04X",
                     initial_state, o_data);

        if (o_valid === 1'b0)
            $display("  PASS: o_valid stayed at 0 during gating (no new data)");
        else
            $display("  FAIL: o_valid = %0b without i_valid (expected 0)", o_valid);

        forced_valid = 1'b0;

        // =====================================================================
        // Extra -- TEST 4: Random valid
        //   Enables rand_valid_en and compares o_data, cycle by cycle,
        //   against a reference model that only advances (lfsr_step) on
        //   cycles where the i_valid sampled by the DUT was 1, and holds
        //   otherwise. Exercises the rand_valid/rand_valid_en process
        //   (Activity 2)
        // =====================================================================
        $display("\n[TEST 4] Random valid — o_data vs. reference model under intermittent i_valid");

        task_async_reset();            // lfsr = DEFAULT_SEED, synchronizes the model
        ref_model     = o_data;
        rand_valid_en = 1'b1;
        fail_flag     = 0;

        for (idx = 0; idx < 3000; idx = idx + 1) begin
            sampled_valid = i_valid;   // value the DUT is about to sample on the next posedge
            @(posedge i_clk); #1;

            if (sampled_valid)
                ref_model = lfsr_step(ref_model);

            if (o_data !== ref_model) begin
                $display("  FAIL: cycle %0d — o_data=0x%04X, expected=0x%04X (sampled i_valid=%0b)",
                         idx, o_data, ref_model, sampled_valid);
                fail_flag = 1;
            end

            // o_valid must travel together with o_data
            if (o_valid !== sampled_valid) begin
                $display("  FAIL: cycle %0d — o_valid=%0b, expected=%0b (must travel with o_data)",
                         idx, o_valid, sampled_valid);
                fail_flag = 1;
            end
        end

        rand_valid_en = 1'b0;

        if (!fail_flag)
            $display("  PASS: o_data and o_valid matched the reference model over 3000 cycles of random valid");
        else
            $display("  FAIL: at least one mismatch occurred under random valid (see detail above)");

        // =====================================================================
        $display("\n[DONE] Simulation complete.\n");
        $finish;
    end

endmodule
