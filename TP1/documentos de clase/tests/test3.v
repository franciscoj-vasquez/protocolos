// TEST3: verifica que el periodo entre shifts coincide con los limites configurados.
//
// Logica: despues de reset, counter=0 => primer shift inmediato.
// A partir de ahi, el periodo entre shifts es (limit + 1) ciclos de clock,S

integer             sel            ; // seleccion de limite (0 a 3, mapea a i_sw[2:1])
integer             cycle_count    ;
integer             rep            ;
reg  [N_LED - 1:0]  snap_led       ; // captura de o_led al inicio de cada periodo
reg  [NB_COUNTER-1:0] expected_period; // periodo esperado segun el limite activo

localparam FORCED_LIMIT_0 = 32'h0000_0010;   // 16  ciclos
localparam FORCED_LIMIT_1 = 32'h0000_0020;   // 32  ciclos
localparam FORCED_LIMIT_2 = 32'h0000_0040;   // 64  ciclos
localparam FORCED_LIMIT_3 = 32'h0000_0080;   // 128 ciclos

initial
begin

  force u_top_leds.u_counter.limit_0 = FORCED_LIMIT_0;
  force u_top_leds.u_counter.limit_1 = FORCED_LIMIT_1;
  force u_top_leds.u_counter.limit_2 = FORCED_LIMIT_2;
  force u_top_leds.u_counter.limit_3 = FORCED_LIMIT_3;

  i_sw[0] = 1'b1; // habilitamos el contador y el shift register
  i_sw[3] = 1'b0; // color de LEDs 

  for (sel = 0; sel < 4; sel = sel + 1)
  begin

    i_sw[2:1] = sel[1:0]; // Se selecciona el limite a testear

    // se calcula el periodo esperado para esta seleccion
    case (sel)
      0: expected_period = FORCED_LIMIT_0 + 1;
      1: expected_period = FORCED_LIMIT_1 + 1;
      2: expected_period = FORCED_LIMIT_2 + 1;
      3: expected_period = FORCED_LIMIT_3 + 1;
    endcase

    reset(); // llevamos counter y shift_register a su estado inicial

    // Post-reset: counter=0 => o_shift=1 => el primer shift ocurre en el
    // primer flanco de clock. Lo descartamos para medir periodos completos.
    @(posedge clock);
    #1; // pequeno delay para que las senales combinacionales se estabilicen

    // Verificamos 5 periodos consecutivos para confirmar que el timing es estable
    for (rep = 0; rep < 5; rep = rep + 1)
    begin

      snap_led    = o_led; // guardamos el valor actual de o_led como referencia
      cycle_count = 0;

      // Contamos flancos de clock hasta que o_led cambie (indica que hubo un shift)
      while (o_led == snap_led)
      begin
        @(posedge clock);
        cycle_count = cycle_count + 1;
        #1; // pequeno delay para que las senales combinacionales se estabilicen
      end
      // Aqui ya hubo un shift
      // El numero de ciclos contados debe coincidir con el periodo esperado
      if (cycle_count !== expected_period)
      begin
        $display("ERROR TEST3: sel=%0d, rep=%0d, periodo=%0d, esperado=%0d",
                  sel, rep, cycle_count, expected_period);
        $display("TEST3 FAILED");
        $finish(2);
      end

    end

  end

  $display("TEST3 PASSED");
  $finish();

end
