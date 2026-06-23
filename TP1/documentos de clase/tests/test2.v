// TEST2: verifica que el sistema es sincronico.
// Con el clock congelado, ningun estado del sistema debe evolucionar.

reg [N_LED      - 1 : 0] prev_o_led    ;
reg [N_LED      - 1 : 0] prev_o_led_b  ;
reg [N_LED      - 1 : 0] prev_o_led_g  ;
reg [NB_COUNTER - 1 : 0] prev_counter  ;
reg [N_LED      - 1 : 0] prev_shift_reg;
integer k                              ;

initial
begin

  force u_top_leds.u_counter.limit_0 = 32'h0000_0010;
  force u_top_leds.u_counter.limit_1 = 32'h0000_0020;
  force u_top_leds.u_counter.limit_2 = 32'h0000_0040;
  force u_top_leds.u_counter.limit_3 = 32'h0000_0080;

  for(k=0; k<20; k=k+1)
  begin

    //----> Config aleatoria de switches, sistema habilitado
    i_sw[0]   = 'd1;
    i_sw[3:1] = $urandom_range(0,7);

    reset();

    //----> Dejamos correr el sistema unos ciclos para que evolucione
    repeat($urandom_range(5,50)) @(posedge clock);

    //----> Congelamos el clock primero
    force clock = 1'b0;
    #1; // Deja que la fase NBA del posedge complete antes de capturar

    //----> Capturamos el estado del sistema con el clock ya frenado
    prev_o_led     = o_led                                    ;
    prev_o_led_b   = o_led_b                                  ;
    prev_o_led_g   = o_led_g                                  ;
    prev_counter   = u_top_leds.u_counter.counter             ;
    prev_shift_reg = u_top_leds.u_shift_reg.shift_register    ;

    //----> Esperamos un tiempo sin flancos de clock
    #($urandom_range(100,1000));

    //----> Verificamos que ninguna señal cambio
    if(prev_o_led != o_led)
    begin
      $display("ERROR TEST2: o_led cambio sin flanco de clock.");
      $display("TEST2 FAILED");
      $finish(2);
    end

    if(prev_o_led_b != o_led_b)
    begin
      $display("ERROR TEST2: o_led_b cambio sin flanco de clock.");
      $display("TEST2 FAILED");
      $finish(2);
    end

    if(prev_o_led_g != o_led_g)
    begin
      $display("ERROR TEST2: o_led_g cambio sin flanco de clock.");
      $display("TEST2 FAILED");
      $finish(2);
    end

    if(prev_counter != u_top_leds.u_counter.counter)
    begin
      $display("ERROR TEST2: counter cambio sin flanco de clock.");
      $display("TEST2 FAILED");
      $finish(2);
    end

    if(prev_shift_reg != u_top_leds.u_shift_reg.shift_register)
    begin
      $display("ERROR TEST2: shift_register cambio sin flanco de clock.");
      $display("TEST2 FAILED");
      $finish(2);
    end

    //----> Liberamos el clock
    release clock;

  end

  $display("TEST2 PASSED");
  $finish();
end
