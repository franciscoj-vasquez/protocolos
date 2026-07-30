// =============================================================================
// Module  : lfsr_generator  (variante FSM style)
// Purpose : Misma funcionalidad que rtl/lfsr_generator.v (16-bit Galois LFSR),
//           reescrita con el patrón de dos always separados: uno combinacional
//           (always @*) para la lógica de próximo estado, con case en vez de
//           if/else if, y otro secuencial (always @(posedge clk)) que solo
//           registra lo que decidió el combinacional.
//
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
    // Próximo valor del LFSR si i_valid gana este ciclo (topología Galois,
    // idéntica a la versión original)
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
    // Combinacional: decide next_lfsr / next_o_valid.
    // Selector = señales de control (i_soft_reset, i_valid).
    // -------------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] next_lfsr;
    reg                  next_o_valid;

    wire [1:0] ctrl_sel = {i_soft_reset, i_valid};

    always @(*) begin
        // Defaults: hold (cubre {i_soft_reset,i_valid} == 2'b00 y previene
        // patron default first
        next_lfsr    = lfsr;
        next_o_valid = 1'b0;

        case (ctrl_sel)
            2'b10, 2'b11: begin   // i_soft_reset=1 (gana sin importar i_valid)
                next_lfsr    = i_seed;
                next_o_valid = 1'b0;   // reseed, no es avance PRBS
            end
            2'b01: begin           // solo i_valid
                next_lfsr    = lfsr_next;
                next_o_valid = 1'b1;
            end
            default: ;              // 2'b00 → se queda con el hold de arriba
        endcase
    end

    // -------------------------------------------------------------------------
    // Secuencial: i_rst se resuelve primero (async, fuera del combinacional);
    // si no hay reset, registra lo que decidió el combinacional.
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            lfsr    <= DEFAULT_SEED;
            o_valid <= 1'b0;
        end else begin
            lfsr    <= next_lfsr;
            o_valid <= next_o_valid;
        end
    end

    assign o_data = lfsr;

endmodule
