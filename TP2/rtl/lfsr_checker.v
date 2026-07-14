// =============================================================================
// Module  : lfsr_checker
// Purpose : Verifica en tiempo real que la salida del generador LFSR
//           corresponde a la secuencia PRBS esperada.
//
// Funcionamiento:
//   1. ACQUIRE  : captura el estado actual del generador para sincronizar la
//                 referencia interna. No cuenta errores ni aciertos.
//   2. UNLOCKED : compara cada nuevo dato con el valor predicho; acumula
//                 aciertos consecutivos → lock al alcanzar LOCK_THRESHOLD.
//   3. LOCKED   : acumula errores consecutivos → unlock al alcanzar
//                 UNLOCK_THRESHOLD. Un acierto resetea el contador de errores.
//
// Invariante: lfsr_ref está siempre un paso por detrás del generador, de modo
//             que lfsr_ref_next = valor esperado en el próximo ciclo i_valid.
//
// Ports:
//   i_clk   : clock del sistema
//   i_rst   : reset asíncrono (activo alto) → vuelve a ACQUIRE
//   i_valid : habilita la evaluación (debe coincidir con el del generador)
//   i_data  : salida del generador LFSR
//   o_lock  : HIGH cuando el checker está bloqueado (secuencia verificada)
// =============================================================================

module lfsr_checker #(
    parameter DATA_WIDTH       = 16,
    parameter LOCK_THRESHOLD   = 5,    // aciertos consecutivos para lockear
    parameter UNLOCK_THRESHOLD = 3     // errores consecutivos para deslockear
)(
    input                    i_clk,
    input                    i_rst,
    input                    i_valid,
    input  [DATA_WIDTH-1:0]  i_data,
    output reg               o_lock
);

    // -------------------------------------------------------------------------
    // Estados internos
    // -------------------------------------------------------------------------
    localparam ST_ACQUIRE  = 2'd0;   // sincronizando referencia
    localparam ST_UNLOCKED = 2'd1;   // contando aciertos hacia el lock
    localparam ST_LOCKED   = 2'd2;   // verificando, contando errores hacia unlock

    reg [1:0]            state;
    reg [DATA_WIDTH-1:0] lfsr_ref;       // referencia interna (un paso atrás)
    reg [3:0]            valid_cnt;      // aciertos consecutivos
    reg [3:0]            invalid_cnt;    // errores consecutivos

    // -------------------------------------------------------------------------
    // Función de paso del LFSR — misma topología y polinomio que el generador
    //   x^16 + x^14 + x^13 + x^11 + 1  (Galois, taps en bits 11, 13, 14)
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

    // Próximo valor esperado (combinacional)
    wire [DATA_WIDTH-1:0] lfsr_ref_next = lfsr_step(lfsr_ref);

    // -------------------------------------------------------------------------
    // Máquina de estados secuencial
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state       <= ST_ACQUIRE;
            lfsr_ref    <= {DATA_WIDTH{1'b0}};
            valid_cnt   <= 4'd0;
            invalid_cnt <= 4'd0;
            o_lock      <= 1'b0;

        end else if (i_valid) begin
            case (state)

                // -------------------------------------------------------------
                // ACQUIRE: seedea la referencia con el estado actual del
                // generador y pasa a verificar desde el próximo ciclo.
                // -------------------------------------------------------------
                ST_ACQUIRE: begin
                    lfsr_ref    <= i_data;
                    valid_cnt   <= 4'd0;
                    invalid_cnt <= 4'd0;
                    state       <= ST_UNLOCKED;
                end

                // -------------------------------------------------------------
                // UNLOCKED: compara i_data con el próximo valor predicho.
                //   Acierto → acumula valid_cnt.
                //   Error   → vuelve a ACQUIRE (re-sincronización necesaria).
                // -------------------------------------------------------------
                ST_UNLOCKED: begin
                    lfsr_ref <= lfsr_ref_next;   // siempre avanza en paralelo al generador

                    if (i_data == lfsr_ref_next) begin
                        if (valid_cnt == LOCK_THRESHOLD - 1) begin
                            o_lock    <= 1'b1;
                            valid_cnt <= 4'd0;
                            state     <= ST_LOCKED;
                        end else
                            valid_cnt <= valid_cnt + 4'd1;
                    end else begin
                        valid_cnt <= 4'd0;
                        state     <= ST_ACQUIRE;
                    end
                end

                // -------------------------------------------------------------
                // LOCKED: compara i_data con el próximo valor predicho.
                //   Acierto → resetea invalid_cnt (buena secuencia continúa).
                //   Error   → acumula invalid_cnt hasta desbloquear.
                // -------------------------------------------------------------
                ST_LOCKED: begin
                    lfsr_ref <= lfsr_ref_next;

                    if (i_data == lfsr_ref_next) begin
                        invalid_cnt <= 4'd0;
                    end else begin
                        if (invalid_cnt == UNLOCK_THRESHOLD - 1) begin
                            o_lock      <= 1'b0;
                            invalid_cnt <= 4'd0;
                            state       <= ST_ACQUIRE;
                        end else
                            invalid_cnt <= invalid_cnt + 4'd1;
                    end
                end

                default: state <= ST_ACQUIRE;

            endcase
        end
    end

endmodule
