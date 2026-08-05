// =============================================================================
// Module  : channel_delay
// Purpose : Communication channel model for the testbench — an N-cycle delay
//           line between the generator and the checker, used to simulate
//           different transmission latencies.
//
// How it works:
//   It is a shift register with MAX_DELAY stages that always shifts, cycle
//   by cycle. Data and valid always shift together, stage by stage, so they
//   can never drift out of phase with each other. The injected error port
//   allows for the simulation of transmission errors by flipping a random bit
//   of the input data.
//
// Ports:
//   i_clk, i_rst    : asynchronous reset, clears every stage
//   i_data/i_valid  : input (generator side)
//   i_inject_error  : flips a random bit of i_data at the pipeline input
//                     (see above)
//   i_delay         : latency in effect, in cycles (0..MAX_DELAY)
//   o_data/o_valid  : output delayed by i_delay cycles (checker side)
// =============================================================================

`timescale 1ns / 1ps

module channel_delay #(
    parameter DATA_WIDTH  = 16,
    parameter MAX_DELAY   = 31,   // max N supported (cycles) -- 2^DELAY_WIDTH-1
    parameter DELAY_WIDTH = 5
)(
    input                          i_clk,
    input                          i_rst,
    input      [DATA_WIDTH-1:0]    i_data,
    input                          i_valid,
    input                          i_inject_error,
    input      [DELAY_WIDTH-1:0]   i_delay,
    output     [DATA_WIDTH-1:0]    o_data,
    output                         o_valid
);

    // Bit to flip when i_inject_error=1 — redrawn every cycle, enabled or
    // not, so it's already "fresh" by the time it's needed.
    integer err_bit;
    initial err_bit = 0;
    always @(posedge i_clk)
        err_bit <= $urandom_range(0, DATA_WIDTH - 1);

    // Corruption: copies i_data and, if applicable, flips only bit err_bit.
    reg [DATA_WIDTH-1:0] tx_data;
    always @(*) begin
        tx_data = i_data;
        if (i_inject_error)
            tx_data[err_bit] = ~tx_data[err_bit];
    end

    // stage[k] = (tx_data,i_valid) delayed by k cycles. Stage 0 is not
    // registered: it's a combinational passthrough (delay=0 == direct
    // connection between generator and checker, no added latency).
    reg [DATA_WIDTH-1:0] data_stage  [1:MAX_DELAY];
    reg                  valid_stage [1:MAX_DELAY];

    integer k;
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            for (k = 1; k <= MAX_DELAY; k = k + 1) begin
                data_stage[k]  <= {DATA_WIDTH{1'b0}};
                valid_stage[k] <= 1'b0;
            end
        end else begin
            data_stage[1]  <= tx_data;
            valid_stage[1] <= i_valid;
            for (k = 2; k <= MAX_DELAY; k = k + 1) begin
                data_stage[k]  <= data_stage[k-1];
                valid_stage[k] <= valid_stage[k-1];
            end
        end
    end

    assign o_data  = (i_delay == 0) ? tx_data : data_stage[i_delay];
    assign o_valid = (i_delay == 0) ? i_valid : valid_stage[i_delay];

endmodule
