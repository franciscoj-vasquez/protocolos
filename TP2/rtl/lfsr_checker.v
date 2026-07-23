// =============================================================================
// Module  : lfsr_checker
//
// Funcionamiento:
//   1. UNLOCKED : compara cada dato con el valor predicho (lfsr_ref_next).
//                 Acierto  → acumula valid_cnt; lock al alcanzar LOCK_THRESHOLD.
//                 Error    → no hay estado especial para esto: simplemente no
//                             hay (todavía) con qué comparar, así que i_data se
//                             toma como nueva referencia y valid_cnt se reinicia.
//                             Esto cubre tanto la falta de sincronización
//                             inicial como cualquier desincronización futura,
//                             sin gastar un estado ni un ciclo aparte.
//   2. LOCKED   : acumula errores consecutivos → unlock al alcanzar
//                 UNLOCK_THRESHOLD. Un acierto resetea el contador de errores.
//                 Al desbloquear, lfsr_ref se fuerza al centinela 0 (ver abajo)
//                 en vez de seguir prediciendo, para no arrastrar una
//                 referencia contaminada por los datos inválidos recién vistos.
//
// Centinela lfsr_ref = 0: la secuencia PRBS nunca pasa por el estado 0 (no es
// parte del ciclo maximal de 2^16-1 estados no nulos), así que es un valor
// "imposible de acertar por casualidad". Se usa en el reset y tras cada
// desbloqueo para garantizar que la primera comparación posterior SIEMPRE
// falla a propósito y dispara la resincronización de UNLOCKED, en vez de
// arriesgarse a que coincida por casualidad con el dato real (p. ej. si se
// hubiera sembrado con DEFAULT_SEED, que es justo el valor con el que suele
// arrancar el generador).
//
// Invariante: lfsr_ref está siempre un paso por detrás del generador, de modo
//             que lfsr_ref_next = valor esperado en el próximo ciclo i_valid.
//
// Ports:
//   i_clk   : clock del sistema
//   i_rst   : reset asíncrono (activo alto) → vuelve a UNLOCKED
//   i_valid : habilita la evaluación (debe coincidir con el del generador)
//   i_data  : salida del generador LFSR
//   o_lock  : HIGH cuando el checker está bloqueado (secuencia verificada)
// =============================================================================

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

    // Próximo valor esperado (combinacional)
    wire [DATA_WIDTH-1:0] lfsr_ref_next = lfsr_step(lfsr_ref);

    // -------------------------------------------------------------------------
    // Máquina de estados secuencial
    // -------------------------------------------------------------------------
    always @(posedge i_clk or posedge i_rst) begin
        if (i_rst) begin
            state       <= ST_UNLOCKED;
            lfsr_ref    <= {DATA_WIDTH{1'b0}};   // la primer comparacion se errara
            valid_cnt   <= 4'd0;
            invalid_cnt <= 4'd0;
            o_lock      <= 1'b0;

        end else if (i_valid) begin
            if (state == ST_UNLOCKED) begin
                // ---------------------------------------------------------------
                // UNLOCKED: compara i_data con el próximo valor predicho.
                //   Acierto → acumula valid_cnt; lock al alcanzar LOCK_THRESHOLD.
                //   Error   → no hay con qué comparar todavía (o se perdió la
                //             sincronía): se toma i_data como nueva referencia
                //             y se reinicia valid_cnt. Sin esto no hace falta
                //             un estado ACQUIRE separado.
                // ---------------------------------------------------------------
                if (i_data == lfsr_ref_next) begin
                    lfsr_ref <= i_data;
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
                // LOCKED: compara i_data con el próximo valor predicho.
                //   Acierto → resetea invalid_cnt (buena secuencia continúa).
                //   Error   → acumula invalid_cnt hasta desbloquear; al
                //             desbloquear, lfsr_ref vuelve al centinela en vez
                //             de seguir prediciendo, para no arrastrar una
                //             referencia contaminada por los últimos datos
                //             inválidos vistos.
                // ---------------------------------------------------------------
                if (i_data == lfsr_ref_next) begin
                    lfsr_ref    <= i_data;
                    invalid_cnt <= 4'd0;
                end else if (invalid_cnt == UNLOCK_THRESHOLD - 1) begin
                    o_lock      <= 1'b0;
                    invalid_cnt <= 4'd0;
                    state       <= ST_UNLOCKED;
                    lfsr_ref    <= {DATA_WIDTH{1'b0}};   // centinela, igual que en el reset
                end else begin
                    lfsr_ref    <= lfsr_ref_next;        // sigue prediciendo pese al error transitorio
                    invalid_cnt <= invalid_cnt + 4'd1;
                end
            end
        end
    end

endmodule
