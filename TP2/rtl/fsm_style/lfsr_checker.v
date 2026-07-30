// =============================================================================
// Module  : lfsr_checker  (variante "FSM style")
//
// Misma funcionalidad que ../lfsr_checker.v, reescrita con el patrón de dos
// always: combinacional (always @*, case sobre `state`) para decidir
// next_state/next_lfsr_ref/next_valid_cnt/next_invalid_cnt/next_o_lock, y
// secuencial (always @(posedge i_clk or posedge i_rst)) que solo registra
// esas señales next_*. Ver ../lfsr_checker.v para la versión original
// (referencia verificada) — esta es funcionalmente idéntica, recompilada
// contra tb_lfsr_system.v sin modificarlo, mismo resultado.
//
// Funcionamiento (idéntico al original):
//   1. UNLOCKED : compara cada dato con el valor predicho (lfsr_ref_next).
//                 Acierto  → acumula valid_cnt; lock al alcanzar LOCK_THRESHOLD.
//                 Error    → i_data pasa a ser la nueva referencia y valid_cnt
//                             se reinicia (cubre resync inicial y pérdida de
//                             sincronía, sin estado ni ciclo aparte).
//   2. LOCKED   : acumula errores consecutivos → unlock al alcanzar
//                 UNLOCK_THRESHOLD. Un acierto resetea el contador de errores.
//                 Al desbloquear, lfsr_ref vuelve al centinela 0.
//
// Ports:
//   i_clk   : clock del sistema
//   i_rst   : reset asíncrono (activo alto) → vuelve a UNLOCKED
//   i_valid : habilita la evaluación (debe coincidir con el del generador)
//   i_data  : salida del generador LFSR
//   o_lock  : HIGH cuando el checker está bloqueado (secuencia verificada)
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
    // Estados internos
    // -------------------------------------------------------------------------
    localparam ST_UNLOCKED = 1'b0;
    localparam ST_LOCKED   = 1'b1;

    reg                  state;
    reg [DATA_WIDTH-1:0] lfsr_ref;       // referencia interna (un paso atrás)
    reg [3:0]            valid_cnt;      // aciertos consecutivos
    reg [3:0]            invalid_cnt;    // errores consecutivos

    // -------------------------------------------------------------------------
    // Función de paso del LFSR — misma topología y polinomio que el generador
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

    // Próximo valor esperado (combinacional), a partir de la referencia actual
    wire [DATA_WIDTH-1:0] lfsr_ref_next = lfsr_step(lfsr_ref);

    // -------------------------------------------------------------------------
    // Combinacional: case sobre el estado actual decide los next_*.
    // -------------------------------------------------------------------------
    reg                  next_state;
    reg [DATA_WIDTH-1:0] next_lfsr_ref;
    reg [3:0]            next_valid_cnt;
    reg [3:0]            next_invalid_cnt;
    reg                  next_o_lock;

    always @(*) begin
        // Defaults: hold (cubre i_valid=0 y previene latches — las 5 señales
        // quedan asignadas en todo camino del bloque).
        next_state       = state;
        next_lfsr_ref    = lfsr_ref;
        next_valid_cnt   = valid_cnt;
        next_invalid_cnt = invalid_cnt;
        next_o_lock      = o_lock;

        case (state)
            // ---------------------------------------------------------------
            // UNLOCKED: compara i_data con el próximo valor predicho.
            //   Acierto → acumula valid_cnt; lock al alcanzar LOCK_THRESHOLD.
            //   Error   → i_data pasa a ser la nueva referencia y se reinicia
            //             valid_cnt.
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
            // LOCKED: compara i_data con el próximo valor predicho.
            //   Acierto → resetea invalid_cnt (buena secuencia continúa).
            //   Error   → acumula invalid_cnt hasta desbloquear; al
            //             desbloquear, lfsr_ref vuelve al centinela.
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
                        next_lfsr_ref    = {DATA_WIDTH{1'b0}};   // centinela
                    end else begin
                        next_lfsr_ref    = lfsr_ref_next;        // sigue prediciendo
                        next_invalid_cnt = invalid_cnt + 4'd1;
                    end
                end
            end

            default: begin
                // Inalcanzable con state de 1 bit — presente solo para que
                // ningún path del case quede sin cubrir (misma disciplina
                // anti-latch que en los otros dos).
                next_state = ST_UNLOCKED;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // Secuencial: i_rst se resuelve primero (async, fuera del combinacional);
    // si no hay reset, registra lo que decidió el combinacional.
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state       <= ST_UNLOCKED;
            lfsr_ref    <= {DATA_WIDTH{1'b0}};   // la primer comparacion se errara
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
