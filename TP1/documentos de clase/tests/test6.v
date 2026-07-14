// TEST6: verifica el reset asincrono del sistema.
//   - counter debe ir a 0 sin necesidad de un flanco de clock
//   - shift_register debe volver a 4'b1000 sin necesidad de un flanco de clock
//   - o_led debe reflejar el reset inmediatamente

integer q;

initial
begin

  force u_top_leds.u_counter.limit_0 = 32'h0000_0010 ; // 16
  force u_top_leds.u_counter.limit_1 = 32'h0000_0020 ; // 32
  force u_top_leds.u_counter.limit_2 = 32'h0000_0040 ; // 64
  force u_top_leds.u_counter.limit_3 = 32'h0000_0080 ; // 128

  for(q=0; q<20; q=q+1)
  begin

    i_sw[0]   = 'd1                 ; // habilitado
    i_sw[2:1] = 2'b11               ; // limit_3 = 128: counter mas alto sin riesgo de wrap
    i_sw[3]   = $urandom_range(0,1) ;

    reset(); // lanza un shift

    repeat($urandom_range(2,100)) @(posedge clock);
    #1; // NBAs del ultimo flanco asentadas

    // Verificamos precondicion: el estado debe ser distinto al de reset
    if(u_top_leds.u_counter.counter == 0)
    begin
      $display("ERROR TEST6 precondicion iter %0d: counter ya es 0 antes del reset.", q);
      $finish(2);
    end
    if(u_top_leds.u_shift_reg.shift_register === 4'b1000)
    begin
      $display("ERROR TEST6 precondicion iter %0d: shift_register ya es 1000 antes del reset.", q);
      $finish(2);
    end

    // Congelamos el clock: a partir de aqui no hay flancos posibles
    force clock = 1'b0;
    #1;

    // Asertamos reset de forma bloqueante (efecto inmediato)
    i_reset = 1'b0;
    #1; // tiempo para que las NBAs del reset asincrono se completen

    // ---- Verificamos que counter se fue a 0 SIN flanco de clock ----
    if(u_top_leds.u_counter.counter !== 0)
    begin
      $display("ERROR TEST6 iter %0d: counter no se reseteo asincrónicamente (val=%0d).",
               q, u_top_leds.u_counter.counter);
      $display("TEST6 FAILED");
      $finish(2);
    end

    // ---- Verificamos que shift_register volvio a 4'b1000 SIN flanco de clock ----
    if(u_top_leds.u_shift_reg.shift_register !== 4'b1000)
    begin
      $display("ERROR TEST6 iter %0d: shift_register no se reseteo asincrónicamente (val=%b).",
               q, u_top_leds.u_shift_reg.shift_register);
      $display("TEST6 FAILED");
      $finish(2);
    end

    // ---- Verificamos que o_led refleja el reset ----
    if(o_led !== 4'b1000)
    begin
      $display("ERROR TEST6 iter %0d: o_led no refleja el reset (val=%b).", q, o_led);
      $display("TEST6 FAILED");
      $finish(2);
    end

    // Liberamos reset y clock para la siguiente iteracion
    i_reset = 1'b1;
    release clock;

  end

  $display("TEST6 PASSED");
  $finish();
end
