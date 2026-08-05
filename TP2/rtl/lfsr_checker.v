// =============================================================================
// Module  : lfsr_checker
//
// Behavior:
//   1. UNLOCKED : compares each data word against the predicted value
//                 (lfsr_ref_next).
//                 Match    →  accumulates valid_cnt; locks at LOCK_THRESHOLD.
//                 Mismatch →  i_data is taken as the new reference and
//                             valid_cnt is reset.
//   2. LOCKED   : accumulates consecutive errors → unlocks at
//                 UNLOCK_THRESHOLD. A match resets the error counter.
//                 On a transient error, lfsr_ref keeps predicting the next
//                 value from the internal reference (lfsr_ref) so the
//                 sequence isn't lost, but once UNLOCK_THRESHOLD errors
//                 accumulate and it unlocks, lfsr_ref is forced back to the
//                 sentinel value 0 (see below) instead of continuing to
//                 predict, so it doesn't carry forward a reference
//                 contaminated by the invalid data just seen.
// =============================================================================

`timescale 1ns / 1ps

module lfsr_checker #(
    parameter DATA_WIDTH       = 16,
    parameter LOCK_THRESHOLD   = 5,
    parameter UNLOCK_THRESHOLD = 3
)(
    input                    i_clk,
    input                    i_rst,
    input                    i_valid,
    input  [DATA_WIDTH-1:0]  i_data,
    output reg               o_lock
);

    // -------------------------------------------------------------------------
    // Internal states
    // -------------------------------------------------------------------------
    localparam ST_UNLOCKED = 1'b0;
    localparam ST_LOCKED   = 1'b1;

    reg                  state;
    reg [DATA_WIDTH-1:0] lfsr_ref;       // internal reference (one step behind)
    reg [3:0]            valid_cnt;      // consecutive matches
    reg [3:0]            invalid_cnt;    // consecutive errors

    // -------------------------------------------------------------------------
    // LFSR step function — same topology and polynomial as the generator
    // -------------------------------------------------------------------------
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

    // Next expected value (combinational)
    wire [DATA_WIDTH-1:0] lfsr_ref_next = lfsr_step(lfsr_ref);

    // -------------------------------------------------------------------------
    // Sequential state machine
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state       <= ST_UNLOCKED;
            lfsr_ref    <= {DATA_WIDTH{1'b0}};   // forces the first comparison to fail
            valid_cnt   <= 4'd0;
            invalid_cnt <= 4'd0;
            o_lock      <= 1'b0;

        end else if (i_valid) begin
            if (state == ST_UNLOCKED) begin
                // ---------------------------------------------------------------
                // UNLOCKED: compares i_data against the predicted next value.
                //   Match    → accumulates valid_cnt; locks at LOCK_THRESHOLD.
                //   Mismatch → i_data is taken as the new reference and
                //              valid_cnt is reset.
                // ---------------------------------------------------------------
                if (i_data == lfsr_ref_next) begin
                    lfsr_ref <= lfsr_ref_next; // equivalently lfsr_ref <= i_data
                    if (valid_cnt == LOCK_THRESHOLD - 1) begin
                        o_lock    <= 1'b1;
                        valid_cnt <= 4'd0;
                        state     <= ST_LOCKED;
                    end else
                        valid_cnt <= valid_cnt + 4'd1;
                end else begin
                    lfsr_ref  <= i_data;
                    valid_cnt <= 4'd0;
                end

            end else begin // ST_LOCKED
                // ---------------------------------------------------------------
                // LOCKED: compares i_data against the predicted next value.
                //   Match    → resets invalid_cnt.
                //   Mismatch → accumulates invalid_cnt until it unlocks; upon
                //              unlocking, lfsr_ref goes back to the sentinel.
                // ---------------------------------------------------------------
                if (i_data == lfsr_ref_next) begin
                    lfsr_ref    <= lfsr_ref_next; // equivalently lfsr_ref <= i_data
                    invalid_cnt <= 4'd0;
                end else if (invalid_cnt == UNLOCK_THRESHOLD - 1) begin
                    o_lock      <= 1'b0;
                    invalid_cnt <= 4'd0;
                    state       <= ST_UNLOCKED;
                    lfsr_ref    <= {DATA_WIDTH{1'b0}};   // sentinel, same as on reset
                end else begin
                    lfsr_ref    <= lfsr_ref_next;        // keeps predicting despite the transient error
                    invalid_cnt <= invalid_cnt + 4'd1;
                end
            end
        end
    end

endmodule
