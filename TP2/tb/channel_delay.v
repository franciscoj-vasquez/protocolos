// =============================================================================
// Module  : channel_delay
// Purpose : Modelo de canal de comunicación para testbench — línea de retardo
//           de N ciclos entre el generador y el checker, para simular
//           distintas latencias de transmisión.
//
// Cómo funciona:
//   Es un shift register de MAX_DELAY etapas que siempre desplaza, ciclo a
//   ciclo. Data y valid se desplazan siempre juntos, etapa por etapa, 
//  así que nunca se desfasan entre sí.
//
// Ports:
//   i_clk, i_rst   : reset asíncrono, limpia todas las etapas
//   i_data/i_valid : entrada (lado generador)
//   i_delay        : latencia vigente, en ciclos (0..MAX_DELAY)
//   o_data/o_valid : salida retardada i_delay ciclos (lado checker)
// =============================================================================

`timescale 1ns / 1ps

module channel_delay #(
    parameter DATA_WIDTH  = 16,
    parameter MAX_DELAY   = 31,   // maximo N soportado (ciclos) -- 2^DELAY_WIDTH-1
    parameter DELAY_WIDTH = 5
)(
    input                          i_clk,
    input                          i_rst,
    input      [DATA_WIDTH-1:0]    i_data,
    input                          i_valid,
    input      [DELAY_WIDTH-1:0]   i_delay,
    output     [DATA_WIDTH-1:0]    o_data,
    output                         o_valid
);

    // etapa[k] = (i_data,i_valid) con k ciclos de retardo. etapa 0 no se
    // registra: es un passthrough combinacional (delay=0 == conexión directa,
    // igual que tb_lfsr_system.v sin canal).
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
            data_stage[1]  <= i_data;
            valid_stage[1] <= i_valid;
            for (k = 2; k <= MAX_DELAY; k = k + 1) begin
                data_stage[k]  <= data_stage[k-1];
                valid_stage[k] <= valid_stage[k-1];
            end
        end
    end

    assign o_data  = (i_delay == 0) ? i_data  : data_stage[i_delay];
    assign o_valid = (i_delay == 0) ? i_valid : valid_stage[i_delay];

endmodule
