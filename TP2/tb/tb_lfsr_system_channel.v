// =============================================================================
// Testbench : tb_lfsr_system_channel
// DUTs      : lfsr_generator + channel_delay + lfsr_checker
//
// Variante de tb_lfsr_system.v que inserta un modelo de canal (channel_delay)
// entre el generador y el checker, para simular latencia de transmisión
// (mayor o menor "distancia") entre ambos. gen_o_data/gen_o_valid entran al
// canal; el checker lee la salida retardada del canal (chan_o_data/
// chan_o_valid), no directamente al generador.
//
// Drenaje de send_valid/send_invalid:
//   Con canal, el último dato de una ráfaga tarda 1 ciclo (registro propio
//   del generador) + chan_delay ciclos (propagación por el canal) en llegar
//   al checker. El drenaje se generaliza a (chan_delay + 1) ciclos tras bajar
//   i_valid — con chan_delay=0 coincide exactamente con el "+1" original de
//   tb_lfsr_system.v.
// =============================================================================

`timescale 1ns / 1ps

module tb_lfsr_system_channel;

    // =========================================================================
    // Parámetros
    // =========================================================================
    localparam CLK_PERIOD       = 100;
    localparam DATA_WIDTH       = 16;
    localparam DEFAULT_SEED     = 16'hFFFF;
    localparam MAX_PERIOD       = (1 << DATA_WIDTH) - 1;   // 65 535
    localparam LOCK_THRESHOLD   = 5;
    localparam UNLOCK_THRESHOLD = 3;
    localparam MAX_DELAY        = 31;
    localparam DELAY_WIDTH      = 5;

    localparam RST_MIN_NS = 1_000;
    localparam RST_MAX_NS = 250_000;

    localparam CYCLES_TO_LOCK = 1 + LOCK_THRESHOLD;

    // =========================================================================
    // Señales
    // =========================================================================
    reg                    i_clk;

    // Generador
    reg                    gen_rst;
    reg                    gen_soft_rst;
    reg                    i_valid;
    reg  [DATA_WIDTH-1:0]  i_seed;
    wire [DATA_WIDTH-1:0]  gen_o_data;
    wire                   gen_o_valid;

    // Canal
    reg                    chan_rst;
    reg  [DELAY_WIDTH-1:0] chan_delay;
    wire [DATA_WIDTH-1:0]  chan_o_data;
    wire                   chan_o_valid;

    // Checker
    reg                    chk_rst;
    reg                    inject_error;
    wire                   o_lock;

    // Dato "enviado" al canal: correcto o corrompido segun inject_error
    // (misma logica de inyeccion que tb_lfsr_system.v, aplicada ANTES del
    // canal — el canal transporta fielmente lo que se le entrega, sea o no
    // el dato correcto)
    wire [DATA_WIDTH-1:0] tx_data = inject_error ? ~gen_o_data : gen_o_data;

    // =========================================================================
    // Instancias
    // =========================================================================
    lfsr_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .DEFAULT_SEED(DEFAULT_SEED)
    ) u_gen (
        .i_clk       (i_clk),
        .i_rst       (gen_rst),
        .i_soft_reset(gen_soft_rst),
        .i_valid     (i_valid),
        .i_seed      (i_seed),
        .o_data      (gen_o_data),
        .o_valid     (gen_o_valid)
    );

    channel_delay #(
        .DATA_WIDTH  (DATA_WIDTH),
        .MAX_DELAY   (MAX_DELAY),
        .DELAY_WIDTH (DELAY_WIDTH)
    ) u_chan (
        .i_clk   (i_clk),
        .i_rst   (chan_rst),
        .i_data  (tx_data),
        .i_valid (gen_o_valid),
        .i_delay (chan_delay),
        .o_data  (chan_o_data),
        .o_valid (chan_o_valid)
    );

    lfsr_checker #(
        .DATA_WIDTH       (DATA_WIDTH),
        .LOCK_THRESHOLD   (LOCK_THRESHOLD),
        .UNLOCK_THRESHOLD (UNLOCK_THRESHOLD)
    ) u_chk (
        .i_clk   (i_clk),
        .i_rst   (chk_rst),
        .i_valid (chan_o_valid),
        .i_data  (chan_o_data),
        .o_lock  (o_lock)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial i_clk = 1'b0;
    always  #(CLK_PERIOD / 2) i_clk = ~i_clk;

    // =========================================================================
    // Monitor de o_lock
    // =========================================================================
    reg prev_lock;
    initial prev_lock = 1'b0;

    always @(o_lock) begin
        $display("[LOCK MONITOR] t=%0t ns  |  o_lock: %0b -> %0b  (chan_delay=%0d)",
                 $time, prev_lock, o_lock, chan_delay);
        prev_lock = o_lock;
    end

    // =========================================================================
    // Tasks de reset
    // =========================================================================
    task reset_generator;
        integer rnd;
        begin
            rnd     = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS;
            gen_rst = 1'b1;
            #(rnd);
            @(negedge i_clk);
            gen_rst = 1'b0;
            @(posedge i_clk); #1;
        end
    endtask

    task reset_checker;
        integer rnd;
        begin
            rnd     = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS;
            chk_rst = 1'b1;
            #(rnd);
            @(negedge i_clk);
            chk_rst = 1'b0;
            @(posedge i_clk); #1;
        end
    endtask

    // =========================================================================
    // Task: set_channel_delay — cambia la latencia del canal de forma segura.
    //   Pulsa chan_rst junto con el cambio de chan_delay para que el canal
    //   arranque "vacío" en la nueva distancia (evita mezclar datos con
    //   distintos delays en tránsito — análogo a reconectar el cable).
    // =========================================================================
    task set_channel_delay;
        input [DELAY_WIDTH-1:0] new_delay;
        begin
            @(negedge i_clk);
            chan_rst   = 1'b1;
            chan_delay = new_delay;
            @(posedge i_clk); #1;
            @(negedge i_clk);
            chan_rst   = 1'b0;
            @(posedge i_clk); #1;
            $display("    [set_channel_delay] delay = %0d ciclos", new_delay);
        end
    endtask

    task randomize_channel_delay;
        reg [DELAY_WIDTH-1:0] d;
        begin
            d = $urandom_range(0, MAX_DELAY);
            set_channel_delay(d);
        end
    endtask

    // =========================================================================
    // Task: send_valid / send_invalid — igual que tb_lfsr_system.v, con el
    //   drenaje generalizado a (chan_delay + 1) ciclos (ver cabecera).
    // =========================================================================
    task send_valid;
        input integer n;
        begin
            inject_error = 1'b0;
            i_valid      = 1'b1;
            repeat (n) @(posedge i_clk);
            @(negedge i_clk);
            i_valid = 1'b0;
            repeat (chan_delay + 1) @(posedge i_clk);   // drenaje: generador + canal
            #1;
        end
    endtask

    task send_invalid;
        input integer n;
        begin
            inject_error = 1'b1;
            i_valid      = 1'b1;
            repeat (n) @(posedge i_clk);
            @(negedge i_clk);
            i_valid      = 1'b0;
            repeat (chan_delay + 1) @(posedge i_clk);   // drenaje: generador + canal
            inject_error = 1'b0;
            #1;
        end
    endtask

    task lock_checker;
        begin
            reset_checker();
            send_valid(CYCLES_TO_LOCK);
        end
    endtask

    // =========================================================================
    // Variables auxiliares
    // =========================================================================
    integer idx;
    integer fail_flag;

    // =========================================================================
    // Secuencia principal
    // =========================================================================
    initial begin

        gen_rst      = 1'b0;
        gen_soft_rst = 1'b0;
        chk_rst      = 1'b0;
        chan_rst     = 1'b0;
        chan_delay   = {DELAY_WIDTH{1'b0}};
        i_valid      = 1'b0;
        i_seed       = DEFAULT_SEED;
        inject_error = 1'b0;

        reset_generator();
        set_channel_delay(0);
        reset_checker();

        // =================================================================
        // TEST C0: Regresión — delay=0 debe comportarse igual que
        //   tb_lfsr_system.v sin canal
        // =================================================================
        $display("\n[TEST C0] delay=0 -- debe comportarse igual que sin canal");

        lock_checker();
        if (o_lock)
            $display("  PASS: lockeo con delay=0 (equivalente a conexion directa)");
        else
            $display("  FAIL: no lockeo con delay=0");

        // =================================================================
        // TEST C1: Lock a través de varias distancias fijas
        // =================================================================
        $display("\n[TEST C1] Lock con distintas latencias fijas de canal");

        fail_flag = 0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            reset_generator();
            set_channel_delay(idx * 4);   // 0, 4, 8, 12, 16
            lock_checker();
            if (o_lock)
                $display("  PASS [delay=%0d]: checker lockeo", idx*4);
            else begin
                $display("  FAIL [delay=%0d]: checker NO lockeo", idx*4);
                fail_flag = 1;
            end
        end
        if (!fail_flag)
            $display("  PASS: lockeo correctamente en todas las latencias probadas");

        // =================================================================
        // TEST C2: Tráfico válido continuo a través de un canal largo — no
        //   debe desbloquear en un período completo
        // =================================================================
        $display("\n[TEST C2] Trafico valido continuo con delay=%0d -- hold por %0d ciclos",
                  MAX_DELAY, MAX_PERIOD);

        reset_generator();
        set_channel_delay(MAX_DELAY);
        lock_checker();

        if (!o_lock) begin
            $display("  FAIL: no lockeo -- abortando C2");
        end else begin
            fail_flag    = 0;
            inject_error = 1'b0;
            i_valid      = 1'b1;
            repeat (MAX_PERIOD) begin
                @(posedge i_clk); #1;
                if (!o_lock) fail_flag = 1;
            end
            i_valid = 1'b0; // partio el ultimo dato del generador, ahora hay que drenar el canal
            repeat (chan_delay + 1) @(posedge i_clk);

            if (!fail_flag)
                $display("  PASS: o_lock se mantuvo HIGH durante todo el periodo con delay=%0d", MAX_DELAY);
            else
                $display("  FAIL: o_lock cayo durante el periodo");
        end

        // =================================================================
        // TEST C3: Fronteras de lock/unlock a través del canal — mismos
        //   patrones de tb_lfsr_system.v (TEST 2/3), con latencia fija
        // =================================================================
        $display("\n[TEST C3] Fronteras lock/unlock con delay=7");

        set_channel_delay(7);

        reset_generator();
        reset_checker();
        send_valid(1);       // resync
        send_valid(4);       // 4 aciertos
        send_invalid(1);     // rompe antes de llegar a 5
        if (!o_lock)
            $display("  PASS: 4 validos + 1 invalido -> nunca lockeo (con canal)");
        else
            $display("  FAIL: lockeo inesperadamente");

        reset_generator();
        lock_checker();
        if (!o_lock) begin
            $display("  FAIL: no se pudo lockear -- abortando C3b");
        end else begin
            fail_flag = 0;
            for (idx = 0; idx < 10; idx = idx + 1) begin
                send_invalid(2);
                send_valid(1);
                if (!o_lock) begin
                    $display("  FAIL: desbloqueo en iteracion %0d", idx);
                    fail_flag = 1;
                end
            end
            if (!fail_flag)
                $display("  PASS: o_lock permanecio HIGH durante 10 iteraciones (2inv+1val) con canal");
        end

        // =================================================================
        // TEST C4: Transición lock/unlock con distancia aleatoria entre
        //   ráfagas — el N cambia (con drenaje seguro) en cada iteración
        // =================================================================
        $display("\n[TEST C4] Transicion lock/unlock con delay aleatorio entre rafagas");

        fail_flag = 0;
        for (idx = 0; idx < 8; idx = idx + 1) begin
            reset_generator();
            reset_checker();
            randomize_channel_delay();

            send_valid(CYCLES_TO_LOCK);
            if (!o_lock) begin
                $display("  FAIL [iter %0d, delay=%0d]: no lockeo", idx, chan_delay);
                fail_flag = 1;
            end else
                $display("  [iter %0d] delay=%0d  LOCKED   OK", idx, chan_delay);

            send_invalid(UNLOCK_THRESHOLD);
            if (o_lock) begin
                $display("  FAIL [iter %0d, delay=%0d]: no desbloqueo", idx, chan_delay);
                fail_flag = 1;
            end else
                $display("  [iter %0d] delay=%0d  UNLOCKED OK", idx, chan_delay);
        end
        if (!fail_flag)
            $display("  PASS: todas las transiciones lock/unlock correctas con distancia aleatoria");

        // =================================================================
        $display("\n[DONE] Simulacion del sistema con canal completa.\n");
        $finish;
    end

endmodule
