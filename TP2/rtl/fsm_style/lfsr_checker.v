// =============================================================================
// Module  : lfsr_checker  ("FSM style" variant)
//
// Same functionality as ../lfsr_checker.v, rewritten with the two-always
// pattern: combinational (always @*, case on `state`) decides
// next_state/next_lfsr_ref/next_valid_cnt/next_invalid_cnt/next_o_lock, and
// sequential (always @(posedge i_clk or posedge i_rst)) only registers
// those next_* signals. See ../lfsr_checker.v for the original version
// (verified reference) — this one is functionally identical, recompiled
// against tb_lfsr_system_channel.v without modifying it, same result.
//
// Behavior (identical to the original):
//   1. UNLOCKED : compares each data sample against the predicted value
//                 (lfsr_ref_next).
//                 Match    → accumulates valid_cnt; locks once
//                             LOCK_THRESHOLD is reached.
//                 Mismatch → i_data becomes the new reference and
//                             valid_cnt resets (covers both initial resync
//                             and any later loss of sync, without a
//                             separate state or cycle).
//   2. LOCKED   : accumulates consecutive errors → unlocks once
//                 UNLOCK_THRESHOLD is reached. A match resets the error
//                 counter. On unlock, lfsr_ref falls back to sentinel 0.
//
// Ports:
//   i_clk   : system clock
//   i_rst   : asynchronous reset (active-high) → returns to UNLOCKED
//   i_valid : enables evaluation (must match the generator's)
//   i_data  : output from the LFSR generator
//   o_lock  : HIGH when the checker is locked (sequence verified)
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

    // Next expected value (combinational), derived from the current reference
    wire [DATA_WIDTH-1:0] lfsr_ref_next = lfsr_step(lfsr_ref);

    // -------------------------------------------------------------------------
    // Combinational: case on the current state decides the next_* signals.
    // -------------------------------------------------------------------------
    reg                  next_state;
    reg [DATA_WIDTH-1:0] next_lfsr_ref;
    reg [3:0]            next_valid_cnt;
    reg [3:0]            next_invalid_cnt;
    reg                  next_o_lock;

    always @(*) begin
        // Defaults: hold (covers i_valid=0 and prevents latches — all 5
        // signals are assigned on every path through the block).
        next_state       = state;
        next_lfsr_ref    = lfsr_ref;
        next_valid_cnt   = valid_cnt;
        next_invalid_cnt = invalid_cnt;
        next_o_lock      = o_lock;

        case (state)
            // ---------------------------------------------------------------
            // UNLOCKED: compares i_data against the next predicted value.
            //   Match    → accumulates valid_cnt; locks once LOCK_THRESHOLD
            //              is reached.
            //   Mismatch → i_data becomes the new reference and valid_cnt
            //              resets.
            // ---------------------------------------------------------------
            ST_UNLOCKED: begin
                if (i_valid) begin
                    if (i_data == lfsr_ref_next) begin
                        next_lfsr_ref = lfsr_ref_next;
                        if (valid_cnt == LOCK_THRESHOLD - 1) begin
                            next_o_lock    = 1'b1;
                            next_valid_cnt = 4'd0;
                            next_state     = ST_LOCKED;
                        end else begin
                            next_valid_cnt = valid_cnt + 4'd1;
                        end
                    end else begin
                        next_lfsr_ref  = i_data;
                        next_valid_cnt = 4'd0;
                    end
                end
            end

            // ---------------------------------------------------------------
            // LOCKED: compares i_data against the next predicted value.
            //   Match    → resets invalid_cnt (good sequence continues).
            //   Mismatch → accumulates invalid_cnt until unlock; on unlock,
            //              lfsr_ref falls back to the sentinel.
            // ---------------------------------------------------------------
            ST_LOCKED: begin
                if (i_valid) begin
                    if (i_data == lfsr_ref_next) begin
                        next_lfsr_ref    = lfsr_ref_next;
                        next_invalid_cnt = 4'd0;
                    end else if (invalid_cnt == UNLOCK_THRESHOLD - 1) begin
                        next_o_lock      = 1'b0;
                        next_invalid_cnt = 4'd0;
                        next_state       = ST_UNLOCKED;
                        next_lfsr_ref    = {DATA_WIDTH{1'b0}};   // sentinel
                    end else begin
                        next_lfsr_ref    = lfsr_ref_next;        // keeps predicting
                        next_invalid_cnt = invalid_cnt + 4'd1;
                    end
                end
            end

            default: begin
                // Unreachable with a 1-bit state — present only so that no
                // path through the case is left uncovered (same anti-latch
                // discipline as the other two).
                next_state = ST_UNLOCKED;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Sequential: i_rst is resolved first (async, outside the combinational
    // block); absent a reset, it registers whatever the combinational block
    // decided.
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state       <= ST_UNLOCKED;
            lfsr_ref    <= {DATA_WIDTH{1'b0}};   // the first comparison will (intentionally) miss
            valid_cnt   <= 4'd0;
            invalid_cnt <= 4'd0;
            o_lock      <= 1'b0;
        end else begin
            state       <= next_state;
            lfsr_ref    <= next_lfsr_ref;
            valid_cnt   <= next_valid_cnt;
            invalid_cnt <= next_invalid_cnt;
            o_lock      <= next_o_lock;
        end
    end

endmodule
