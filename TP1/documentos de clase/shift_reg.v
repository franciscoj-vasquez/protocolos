module shift_reg
#(
  parameter   NB_SHIFT_REG = 4
)
(
  //----> Outputs
    output wire [NB_SHIFT_REG - 1 : 0]  o_led_enable ,
  //----> Inputs
    input  wire                         i_shift      ,
    input  wire                         i_enable     ,
    input  wire                         i_reset      , 
    input  wire                         clock 
);


//----> Shift register
reg  [NB_SHIFT_REG - 1 : 0] shift_register;

always@(posedge clock or negedge i_reset)
begin
  if      (!i_reset)
  begin
    shift_register <= 4'b1000;
  end
  else if (i_shift && i_enable)
  begin
    shift_register <= {shift_register[0],shift_register[NB_SHIFT_REG-1:1]};
  end
end

assign o_led_enable = shift_register;

endmodule


    // shift_register <= (shift_register == 4'b0001) ? 4'b1000 : (shift_register >> 1);
    // shift_register <= (shift_register == 4'b1000) ? 4'b0100 : 
    //                   (shift_register == 4'b1000) ? 4'b0010 : 
    //                   (shift_register == 4'b1000) ? 4'b0001 : 
    //                                                 4'b1000 ;
    // shift_register <= (shift_register<4'b1000) ? shift_register + shift_register : 'b0001;