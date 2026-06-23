// TEST1: verifica que con i_sw[0]=0 (deshabilitado), o_led no cambia.

reg [N_LED      - 1 : 0] prev_o_led    ;
reg [NB_COUNTER - 1 : 0] clock_counter ;
integer i                               ;
integer j                               ;

initial
begin

  force u_top_leds.u_counter.limit_0 = 32'h0000_0010;
  force u_top_leds.u_counter.limit_1 = 32'h0000_0020;
  force u_top_leds.u_counter.limit_2 = 32'h0000_0040;
  force u_top_leds.u_counter.limit_3 = 32'h0000_0080;

  for(i=0; i<100; i=i+1)
  begin

    i_sw[0]       = 'd0;
    i_sw[3:1]     = $urandom_range(0,7);
    prev_o_led    = 'd0;
    clock_counter = 'd0;

    reset();

    //----> Habilitamos el contador
    i_sw[0] = 'd1;

    //----> Esperamos un momento random (1us = 1000 * timescale 1ns)
    #($urandom_range(1,5) * 1000);

    //----> Deshabilitamos y guardamos el estado actual
    i_sw[0]    = 'd0  ;
    prev_o_led = o_led;

    //----> Verificamos que o_led no cambia durante N ciclos
    clock_counter = $urandom_range(50,500);

    for(j=0; j<clock_counter; j=j+1)
    begin
      @(posedge clock);
      if(prev_o_led != o_led)
      begin
        $display("ERROR TEST1: o_led cambio con el contador deshabilitado.");
        $display("TEST1 FAILED");
        $finish(2);
      end
    end

  end

  $display("TEST1 PASSED");
  $finish();
end
