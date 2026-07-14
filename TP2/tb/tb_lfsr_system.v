// =============================================================================
// Testbench : tb_lfsr_system
// DUTs      : lfsr_generator + lfsr_checker (integrados)
//
// Actividad 5 — tests:
//   TEST 1 : tráfico válido → checker lockea y no desbloquea en un período
//   TEST 2 : frontera lock   — 4 válidos + 1 inválido → nunca lockea
//   TEST 3 : frontera unlock — lockeado + (2 inv + 1 val)×N → nunca desbloquea
//   TEST 4 : transición      — (5 val + 3 inv)×5 → siempre alterna lock/unlock
//   TEST 5 : reset random    — checker siempre re-lockea tras reset
//
// Inyección de errores:
//   inject_error=1 : checker recibe ~gen_o_data (inversión garantiza mismatch)
//   inject_error=0 : checker recibe gen_o_data  (datos reales del generador)
// =============================================================================

`timescale 1ns / 1ps

module tb_lfsr_system;

    // =========================================================================
    // Parámetros
    // =========================================================================
    localparam CLK_PERIOD       = 100;
    localparam DATA_WIDTH       = 16;
    localparam DEFAULT_SEED     = 16'hFFFF;
    localparam MAX_PERIOD       = (1 << DATA_WIDTH) - 1;   // 65 535
    localparam LOCK_THRESHOLD   = 5;
    localparam UNLOCK_THRESHOLD = 3;

    localparam RST_MIN_NS = 1_000;
    localparam RST_MAX_NS = 250_000;

    // Ciclos de valid necesarios para lockear desde ACQUIRE:
    //   1 ciclo de ACQUIRE + LOCK_THRESHOLD ciclos en UNLOCKED
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

    // Checker
    reg                    chk_rst;
    reg                    inject_error;
    wire [DATA_WIDTH-1:0]  chk_i_data;
    wire                   o_lock;

    // Inversión bit a bit garantiza mismatch contra cualquier estado PRBS ≠ 0
    assign chk_i_data = inject_error ? ~gen_o_data : gen_o_data;

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
        .o_data      (gen_o_data)
    );

    lfsr_checker #(
        .DATA_WIDTH       (DATA_WIDTH),
        .LOCK_THRESHOLD   (LOCK_THRESHOLD),
        .UNLOCK_THRESHOLD (UNLOCK_THRESHOLD)
    ) u_chk (
        .i_clk   (i_clk),
        .i_rst   (chk_rst),
        .i_valid (i_valid),
        .i_data  (chk_i_data),
        .o_lock  (o_lock)
    );

    // =========================================================================
    // Clock
    // =========================================================================
    initial i_clk = 1'b0;
    always  #(CLK_PERIOD / 2) i_clk = ~i_clk;

    // =========================================================================
    // Monitor de o_lock — imprime cada cambio de estado
    // =========================================================================
    reg prev_lock;
    initial prev_lock = 1'b0;

    always @(o_lock) begin
        $display("[LOCK MONITOR] t=%0t ns  |  o_lock: %0b → %0b",
                 $time, prev_lock, o_lock);
        prev_lock = o_lock;
    end

    // =========================================================================
    // Task: reset_generator — reset asíncrono por tiempo random [1us, 250us]
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

    // =========================================================================
    // Task: reset_checker — reset asíncrono por tiempo random [1us, 250us]
    // =========================================================================
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
    // Task: send_valid — N ciclos de datos correctos (inject_error=0)
    // =========================================================================
    task send_valid;
        input integer n;
        begin
            inject_error = 1'b0;
            i_valid      = 1'b1;
            repeat (n) @(posedge i_clk);
            @(negedge i_clk);
            i_valid = 1'b0;
            #1;
        end
    endtask

    // =========================================================================
    // Task: send_invalid — N ciclos de datos erróneos (inject_error=1)
    // =========================================================================
    task send_invalid;
        input integer n;
        begin
            inject_error = 1'b1;
            i_valid      = 1'b1;
            repeat (n) @(posedge i_clk);
            @(negedge i_clk);
            i_valid      = 1'b0;
            inject_error = 1'b0;
            #1;
        end
    endtask

    // =========================================================================
    // Task: lock_checker — resetea el checker y lo lleva hasta estado LOCKED
    // =========================================================================
    task lock_checker;
        begin
            reset_checker();
            send_valid(CYCLES_TO_LOCK);   // 1 ACQUIRE + 5 UNLOCKED → LOCKED
        end
    endtask

    // =========================================================================
    // Variables auxiliares
    // =========================================================================
    integer  idx;
    integer  fail_flag;

    // =========================================================================
    // Secuencia principal
    // =========================================================================
    initial begin
        $dumpfile("tb_lfsr_system.vcd");
        $dumpvars(0, tb_lfsr_system);

        // Inicialización
        gen_rst      = 1'b0;
        gen_soft_rst = 1'b0;
        chk_rst      = 1'b0;
        i_valid      = 1'b0;
        i_seed       = DEFAULT_SEED;
        inject_error = 1'b0;

        reset_generator();
        reset_checker();

        // =================================================================
        // TEST 0: Soft reset del generador — verifica carga de i_seed
        //   a) gen_soft_rst debe cargar i_seed en gen_o_data
        //   b) el checker debe lockear correctamente con la nueva seed
        // =================================================================
        $display("\n[TEST 0] Soft reset del generador con i_seed conocida (0xCAFE)");

        i_seed = 16'hCAFE;
        gen_soft_rst = 1'b1;
        @(posedge i_clk);       // loads i_seed at this posedge
        @(negedge i_clk);
        gen_soft_rst = 1'b0;
        @(posedge i_clk); #1;

        if (gen_o_data === 16'hCAFE)
            $display("  PASS [0a]: gen_o_data = 0x%04X tras gen_soft_rst", gen_o_data);
        else
            $display("  FAIL [0a]: esperado=0xCAFE, obtenido=0x%04X", gen_o_data);

        // Checker debe adquirir y lockear desde la nueva seed
        reset_checker();
        send_valid(CYCLES_TO_LOCK);

        if (o_lock)
            $display("  PASS [0b]: checker lockeó correctamente con gen seed=0xCAFE");
        else
            $display("  FAIL [0b]: checker no pudo lockear tras soft reset del generador");

        // Restaurar seed y estado inicial para los tests siguientes
        i_seed = DEFAULT_SEED;
        reset_generator();
        reset_checker();

        // =================================================================
        // TEST 1: Tráfico válido — lock y hold por un período completo
        // =================================================================
        $display("\n[TEST 1] Tráfico válido continuo — lock + hold por %0d ciclos", MAX_PERIOD);

        lock_checker();

        if (!o_lock) begin
            $display("  FAIL: el checker no logró lockear — abortando");
            $finish;
        end

        // Correr MAX_PERIOD ciclos y verificar que o_lock no cae
        fail_flag    = 0;
        inject_error = 1'b0;
        i_valid      = 1'b1;

        repeat (MAX_PERIOD) begin
            @(posedge i_clk); #1;
            if (!o_lock) fail_flag = 1;
        end

        i_valid = 1'b0;

        if (!fail_flag)
            $display("  PASS: o_lock se mantuvo HIGH durante todo el período (%0d ciclos)", MAX_PERIOD);
        else
            $display("  FAIL: o_lock cayó durante el período");

        // =================================================================
        // TEST 2: Frontera lock — 4 válidos + 1 inválido → nunca lockea
        //   Secuencia: 1 ACQUIRE + 4 UNLOCKED(valid) + 1 inválido
        //   valid_cnt llega a 4 (==LOCK_THRESHOLD-1) pero falta un acierto más.
        //   El inválido resetea valid_cnt → vuelve a ACQUIRE sin haber lockeado.
        // =================================================================
        $display("\n[TEST 2] Frontera lock: 4 válidos + 1 inválido → nunca debe lockear");

        reset_generator();
        reset_checker();

        send_valid(1);       // ciclo ACQUIRE
        send_valid(4);       // 4 checks en UNLOCKED: valid_cnt = 1, 2, 3, 4
        send_invalid(1);     // mismatch → valid_cnt = 0, state → ACQUIRE

        if (!o_lock)
            $display("  PASS: checker nunca lockeó");
        else
            $display("  FAIL: checker lockeó inesperadamente");

        // =================================================================
        // TEST 3: Frontera unlock — lockeado + (2 inv + 1 val)×10 → nunca desbloquea
        //   El patrón de 2 inválidos nunca alcanza UNLOCK_THRESHOLD=3
        //   consecutivos antes de que un válido resetee invalid_cnt.
        // =================================================================
        $display("\n[TEST 3] Frontera unlock: lockeado + (2 inv + 1 val)×10 → nunca desbloquea");

        reset_generator();
        lock_checker();

        if (!o_lock) begin
            $display("  FAIL: no se pudo lockear — abortando test 3");
        end else begin
            fail_flag = 0;
            for (idx = 0; idx < 10; idx = idx + 1) begin
                send_invalid(2);   // invalid_cnt: 0→1→2 (no llega a condición de unlock)
                send_valid(1);     // invalid_cnt → 0
                if (!o_lock) begin
                    $display("  FAIL: checker desbloqueó en iteración %0d", idx);
                    fail_flag = 1;
                end
            end
            if (!fail_flag)
                $display("  PASS: o_lock permaneció HIGH durante 10 iteraciones (2inv+1val)");
        end

        // =================================================================
        // TEST 4: Transición — (5 val + 3 inv)×5 → siempre alterna lock/unlock
        //   5 válidos desde ACQUIRE → lock; 3 inválidos → unlock; repetir.
        // =================================================================
        $display("\n[TEST 4] Transición: patrón (5 val + 3 inv)×5 — debe alternar lock/unlock");

        reset_generator();
        reset_checker();

        fail_flag = 0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            // Lock desde ACQUIRE (1 ACQUIRE + 5 UNLOCKED)
            send_valid(CYCLES_TO_LOCK);
            if (!o_lock) begin
                $display("  FAIL [iter %0d]: no lockeó tras %0d válidos", idx, CYCLES_TO_LOCK);
                fail_flag = 1;
            end else
                $display("  [iter %0d] LOCKED   ✓", idx);

            // Unlock: 3 inválidos consecutivos
            send_invalid(UNLOCK_THRESHOLD);
            if (o_lock) begin
                $display("  FAIL [iter %0d]: no desbloqueo tras %0d inválidos",
                         idx, UNLOCK_THRESHOLD);
                fail_flag = 1;
            end else
                $display("  [iter %0d] UNLOCKED ✓", idx);
        end

        if (!fail_flag)
            $display("  PASS: todas las transiciones lock/unlock fueron correctas");

        // =================================================================
        // TEST 5: Reset random del checker — debe relockear siempre
        // =================================================================
        $display("\n[TEST 5] Reset random del checker ×5 — debe relockear tras cada reset");

        reset_generator();

        fail_flag = 0;
        for (idx = 0; idx < 5; idx = idx + 1) begin
            // Tráfico válido por tiempo random antes del reset
            send_valid($urandom_range(1, 50));

            reset_checker();

            if (o_lock) begin
                $display("  FAIL [iter %0d]: o_lock no bajó tras reset", idx);
                fail_flag = 1;
            end

            // Re-lockear desde estado actual del generador
            send_valid(CYCLES_TO_LOCK);

            if (o_lock)
                $display("  PASS [iter %0d]: checker se relockeo correctamente", idx);
            else begin
                $display("  FAIL [iter %0d]: checker no pudo relockear", idx);
                fail_flag = 1;
            end
        end

        if (!fail_flag)
            $display("  PASS: todos los re-locks exitosos tras reset random");

        // =================================================================
        $display("\n[DONE] Simulación del sistema completa.\n");
        $finish;
    end

endmodule
