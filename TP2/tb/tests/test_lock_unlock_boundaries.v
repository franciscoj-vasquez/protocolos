// =============================================================================
// Test C3 : lock/unlock boundaries through the channel
//
// With delay=7: (a) 4 valid + 1 invalid must never reach LOCK_THRESHOLD, and
// (b) once locked, (2 invalid + 1 valid) x10 must never reach
// UNLOCK_THRESHOLD.
// =============================================================================

task test_C3;
    integer idx;
    integer fail_flag;
    begin
        $display("\n[TEST C3] Lock/unlock boundaries with delay=7");

        set_channel_delay(7);

        reset_generator();
        reset_checker();
        send_valid(1);       // resync
        send_valid(4);       // 4 matches
        send_invalid(1);     // breaks before reaching 5
        if (!o_lock)
            $display("  PASS: 4 valid + 1 invalid -> never locked (with channel)");
        else
            $display("  FAIL: locked unexpectedly");

        reset_generator();
        lock_checker();
        if (!o_lock) begin
            $display("  FAIL: could not lock -- aborting C3b");
        end else begin
            fail_flag = 0;
            for (idx = 0; idx < 10; idx = idx + 1) begin
                send_invalid(2);
                send_valid(1);
                if (!o_lock) begin
                    $display("  FAIL: unlocked on iteration %0d", idx);
                    fail_flag = 1;
                end
            end
            if (!fail_flag)
                $display("  PASS: o_lock stayed HIGH through 10 iterations (2inv+1val) with channel");
        end
    end
endtask
