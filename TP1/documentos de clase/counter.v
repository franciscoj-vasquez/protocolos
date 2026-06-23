module counter
#(
  parameter NB_COUNT_LIMIT  = 2
)
(
  //----> Output
  output  wire                          o_shift           ,
  //----> Inputs
  input   wire                          i_enable          ,
  input   wire [NB_COUNT_LIMIT - 1 : 0] i_sel_count_limit ,
  input   wire                          i_reset           ,
  input   wire                          clock
)                                                         ;



//----> Define Count Limits
localparam NB_COUNTER      = 32                           ;

reg  [NB_COUNTER - 1 : 0] counter                         ;
wire [NB_COUNTER - 1 : 0] counter_next                    ;

reg  [NB_COUNTER - 1 : 0] limit_0                         ;
reg  [NB_COUNTER - 1 : 0] limit_1                         ;
reg  [NB_COUNTER - 1 : 0] limit_2                         ;
reg  [NB_COUNTER - 1 : 0] limit_3                         ;

always@(posedge clock or negedge i_reset)
begin
  if      (!i_reset )
  begin
    limit_0 <= 'd0 ;
    limit_1 <= 'd0 ;
    limit_2 <= 'd0 ;
    limit_3 <= 'd0 ;
  end
  else
  begin
    limit_0 <= 32'h0080_0000 ;
    limit_1 <= 32'h0100_0000 ;
    limit_2 <= 32'h0200_0000 ;
    limit_3 <= 32'h0400_0000 ;
  end
end
// localparam    LIMIT_0   = 32'h0080_0000                   ; // ~84ms  @ 100MHz
// localparam    LIMIT_1   = 32'h0100_0000                   ; // ~168ms @ 100MHz
// localparam    LIMIT_2   = 32'h0200_0000                   ; // ~335ms @ 100MHz
// localparam    LIMIT_3   = 32'h0400_0000                   ; // ~671ms @ 100MHz

assign counter_next = ((i_sel_count_limit == 2'b00) && (counter >= limit_0)) ? 'd0 :
                      ((i_sel_count_limit == 2'b01) && (counter >= limit_1)) ? 'd0 :
                      ((i_sel_count_limit == 2'b10) && (counter >= limit_2)) ? 'd0 :
                      ((i_sel_count_limit == 2'b11) && (counter >= limit_3)) ? 'd0 :
                                                                                counter + 1'b1;

//----> Counter
always@(posedge clock or negedge i_reset)
begin
  if      (!i_reset )
  begin
    counter <= 'd0                              ;
  end
  else if (!i_enable)
  begin
    counter <= counter                          ;
  end
  else
  begin
    counter <= counter_next                     ;
  end
end



//----> Outputs
assign o_shift = (counter == 'd0)               ;



endmodule


// assign o_shift =  ((i_sel_count_limit == 2'b00) && (counter >= LIMIT_0)) ? 'd1 :
//                   ((i_sel_count_limit == 2'b01) && (counter >= LIMIT_1)) ? 'd1 :
//                   ((i_sel_count_limit == 2'b10) && (counter >= LIMIT_2)) ? 'd1 :
//                   ((i_sel_count_limit == 2'b11) && (counter >= LIMIT_3)) ? 'd1 :
//                                                                            'd0

// reg  [NB_COUNTER - 1 : 0] counter_next ;
// always(*)
// begin
//   counter_next = 'd0
//   case(i_sel_count_limit)
//     'b00:
//       if (counter_next >= LIMIT_0) counter_next = 'd0           ;
//       else                         counter_next = counter + 1'b1;
//     'b01:
//       if (counter_next >= LIMIT_0) counter_next = 'd0           ;
//       else                         counter_next = counter + 1'b1;
//     'b10:
//       if (counter_next >= LIMIT_0) counter_next = 'd0           ;
//       else                         counter_next = counter + 1'b1;
//     'b11:
//       if (counter_next >= LIMIT_0) counter_next = 'd0           ;
//       else                         counter_next = counter + 1'b1;
//   endcase
// end