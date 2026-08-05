// =============================================================================
// Test C6 : random checker reset in the middle of traffic
//
// 5 iterations: a valid burst of random duration, then a checker reset
// halfway through traffic (not from a clean state), then confirms the
// checker always relocks from the generator's current state.
// =============================================================================

task test_C6;
    integer idx;
    integer fail_flag;
    begin
        $display("\n[TEST C6] Random checker reset x5 in the middle of traffic -- must relock (with channel)");

        randomize_channel_delay();
        reset_generator();

        fail_flag = 0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            // Valid traffic for a random time before the reset
            send_valid($urandom_range(1, 50));

            reset_checker();

            if (o_lock) begin
                $display("  FAIL [iter %0d]: o_lock did not drop after reset", idx);
                fail_flag = 1;
            end

            // Relock from the generator's current state
            send_valid(CYCLES_TO_LOCK);

            if (o_lock)
                $display("  PASS [iter %0d]: checker relocked correctly", idx);
            else begin
                $display("  FAIL [iter %0d]: checker could not relock", idx);
                fail_flag = 1;
            end
        end

        if (!fail_flag)
            $display("  PASS: every re-lock succeeded after a random reset (with channel)");
    end
endtask
