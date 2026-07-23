// =============================================================================
// Module  : lfsr_generator
// Purpose : 16-bit Galois LFSR pseudo-random bit sequence generator.
//
// Reset behaviour
//   i_rst       (async, active-high) : loads DEFAULT_SEED immediately,
//                                      independent of the clock.
//   i_soft_reset (sync, active-high) : captures i_seed on the rising clock
//                                      edge.
//
// Shift control
//   i_valid : the register advances only when this signal is asserted.
//             When de-asserted the current state is held.
//
// o_valid
//   Registered, one-cycle companion of o_data: it must always travel
//   alongside the data it qualifies, so it is flopped through the exact
//   same priority chain as `lfsr` instead of being a bare echo of i_valid.
//   o_valid = 1 only on cycles where o_data is a genuine PRBS advance
//   (the i_valid branch actually won that cycle); it reads 0 after a
//   reset/seed load or a hold, since that data isn't a fresh sequence step.
// =============================================================================

`timescale 1ns / 1ps

module lfsr_generator #(
    parameter DATA_WIDTH   = 16,
    parameter DEFAULT_SEED = 16'hFFFF   // for i_rst
)(
    input                       i_clk,
    input                       i_rst,        // async reset  → DEFAULT_SEED
    input                       i_soft_reset, // sync  reset  → i_seed value
    input                       i_valid,      // shift enable
    input  [DATA_WIDTH-1:0]     i_seed,       // runtime-configurable seed
    output [DATA_WIDTH-1:0]     o_data,
    output reg                  o_valid       // registered companion of o_data
);

    reg [DATA_WIDTH-1:0] lfsr;

    // -------------------------------------------------------------------------
    // Combinational next-state (Galois topology):
    // -------------------------------------------------------------------------
    wire feedback = lfsr[DATA_WIDTH-1]; //msb

    wire [DATA_WIDTH-1:0] lfsr_next;

    assign lfsr_next[0]  = feedback;
    assign lfsr_next[1]  = lfsr[0];
    assign lfsr_next[2]  = lfsr[1];
    assign lfsr_next[3]  = lfsr[2];
    assign lfsr_next[4]  = lfsr[3];
    assign lfsr_next[5]  = lfsr[4];
    assign lfsr_next[6]  = lfsr[5];
    assign lfsr_next[7]  = lfsr[6];
    assign lfsr_next[8]  = lfsr[7];
    assign lfsr_next[9]  = lfsr[8];
    assign lfsr_next[10] = lfsr[9];
    assign lfsr_next[11] = lfsr[10] ^ feedback;   // tap
    assign lfsr_next[12] = lfsr[11];
    assign lfsr_next[13] = lfsr[12] ^ feedback;   // tap
    assign lfsr_next[14] = lfsr[13] ^ feedback;   // tap
    assign lfsr_next[15] = lfsr[14];

    // -------------------------------------------------------------------------
    // Sequential logic — priority: i_rst > i_soft_reset > i_valid
    // o_valid mirrors, edge for edge, whether THIS update is the i_valid
    // branch (a real advance) so it stays truthfully paired with o_data.
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            lfsr    <= DEFAULT_SEED;
            o_valid <= 1'b0;
        end else if (i_soft_reset) begin
            lfsr    <= i_seed;      // load runtime seed synchronously
            o_valid <= 1'b0;        // reseed, not a PRBS advance
        end else if (i_valid) begin
            lfsr    <= lfsr_next;   // advance sequence
            o_valid <= 1'b1;
        end else begin
            o_valid <= 1'b0;        // hold — no valid token, no reset
        end
    end

    assign o_data = lfsr;

endmodule
