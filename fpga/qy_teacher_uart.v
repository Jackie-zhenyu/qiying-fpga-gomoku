`timescale 1ns/1ps
`default_nettype none
module qy_teacher_uart #(parameter CLK_HZ=137500000,BAUD=115200)(
 input wire clk,rst_n,rx,output reg tx,
 output reg rx_valid,output reg [7:0] rx_data,output reg rx_error,
 input wire tx_valid,input wire [7:0] tx_data,output wire tx_ready
);
 localparam DIV=(CLK_HZ+BAUD/2)/BAUD;
 (* ASYNC_REG="TRUE" *) reg rx_meta,rx_sync;
 reg [31:0] rc,tc;reg [3:0] rb,tb;reg [7:0] rd;reg [9:0] td;reg receiving,sending;
 assign tx_ready=!sending;
 always @(posedge clk)begin
  if(!rst_n)begin rx_meta<=1;rx_sync<=1;tx<=1;rx_valid<=0;rx_error<=0;rx_data<=0;
   rc<=0;tc<=0;rb<=0;tb<=0;rd<=0;td<=1023;receiving<=0;sending<=0;end
  else begin
   rx_meta<=rx;rx_sync<=rx_meta;rx_valid<=0;rx_error<=0;
   if(!receiving)begin if(!rx_sync)begin receiving<=1;rc<=DIV/2-1;rb<=0;end end
   else if(rc!=0)rc<=rc-1'b1;
   else begin
    rc<=DIV-1;
    if(rb==0)begin if(rx_sync)receiving<=0;else rb<=1;end
    else if(rb<=8)begin rd[rb-1]<=rx_sync;rb<=rb+1'b1;end
    else begin receiving<=0;if(rx_sync)begin rx_data<=rd;rx_valid<=1;end else rx_error<=1;end
   end
   if(!sending)begin
    tx<=1;
    if(tx_valid)begin sending<=1;td<={1'b1,tx_data,1'b0};tx<=0;tc<=DIV-1;tb<=0;end
   end else if(tc!=0)tc<=tc-1'b1;
   else if(tb==9)begin sending<=0;tx<=1;end
   else begin tb<=tb+1'b1;td<={1'b1,td[9:1]};tx<=td[1];tc<=DIV-1;end
  end
 end
endmodule
`default_nettype wire
