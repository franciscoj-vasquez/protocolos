// =============================================================================
// Test C5 : chained transition without reset between iterations
//
// Pattern (CYCLES_TO_LOCK valid + UNLOCK_THRESHOLD invalid) x5, WITHOUT
// resetting the generator/checker between iterations (unlike C4). The
// channel delay is re-randomized before every iteration — safe to change
// here because send_valid/send_invalid already drain the channel before
// returning, so there is never in-flight data when the distance changes,
// and only the channel is touched (gen_rst/chk_rst are not). Verifies it
// always alternates between LOCKED and UNLOCKED under continuous traffic
// and a varying channel distance, not just after a clean reset at a fixed
// delay.
// =============================================================================

task test_C5;
    integer idx;
    integer fail_flag;
    begin
        $display("\n[TEST C5] Chained transition (no reset between iterations) with random delay per iteration");

        reset_generator();
        reset_checker();

        fail_flag = 0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            randomize_channel_delay();

            send_valid(CYCLES_TO_LOCK);
            if (!o_lock) begin
                $display("  FAIL [iter %0d, delay=%0d]: did not lock after %0d valid", idx, chan_delay, CYCLES_TO_LOCK);
                fail_flag = 1;
            end else
                $display("  [iter %0d] delay=%0d  LOCKED   OK", idx, chan_delay);

            send_invalid(UNLOCK_THRESHOLD);
            if (o_lock) begin
                $display("  FAIL [iter %0d, delay=%0d]: did not unlock after %0d invalid", idx, chan_delay, UNLOCK_THRESHOLD);
                fail_flag = 1;
            end else
                $display("  [iter %0d] delay=%0d  UNLOCKED OK", idx, chan_delay);
        end

        if (!fail_flag)
            $display("  PASS: every chained lock/unlock transition was correct (with random delay per iteration)");
    end
endtask
