// TEST4: verifica el comportamiento al cambiar el limite del contador en caliente.
//
// Caso A (limite mayor → limite menor): si counter > nuevo limite, el contador
//         debe resetearse a 0 en el siguiente posedge, y el shift_register debe
//         shiftear en el posedge siguiente a ese.
//
// Caso B (limite menor → limite mayor): si counter < nuevo limite, el contador
//         debe seguir incrementando normalmente, sin reset ni shift extra.

reg [N_LED      - 1 : 0] prev_shift_reg ;
reg [NB_COUNTER - 1 : 0] prev_counter   ;
integer m                               ;

initial
begin

  force u_top_leds.u_counter.limit_0 = 32'h0000_0010 ; // 16
  force u_top_leds.u_counter.limit_1 = 32'h0000_0020 ; // 32
  force u_top_leds.u_counter.limit_2 = 32'h0000_0040 ; // 64
  force u_top_leds.u_counter.limit_3 = 32'h0000_0080 ; // 128

  for(m=0; m<20; m=m+1)
  begin

    // CASO A: limite mayor -> limite menor
    // Corremos con limit_3 (128). Avanzamos 30 ciclos: counter = 30.
    // 30 > limit_0 (16), por lo que al cambiar a limit_0 el contador
    // debe resetearse en el siguiente posedge y shiftear en el siguiente.

    i_sw[0]   = 'd1                 ;
    i_sw[2:1] = 2'b11               ; // limit_3 = 128
    i_sw[3]   = $urandom_range(0,1) ;

    reset();

    // Despues de reset el primer posedge shiftea y counter pasa a 1.
    // Tras 30 posedges mas: counter = 30  (16 < 30 < 128).
    repeat(30) @(posedge clock);
    #1; // dejar que las NBAs del ultimo flanco se completen

    // Capturamos shift_register antes de cambiar el limite
    prev_shift_reg = u_top_leds.u_shift_reg.shift_register ;

    // Cambiamos a limite menor: counter (30) >= limit_0 (16) -> counter_next = 0
    i_sw[2:1] = 2'b00 ;

    // --- Posedge 1 post-cambio: counter debe ir a 0 ---
    @(posedge clock);
    #1;

    if(u_top_leds.u_counter.counter !== 0)
    begin
      $display("ERROR TEST4 CASO A iter %0d: contador no se reseteo (val=%0d).", m, u_top_leds.u_counter.counter);
      $display("TEST4 FAILED");
      $finish(2);
    end

    // --- Posedge 2 post-cambio: o_shift=1 en este ciclo -> shift_register debe haber shiftado ---
    @(posedge clock);
    #1;

    if(u_top_leds.u_shift_reg.shift_register === prev_shift_reg)
    begin
      $display("ERROR TEST4 CASO A iter %0d: shift_register no shifteo luego del reset del contador.", m);
      $display("TEST4 FAILED");
      $finish(2);
    end

    // CASO B: limite menor -> limite mayor
    // Corremos con limit_0 (16). Avanzamos 5 ciclos: counter = 5.
    // 5 < limit_3 (128), por lo que al cambiar a limit_3 el contador
    // NO debe resetearse: debe incrementar en 1 y shift_reg no cambia.

    i_sw[0]   = 'd1                 ;
    i_sw[2:1] = 2'b00               ; // limit_0 = 16
    i_sw[3]   = $urandom_range(0,1) ;

    reset();

    // Tras 5 posedges: counter = 5  (5 < 16 < 128)
    repeat(5) @(posedge clock);
    #1;

    // Capturamos estado antes del cambio
    prev_counter   = u_top_leds.u_counter.counter             ;
    prev_shift_reg = u_top_leds.u_shift_reg.shift_register    ;

    // Cambiamos a limite mayor: counter (5) < limit_3 (128) -> solo incrementa
    i_sw[2:1] = 2'b11 ;

    // --- Un posedge: counter debe incrementar normalmente, sin shift extra ---
    @(posedge clock);
    #1;

    if(u_top_leds.u_counter.counter !== prev_counter + 1)
    begin
      $display("ERROR TEST4 CASO B iter %0d: contador se reseteo indebidamente (val=%0d, esperado=%0d).",
               m, u_top_leds.u_counter.counter, prev_counter + 1);
      $display("TEST4 FAILED");
      $finish(2);
    end

    if(u_top_leds.u_shift_reg.shift_register !== prev_shift_reg)
    begin
      $display("ERROR TEST4 CASO B iter %0d: shift_register cambio indebidamente.", m);
      $display("TEST4 FAILED");
      $finish(2);
    end

  end

  $display("TEST4 PASSED");
  $finish();
end
