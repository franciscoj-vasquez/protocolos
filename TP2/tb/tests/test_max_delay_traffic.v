// =============================================================================
// Test C2 : continuous valid traffic at maximum channel latency
//
// With delay=MAX_DELAY (31, the longest latency the channel supports), sends
// a full period of 50/50-gated valid data (65 535 words) and confirms o_lock
// never drops.
// =============================================================================

task test_C2;
    integer fail_flag;
    integer valid_sent;
    reg     sampled_valid;
    begin
        $display("\n[TEST C2] Continuous valid traffic (50/50 random) with delay=%0d -- hold for %0d data words",
                  MAX_DELAY, MAX_PERIOD);

        reset_generator();
        set_channel_delay(MAX_DELAY);
        lock_checker();

        if (!o_lock) begin
            $display("  FAIL: did not lock -- aborting C2");
        end else begin
            fail_flag     = 0;
            inject_error  = 1'b0;
            rand_valid_en = 1'b1;
            #1;   // let the i_valid mux settle (rand_valid_en just changed)
            valid_sent    = 0;
            while (valid_sent < MAX_PERIOD) begin
                sampled_valid = i_valid;   // value that will be sampled on the next posedge
                @(posedge i_clk); #1;
                if (sampled_valid) valid_sent = valid_sent + 1;
                if (!o_lock) fail_flag = 1;
            end
            rand_valid_en = 1'b0;
            forced_valid  = 1'b0;   // the generator's last data word left, now the channel must drain
            repeat (chan_delay + 1) @(posedge i_clk);

            if (!fail_flag)
                $display("  PASS: o_lock stayed HIGH through the whole period with delay=%0d", MAX_DELAY);
            else
                $display("  FAIL: o_lock dropped during the period");
        end
    end
endtask
