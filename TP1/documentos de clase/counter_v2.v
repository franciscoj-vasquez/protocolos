module counter
#(
  parameter NB_COUNTER = 32                         ,
)
(
  //----> Output
  output  wire  [NB_COUNTER - 1 : 0]  o_count       ,
  //----> Inputs
  input   wire                        i_sw          ,
  input   wire                        i_reset       ,
  input   wire                        i_reset_count ,
  input   wire                        clock
);


//----> Counter
reg [NB_COUNTER - 1 : 0] counter;

always@(posedge clock or negedge i_reset)
begin
  if      (!i_reset     )
  begin
    counter <= 'd0                                  ;
  end
  else if (!i_sw        )
  begin
    counter <= counter                              ;
  end
  else if (i_reset_count)
  begin
    counter <= 'd0                                  ;
  end
  else
  begin
    counter <= counter + 1'b1                       ;
  end
end


endmodule