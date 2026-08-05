// =============================================================================
// Test C4 : lock/unlock transition with random distance between bursts
//
// 8 iterations of lock->unlock, each with a freshly randomized channel
// delay, resetting the generator and checker before each attempt.
// =============================================================================

task test_C4;
    integer idx;
    integer fail_flag;
    begin
        $display("\n[TEST C4] Lock/unlock transition with random delay between bursts");

        fail_flag = 0;
        for (idx = 0; idx < 8; idx = idx + 1) begin
            reset_generator();
            reset_checker();
            randomize_channel_delay();

            send_valid(CYCLES_TO_LOCK);
            if (!o_lock) begin
                $display("  FAIL [iter %0d, delay=%0d]: did not lock", idx, chan_delay);
                fail_flag = 1;
            end else
                $display("  [iter %0d] delay=%0d  LOCKED   OK", idx, chan_delay);

            send_invalid(UNLOCK_THRESHOLD);
            if (o_lock) begin
                $display("  FAIL [iter %0d, delay=%0d]: did not unlock", idx, chan_delay);
                fail_flag = 1;
            end else
                $display("  [iter %0d] delay=%0d  UNLOCKED OK", idx, chan_delay);
        end
        if (!fail_flag)
            $display("  PASS: every lock/unlock transition was correct with random distance");
    end
endtask
