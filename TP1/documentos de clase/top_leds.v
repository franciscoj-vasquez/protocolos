//----> TOP LEDS

module top_leds
#(
  parameter N_SWITCH = 4                  ,
  parameter N_LED    = 4
)
(
//----> Output
  output  wire [N_LED    - 1 : 0] o_led   ,
  output  wire [N_LED    - 1 : 0] o_led_b ,
  output  wire [N_LED    - 1 : 0] o_led_g ,
//----> Inputs
  input   wire [N_SWITCH - 1 : 0] i_sw    ,
  input   wire                    i_reset ,
  input   wire                    clock
);

localparam   NB_SHIFT_REG = 4;

//----> VIO output wires (señales de control virtuales generadas desde el dashboard VIO)
wire        sel_mux   ; // 1 = usar controles VIO, 0 = usar entradas físicas
wire        vio_reset ; // reset virtual  (activo bajo, igual que i_reset)
wire [2:0]  vio_sw    ; // [0]=enable, [2:1]=sel_count_limit (reemplaza i_sw[2:0])
wire        vio_sw3   ; // selección de color LED  (reemplaza i_sw[3])

//----> Mux: elige entre entradas físicas y controles VIO según sel_mux
wire [2:0]  sw_int    ;
wire        sw3_int   ;
wire        reset_int ;

assign sw_int    = sel_mux ? vio_sw    : i_sw[2:0];
assign sw3_int   = sel_mux ? vio_sw3   : i_sw[3]  ;
assign reset_int = sel_mux ? vio_reset : i_reset  ;

wire                         shift      ;
wire [NB_SHIFT_REG - 1 : 0]  led_enable ;

counter
u_counter
(
  //----> Output
  .o_shift           (shift        ),
  //----> Inputs
  .i_enable          (sw_int[0]   ),
  .i_sel_count_limit (sw_int[2:1] ),
  .i_reset           (reset_int   ),
  .clock             (clock       )
);

shift_reg
u_shift_reg
(
  //----> Outputs
  .o_led_enable (led_enable  ),
  //----> Inputs
  .i_shift      (shift       ),
  .i_enable     (sw_int[0]   ),
  .i_reset      (reset_int   ),
  .clock        (clock       )
);

//----> Outputs
assign o_led   =  led_enable;
assign o_led_b = ( sw3_int) ? led_enable : 4'b0000;
assign o_led_g = (!sw3_int) ? led_enable : 4'b0000;

`ifdef SYNTHESIS

// -----------------------------------------------------------------------
// VIO (Virtual Input/Output) — Xilinx IP core
//   Configurar en Vivado IP Catalog con:
//     - Input  Probes: 3 x 4 bits  (probe_in0..2 → monitorea o_led, o_led_b, o_led_g)
//     - Output Probes: probe_out0 1b, probe_out1 1b, probe_out2 3b, probe_out3 1b
//   Inicializar probe_out1 (vio_reset) en 1 desde el dashboard para no quedar en reset.
// -----------------------------------------------------------------------
vio_0
u_vio
(
  .clk        (clock     ),
  //----> Inputs al VIO: señales que se monitorean en el dashboard
  .probe_in0  (o_led     ),   // [3:0] LEDs rojo
  .probe_in1  (o_led_b   ),   // [3:0] LEDs azul
  .probe_in2  (o_led_g   ),   // [3:0] LEDs verde
  //----> Outputs del VIO: controles virtuales desde el dashboard
  .probe_out0 (sel_mux   ),   // [0:0] selector mux (0=físico, 1=VIO)
  .probe_out1 (vio_reset ),   // [0:0] reset virtual  (inicializar en 1)
  .probe_out2 (vio_sw    ),   // [2:0] sw[2:0] virtual
  .probe_out3 (vio_sw3   )    // [0:0] sw[3] virtual
);

// -----------------------------------------------------------------------
// ILA (Integrated Logic Analyzer) — Xilinx IP core
//   Configurar en Vivado IP Catalog con:
//     - Number of Probes: 3
//     - probe0..2: 4 bits c/u  (o_led, o_led_b, o_led_g)
//     - Sample depth: 1024 (mínimo recomendado para ver el patrón de LEDs)
// -----------------------------------------------------------------------
ila_0
u_ila
(
  .clk     (clock   ),
  .probe0  (o_led   ),   // [3:0] LEDs rojo
  .probe1  (o_led_b ),   // [3:0] LEDs azul
  .probe2  (o_led_g )    // [3:0] LEDs verde
);

`else

// -----------------------------------------------------------------------
// Simulación: VIO bypasseado — entradas físicas pasan directo al diseño.
// sel_mux=0 → sw_int=i_sw[2:0], sw3_int=i_sw[3], reset_int=i_reset.
// -----------------------------------------------------------------------
assign sel_mux   = 1'b0;
assign vio_reset = 1'b1;
assign vio_sw    = 3'b000;
assign vio_sw3   = 1'b0;

`endif

endmodule