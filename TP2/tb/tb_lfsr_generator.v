// =============================================================================
// Testbench : tb_lfsr_generator
// DUT       : lfsr_generator
//
// Actividad 2 — infraestructura:
//   · Clock 10 MHz (periodo = 100 ns)
//   · task_set_seed       : cambia i_seed en runtime
//   · task_async_reset    : activa i_rst por tiempo random en [1us, 250us]
//   · task_soft_reset     : activa i_soft_reset por tiempo random en [1us, 250us]
//   · valid aleatorio     : proceso que randomiza rand_valid en cada ciclo;
//                           i_valid es un wire que selecciona entre forced_valid
//
//
// o_valid — señal que debe viajar siempre junto a o_data (registrada, no un
//   simple alias combinacional de i_valid): el DUT la expone como salida y
//   este testbench la verifica en TEST 0a/0b/0c (debe bajar tras cualquier
//   carga de seed, incluso si i_valid estaba asertado a la vez), TEST 3
//   (gating) y TEST 4 (comparación ciclo a ciclo contra el i_valid muestreado).
//
// Actividad 3 — tests:
//   · TEST 0a: i_rst       → o_data == DEFAULT_SEED, o_valid == 0
//   · TEST 0b: i_soft_reset → o_data == i_seed, o_valid == 0
//   · TEST 0c: prioridad   → i_soft_reset gana sobre i_valid simultáneo;
//              o_valid == 0 porque no hubo avance real de la secuencia
//   · TEST 1 : periodicidad con DEFAULT_SEED (esperado: 65 535)
//   · TEST 2 : periodicidad con 5 seeds random distintas
//   · TEST 3 : valid gating — output no debe avanzar sin i_valid; o_valid
//              debe permanecer en 0
//   · TEST 4 : valid aleatorio — o_data vs. modelo de referencia bajo i_valid
//              intermitente (ejercita rand_valid/rand_valid_en de Actividad 2)
//              y o_valid vs. el i_valid muestreado un ciclo antes
// =============================================================================

`timescale 1ns / 1ps

module tb_lfsr_generator;

    // =========================================================================
    // Parámetros de simulación
    // =========================================================================
    localparam CLK_PERIOD   = 100;          // 100 ns → 10 MHz
    localparam DATA_WIDTH   = 16;
    localparam DEFAULT_SEED = 16'hFFFF;
    localparam MAX_PERIOD   = (1 << DATA_WIDTH) - 1;   // 65 535
    localparam SAFETY_LIMIT = MAX_PERIOD + 100;        // margen anti-cuelgue, escala con DATA_WIDTH

    localparam RST_MIN_NS   = 1_000;        // 1 us
    localparam RST_MAX_NS   = 250_000;      // 250 us

    // =========================================================================
    // Señales del DUT
    // =========================================================================
    reg                    i_clk;
    reg                    i_rst;
    reg                    i_soft_reset;
    reg  [DATA_WIDTH-1:0]  i_seed;
    wire [DATA_WIDTH-1:0]  o_data;
    wire                   o_valid;

    // =========================================================================
    // Control de i_valid — separado en dos drivers para evitar conflicto:
    //   forced_valid : controlado por las secuencias de test (initial block)
    //   rand_valid   : randomizado por el proceso siempre-activo (always block)
    //   i_valid      : wire que selecciona entre ambos según rand_valid_en
    // =========================================================================
    reg  forced_valid;
    reg  rand_valid;
    reg  rand_valid_en;

    wire i_valid = rand_valid_en ? rand_valid : forced_valid; // Compatibilizar Actividad 2 y test de Actividad 3

    // =========================================================================
    // Instancia del DUT
    // =========================================================================
    lfsr_generator #(
        .DATA_WIDTH  (DATA_WIDTH),
        .DEFAULT_SEED(DEFAULT_SEED)
    ) dut (
        .i_clk       (i_clk),
        .i_rst       (i_rst),
        .i_soft_reset(i_soft_reset),
        .i_valid     (i_valid),
        .i_seed      (i_seed),
        .o_data      (o_data),
        .o_valid     (o_valid)
    );

    // ========================================================================= Actividad 2
    // Generación de clock — 10 MHz
    // =========================================================================
    initial i_clk = 1'b0;
    always  #(CLK_PERIOD / 2) i_clk = ~i_clk; // cada 50 ns → flanco de clock

    // ========================================================================= Actividad 2
    // Proceso de valid aleatorio — solo activo cuando rand_valid_en=1
    // =========================================================================
    initial rand_valid = 1'b0; // valor inicial
    always @(posedge i_clk) begin
        if (rand_valid_en)
            rand_valid <= $urandom_range(0, 1);
    end

    // =========================================================================
    // Modelo de referencia (TEST 4) — misma topología Galois que el DUT.
    // Permite predecir o_data ciclo a ciclo bajo i_valid intermitente sin
    // depender del propio DUT.
    // =========================================================================
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

    // ========================================================================= Actividad 2
    // Task: task_set_seed — actualiza i_seed en tiempo de simulación
    // =========================================================================
    task task_set_seed;
        input [DATA_WIDTH-1:0] new_seed;
        begin
            i_seed = new_seed;
            $display("    [task_set_seed] i_seed = 0x%04X", new_seed);
        end
    endtask

    // ========================================================================= Actividad 2
    // Task: task_async_reset — activa i_rst por duración random [1us, 250us]
    // =========================================================================
    task task_async_reset;
        integer rand_ns;
        begin
            rand_ns = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS; // random, modulo y desplazo
            $display("    [task_async_reset] i_rst activo por %0d ns", rand_ns);
            i_rst = 1'b1;
            #(rand_ns);
            @(negedge i_clk);
            i_rst = 1'b0;
            @(posedge i_clk);
            #1;
        end
    endtask

    // ========================================================================= Actividad 2
    // Task: task_soft_reset — activa i_soft_reset por duración random [1us, 250us]
    // =========================================================================
    task task_soft_reset;
        integer rand_ns;
        begin
            rand_ns = ($urandom % (RST_MAX_NS - RST_MIN_NS + 1)) + RST_MIN_NS;
            $display("    [task_soft_reset] i_soft_reset activo por %0d ns (seed=0x%04X)",
                     rand_ns, i_seed);
            i_soft_reset = 1'b1;
            #(rand_ns);
            @(negedge i_clk);
            i_soft_reset = 1'b0;
            @(posedge i_clk);
            #1;
        end
    endtask

    // =========================================================================
    // Variables auxiliares de test
    // =========================================================================
    integer              count;
    integer              idx;
    reg [DATA_WIDTH-1:0] initial_state;
    reg [DATA_WIDTH-1:0] rand_seed_val;
    reg [DATA_WIDTH-1:0] known_seed;
    integer              fail_flag;
    reg [DATA_WIDTH-1:0] ref_model;
    reg                  sampled_valid;

    // =========================================================================
    // Secuencia principal de tests
    // =========================================================================
    initial begin
        
        // ---- Estado inicial de señales ----
        i_rst         = 1'b0;
        i_soft_reset  = 1'b0;
        forced_valid  = 1'b0;
        rand_valid_en = 1'b0;
        i_seed        = DEFAULT_SEED;

        // =====================================================================
        // TEST 0a: Async reset — o_data debe ser DEFAULT_SEED
        //   Verifica directamente que i_rst carga el seed fijo del parámetro.
        // =====================================================================
        $display("\n[TEST 0a] Async reset — o_data debe ser DEFAULT_SEED (0x%04X)", DEFAULT_SEED);

        task_async_reset();

        if (o_data === DEFAULT_SEED)
            $display("  PASS: o_data = 0x%04X", o_data);
        else
            $display("  FAIL: esperado=0x%04X, obtenido=0x%04X", DEFAULT_SEED, o_data);

        if (o_valid === 1'b0)
            $display("  PASS: o_valid = 0 tras i_rst (sin avance real)");
        else
            $display("  FAIL: o_valid = %0b tras i_rst (esperado 0)", o_valid);

        // =====================================================================
        // TEST 0b: Soft reset — o_data debe ser i_seed al finalizar el reset
        //   Verifica que i_soft_reset carga el valor configurado en i_seed.
        // =====================================================================
        $display("\n[TEST 0b] Soft reset — o_data debe ser i_seed (0xA5C3)");

        known_seed = 16'hA5C3;
        task_set_seed(known_seed);
        task_soft_reset();

        if (o_data === known_seed)
            $display("  PASS: o_data = 0x%04X", o_data);
        else
            $display("  FAIL: esperado=0x%04X, obtenido=0x%04X", known_seed, o_data);

        if (o_valid === 1'b0)
            $display("  PASS: o_valid = 0 tras i_soft_reset (sin avance real)");
        else
            $display("  FAIL: o_valid = %0b tras i_soft_reset (esperado 0)", o_valid);

        // =====================================================================
        // TEST 0c: Prioridad i_soft_reset > i_valid
        //   Con ambas señales asertadas en el mismo flanco, i_soft_reset debe
        //   ganar: el LFSR debe cargar i_seed, NO avanzar a lfsr_next.
        // =====================================================================
        $display("\n[TEST 0c] Prioridad: i_soft_reset debe ganar sobre i_valid simultáneo");

        task_async_reset();           // LFSR = DEFAULT_SEED
        known_seed   = 16'hBEEF;
        i_seed       = known_seed;

        // Asertamos ambas en el mismo ciclo de clock
        i_soft_reset = 1'b1;
        forced_valid = 1'b1;
        @(posedge i_clk); #1;        // aquí el DUT debe cargar i_seed, no avanzar
        i_soft_reset = 1'b0;
        forced_valid = 1'b0;

        if (o_data === known_seed)
            $display("  PASS: i_soft_reset ganó — o_data = 0x%04X (= i_seed)", o_data);
        else
            $display("  FAIL: o_data = 0x%04X (esperado 0x%04X); i_soft_reset no tuvo prioridad",
                     o_data, known_seed);

        // o_valid debe reflejar que este dato es un reseed, no un avance PRBS,
        // aunque i_valid haya estado en 1 en el mismo flanco: es la prueba
        // clave de que o_valid "viaja con" el dato en vez de ecoar i_valid.
        if (o_valid === 1'b0)
            $display("  PASS: o_valid = 0 — refleja que NO hubo avance real pese a i_valid=1");
        else
            $display("  FAIL: o_valid = %0b (esperado 0); no debe marcarse válido un dato reseedeado",
                     o_valid);

        // ===================================================================== // Actividad 3 
        // TEST 1: Periodicidad con DEFAULT_SEED
        //   Se avanza el LFSR ciclo a ciclo y se cuenta hasta volver al estado
        //   inicial. Para un LFSR maximal-length de 16 bits, el período = 65 535.
        // =====================================================================
        $display("\n[TEST 1] Periodicidad — DEFAULT_SEED = 0x%04X", DEFAULT_SEED);

        task_async_reset(); // valor inicial = DEFAULT_SEED
        forced_valid  = 1'b1; // habilitar el avance con cada ciclo
        initial_state = o_data;
        count         = 0;

        @(posedge i_clk); #1; count = 1;

        while (o_data !== initial_state) begin
            if (count >= SAFETY_LIMIT) begin
                $display("  FAIL: período superó el límite de seguridad");
                $finish;
            end
            @(posedge i_clk); #1;
            count = count + 1;
        end
        // o_data volvió al estado inicial → fin de la medición del período

        if (count === MAX_PERIOD)
            $display("  PASS: período = %0d  (2^%0d - 1 confirmado)", count, DATA_WIDTH);
        else
            $display("  FAIL: esperado = %0d, medido = %0d", MAX_PERIOD, count);

        forced_valid = 1'b0;

        // ===================================================================== // Actividad 3
        // TEST 2: Periodicidad con seeds random
        //   Para cada seed: (a) async reset, (b) soft reset con seed random,
        //   (c) medición del período. Cualquier seed ≠ 0 → período = 65 535.
        // =====================================================================
        $display("\n[TEST 2] Periodicidad con 5 seeds aleatorias");

        for (idx = 0; idx < 5; idx = idx + 1) begin
            rand_seed_val = ($urandom & 16'hFFFF); // seed random de 16 bits
            if (rand_seed_val == 16'h0000) rand_seed_val = 16'h0001; // seria locazo, pero mejor prevenir

            task_async_reset();
            task_set_seed(rand_seed_val);
            task_soft_reset();

            forced_valid  = 1'b1;
            initial_state = o_data;
            count         = 0;

            @(posedge i_clk); #1; count = 1;

            while (o_data !== initial_state) begin
                if (count >= SAFETY_LIMIT) begin
                    $display("  FAIL [seed=0x%04X]: período excedió %0d", rand_seed_val, SAFETY_LIMIT);
                    count = -1;
                    initial_state = o_data;   // fuerza salida del while
                end else begin
                    @(posedge i_clk); #1;
                    count = count + 1;
                end
            end

            // o_data volvió al estado inicial → fin de la medición del período
            if (count === MAX_PERIOD)
                $display("  PASS [seed=0x%04X] → período = %0d", rand_seed_val, count);
            else if (count !== -1)
                $display("  FAIL [seed=0x%04X] → esperado=%0d, medido=%0d",
                         rand_seed_val, MAX_PERIOD, count);

            forced_valid = 1'b0;
            task_async_reset();
        end

        // ===================================================================== // extra
        // TEST 3: Valid gating
        //   Con i_valid=0 el estado del LFSR debe permanecer constante.
        // =====================================================================
        $display("\n[TEST 3] Valid gating — output debe mantenerse sin i_valid");

        task_async_reset();
        initial_state = o_data;
        forced_valid  = 1'b0;

        repeat (50) @(posedge i_clk); #1;

        if (o_data === initial_state)
            $display("  PASS: output se mantuvo constante durante 50 ciclos sin i_valid");
        else
            $display("  FAIL: output cambió sin i_valid — estado inicial=0x%04X, actual=0x%04X",
                     initial_state, o_data);

        if (o_valid === 1'b0)
            $display("  PASS: o_valid permaneció en 0 durante el gating (sin dato nuevo)");
        else
            $display("  FAIL: o_valid = %0b sin i_valid (esperado 0)", o_valid);

        forced_valid = 1'b0;

        // ===================================================================== // extra
        // TEST 4: Valid aleatorio
        //   Activa rand_valid_en y compara o_data, ciclo a ciclo, contra un
        //   modelo de referencia que solo avanza (lfsr_step) en los ciclos
        //   donde el i_valid muestreado por el DUT fue 1, y se mantiene en el
        //   resto. Ejercita el proceso rand_valid/rand_valid_en (Actividad 2)
        // =====================================================================
        $display("\n[TEST 4] Valid aleatorio — o_data vs. modelo de referencia bajo i_valid intermitente");

        task_async_reset();            // lfsr = DEFAULT_SEED, sincroniza el modelo
        ref_model     = o_data;
        rand_valid_en = 1'b1;
        fail_flag     = 0;

        for (idx = 0; idx < 3000; idx = idx + 1) begin
            sampled_valid = i_valid;   // valor que el DUT va a muestrear en el próximo posedge
            @(posedge i_clk); #1;

            if (sampled_valid)
                ref_model = lfsr_step(ref_model);

            if (o_data !== ref_model) begin
                $display("  FAIL: ciclo %0d — o_data=0x%04X, esperado=0x%04X (i_valid muestreado=%0b)",
                         idx, o_data, ref_model, sampled_valid);
                fail_flag = 1;
            end

            // o_valid debe viajar junto con o_data: en este tramo i_rst e
            // i_soft_reset están en 0, así que o_valid debe calcar exactamente
            // el i_valid muestreado en el flanco que acaba de ocurrir.
            if (o_valid !== sampled_valid) begin
                $display("  FAIL: ciclo %0d — o_valid=%0b, esperado=%0b (debe viajar con o_data)",
                         idx, o_valid, sampled_valid);
                fail_flag = 1;
            end
        end

        rand_valid_en = 1'b0;

        if (!fail_flag)
            $display("  PASS: o_data y o_valid coincidieron con el modelo de referencia en 3000 ciclos de valid aleatorio");
        else
            $display("  FAIL: hubo al menos un mismatch bajo valid aleatorio (ver detalle arriba)");

        // =====================================================================
        $display("\n[DONE] Simulación completa.\n");
        $finish;
    end

endmodule
