// TEST5: verifica que i_sw[3] controla el canal de color de los LEDs.
//   sw[3]=1 -> o_led_b == o_led  y  o_led_g == 0  (azul)
//   sw[3]=0 -> o_led_g == o_led  y  o_led_b == 0  (verde)
// Ademas verifica que o_led no depende de sw[3].

reg [N_LED - 1 : 0] prev_o_led ;
integer p                      ;

initial
begin

  force u_top_leds.u_counter.limit_0 = 32'h0000_0010 ;
  force u_top_leds.u_counter.limit_1 = 32'h0000_0020 ;
  force u_top_leds.u_counter.limit_2 = 32'h0000_0040 ;
  force u_top_leds.u_counter.limit_3 = 32'h0000_0080 ;

  for(p=0; p<50; p=p+1)
  begin

    i_sw[0]   = 'd1                 ;
    i_sw[2:1] = $urandom_range(0,3) ;
    i_sw[3]   = $urandom_range(0,1) ;

    reset();

    // Dejamos evolucionar el sistema para tener un estado de LEDs variable
    repeat($urandom_range(1,100)) @(posedge clock);
    #1; // NBAs del ultimo flanco asentadas

    // Guardamos o_led (debe ser independiente de sw[3])
    prev_o_led = o_led;

    // ---- Verificacion con sw[3] = 1 (azul) ----
    i_sw[3] = 1'b1;
    #1; // la logica combinacional se actualiza

    if(o_led !== prev_o_led)
    begin
      $display("ERROR TEST5 iter %0d: o_led cambio al modificar sw[3] (antes=%b, ahora=%b).",
               p, prev_o_led, o_led);
      $display("TEST5 FAILED");
      $finish(2);
    end

    if(o_led_b !== o_led)
    begin
      $display("ERROR TEST5 iter %0d: con sw[3]=1, o_led_b (%b) != o_led (%b).",
               p, o_led_b, o_led);
      $display("TEST5 FAILED");
      $finish(2);
    end

    if(o_led_g !== 4'b0000)
    begin
      $display("ERROR TEST5 iter %0d: con sw[3]=1, o_led_g (%b) != 0.", p, o_led_g);
      $display("TEST5 FAILED");
      $finish(2);
    end

    // ---- Verificacion con sw[3] = 0 (verde) ----
    i_sw[3] = 1'b0;
    #1;

    if(o_led !== prev_o_led)
    begin
      $display("ERROR TEST5 iter %0d: o_led cambio al modificar sw[3] (antes=%b, ahora=%b).",
               p, prev_o_led, o_led);
      $display("TEST5 FAILED");
      $finish(2);
    end

    if(o_led_g !== o_led)
    begin
      $display("ERROR TEST5 iter %0d: con sw[3]=0, o_led_g (%b) != o_led (%b).",
               p, o_led_g, o_led);
      $display("TEST5 FAILED");
      $finish(2);
    end

    if(o_led_b !== 4'b0000)
    begin
      $display("ERROR TEST5 iter %0d: con sw[3]=0, o_led_b (%b) != 0.", p, o_led_b);
      $display("TEST5 FAILED");
      $finish(2);
    end

  end

  $display("TEST5 PASSED");
  $finish();
end
