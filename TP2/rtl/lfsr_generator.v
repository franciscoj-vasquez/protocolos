// =============================================================================
// Module  : lfsr_generator
// Purpose : 16-bit Galois LFSR pseudo-random bit sequence generator.
//
// Polynomial : x^16 + x^14 + x^13 + x^11 + 1
// Taps (0-idx): bits 11, 13, 14  →  max period = 2^16 - 1 = 65 535 states
//
// Reset behaviour
//   i_rst       (async, active-high) : loads DEFAULT_SEED immediately,
//                                      independent of the clock.
//   i_soft_reset (sync, active-high) : captures i_seed on the rising clock
//                                      edge (seed is programmable at runtime).
//
// Shift control
//   i_valid : the register advances only when this signal is asserted.
//             When de-asserted the current state is held.
// =============================================================================

module lfsr_generator #(
    parameter DATA_WIDTH   = 16,
    parameter DEFAULT_SEED = 16'hFFFF   // hard-wired seed for i_rst
)(
    input                       i_clk,
    input                       i_rst,        // async reset  → DEFAULT_SEED
    input                       i_soft_reset, // sync  reset  → i_seed value
    input                       i_valid,      // shift enable
    input  [DATA_WIDTH-1:0]     i_seed,       // runtime-configurable seed
    output [DATA_WIDTH-1:0]     o_data
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
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst)
            lfsr <= DEFAULT_SEED;
        else if (i_soft_reset)
            lfsr <= i_seed;         // load runtime seed synchronously
        else if (i_valid)
            lfsr <= lfsr_next;      // advance sequence
        // else: hold — no valid token, no reset
    end

    assign o_data = lfsr;

endmodule
