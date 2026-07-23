`default_nettype none
`timescale 1ns/1ns

module top_leds_tb();

localparam N_SWITCH  = 4 ;
localparam N_LED     = 4 ;
localparam NB_COUNTER = 32;

wire [N_LED - 1 : 0] o_led  ;
wire [N_LED - 1 : 0] o_led_b;
wire [N_LED - 1 : 0] o_led_g;

reg  [N_SWITCH - 1 : 0] i_sw   ;
reg                     i_reset;
reg                     clock  ;

top_leds
u_top_leds
(
  .o_led      (o_led  ),
  .o_led_b    (o_led_b),
  .o_led_g    (o_led_g),
  .i_sw       (i_sw   ),
  .i_reset    (i_reset),
  .clock      (clock  )
);


//----> Generamos clock
initial
begin
  clock <= 'd0;
end
always #5 clock = ~clock;


//----> Task para el reset
task reset ();
time reset_time;
begin
  i_reset    <= 'd0;
  reset_time  = $urandom_range(1,100);
  #reset_time;
  @(posedge clock);
  i_reset <= 'd1;
end
endtask


// --- Seleccion de test  ---
// `define TEST1
// `define TEST2
// `define TEST3
// `define TEST4
// `define TEST5
// `define TEST6


`ifdef TEST1
`include "tests/test1.v"
`endif

`ifdef TEST2
`include "tests/test2.v"
`endif

`ifdef TEST3
`include "tests/test3.v"
`endif

`ifdef TEST4
`include "tests/test4.v"
`endif

`ifdef TEST5
`include "tests/test5.v"
`endif

`ifdef TEST6
`include "tests/test6.v"
`endif


endmodule
