// =============================================================================
// Test C0 : delay=0 regression
//
// Verifies that delay=0 behaves exactly like a direct connection between
// generator and checker. Soft-resets the generator to a known seed (0xCAFE)
// and confirms the checker can lock starting from that new seed through the
// channel. This is the literal deliverable for Activity 5.
// =============================================================================

task test_C0;
    begin
        $display("\n[TEST C0] delay=0 -- must behave the same as without a channel");

        i_seed = 16'hCAFE;
        gen_soft_rst = 1'b1;
        @(posedge i_clk);       // loads i_seed at this posedge
        @(negedge i_clk);
        gen_soft_rst = 1'b0;
        @(posedge i_clk); #1;

        if (gen_o_data === 16'hCAFE)
            $display("  PASS [C0a]: gen_o_data = 0x%04X after gen_soft_rst", gen_o_data);
        else
            $display("  FAIL [C0a]: expected=0xCAFE, got=0x%04X", gen_o_data);

        reset_checker();
        send_valid(CYCLES_TO_LOCK);

        if (o_lock)
            $display("  PASS [C0b]: checker locked with gen seed=0xCAFE through the channel (delay=0)");
        else
            $display("  FAIL [C0b]: checker could not lock after the generator's soft reset");

        // Restore seed and initial state for the following tests
        i_seed = DEFAULT_SEED;
        reset_generator();

        lock_checker();
        if (o_lock)
            $display("  PASS [C0c]: locked with delay=0 (equivalent to a direct connection)");
        else
            $display("  FAIL [C0c]: failed to lock with delay=0");
    end
endtask
