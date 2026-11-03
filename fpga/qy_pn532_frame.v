`timescale 1ns/1ps
`default_nettype none
// Bounded PN532 normal-frame receiver; extended frames deliberately rejected.
// payload byte 0 is TFI (D5); byte 1 response command. Checks LCS, DCS, postamble.
module qy_pn532_frame #(parameter [63:0] TIMEOUT_US=20000)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire rx_valid,rx_error,input wire [7:0] rx_data,
 output reg ack,valid,error,output reg [7:0] length,output reg [511:0] payload
);
 reg [3:0] state;reg [7:0] len,index,sum;reg [511:0] work;
 reg [63:0] last_rx;
 always @(posedge clk)begin
  if(!rst_n)begin state<=0;len<=0;index<=0;sum<=0;work<=0;last_rx<=0;
   ack<=0;valid<=0;error<=0;length<=0;payload<=0;end
  else begin
   ack<=0;valid<=0;error<=0;
   if(rx_error||(state!=0&&(now_us<last_rx||now_us-last_rx>TIMEOUT_US)))begin state<=0;error<=1;end
   else if(rx_valid)begin
    last_rx<=now_us;
    case(state)
     0:if(rx_data==0)state<=1;
     1:if(rx_data==0)state<=2;else state<=0;
     2:if(rx_data==8'hff)state<=3;else state<=rx_data==0?2:0;
     3:begin len<=rx_data;state<=4;end
     4:begin
      if(len==0&&rx_data==8'hff)state<=8;
      else if(len>=2&&len<=64&&((len+rx_data)&8'hff)==0)begin state<=5;index<=0;sum<=0;work<=0;end
      else begin state<=0;error<=1;end
     end
     5:begin
      work[index*8+:8]<=rx_data;sum<=sum+rx_data;index<=index+1'b1;
      if(index+1==len)state<=6;
     end
     6:if(((sum+rx_data)&8'hff)==0)state<=7;else begin state<=0;error<=1;end
     7:begin state<=0;if(rx_data==0&&work[7:0]==8'hd5)begin valid<=1;payload<=work;length<=len;end else error<=1;end
     8:begin state<=0;if(rx_data==0)ack<=1;else error<=1;end
     default:begin state<=0;error<=1;end
    endcase
   end
  end
 end
endmodule
`default_nettype wire
