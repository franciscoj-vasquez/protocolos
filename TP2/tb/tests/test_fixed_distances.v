// =============================================================================
// Test C1 : lock across fixed channel distances
//
// Locks the checker through 5 fixed channel latencies (0, 4, 8, 12, 16
// cycles), resetting the generator before each attempt.
// =============================================================================

task test_C1;
    integer idx;
    integer fail_flag;
    begin
        $display("\n[TEST C1] Lock with different fixed channel latencies");

        fail_flag = 0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            reset_generator();
            set_channel_delay(idx * 4);   // 0, 4, 8, 12, 16
            lock_checker();
            if (o_lock)
                $display("  PASS [delay=%0d]: checker locked", idx*4);
            else begin
                $display("  FAIL [delay=%0d]: checker did NOT lock", idx*4);
                fail_flag = 1;
            end
        end
        if (!fail_flag)
            $display("  PASS: locked correctly at every latency tested");
    end
endtask
