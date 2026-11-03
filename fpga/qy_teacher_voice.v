`timescale 1ns/1ps
`default_nettype none
// CI1302 YB-MAD01 frame protocol. Draft profile IDs require matching module
// firmware. Production default is DISABLED; never interpret stock car words.
module qy_teacher_voice #(
 parameter PROFILE_READY=0,
 parameter [47:0] COMMAND_IDS=48'h060504030201,
 parameter [119:0] PHRASE_IDS=120'h1817161514131211100f0e0d0c0b0a,
 parameter [63:0] FRAME_TIMEOUT_US=20000,
 parameter [63:0] REPEAT_GAP_US=300000,SPEECH_GAP_US=5000000
)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire rx_valid,rx_error,input wire [7:0] rx_data,
 output reg cmd_valid,output reg [2:0] cmd,
 input wire phrase_valid,input wire [7:0] phrase_id,input wire invalidate,
 output wire tx_valid,output wire [7:0] tx_data,input wire tx_ready,
 output reg [31:0] rejected
);
 // Packed maps put logical command 1 / phrase 10 in the low byte.
 // Any byte value is legal, including protocol delimiter bytes.
 // A duplicate within either map disables the entire profile. IDs may repeat
 // across the two maps: their frame TYPE fields distinguish the directions.
 function profile_unique;
  input [47:0] commands;input [119:0] phrases;integer a,b;
  begin
   profile_unique=1'b1;
   for(a=0;a<6;a=a+1)for(b=a+1;b<6;b=b+1)
    if(commands[a*8+:8]==commands[b*8+:8])profile_unique=1'b0;
   for(a=0;a<15;a=a+1)for(b=a+1;b<15;b=b+1)
    if(phrases[a*8+:8]==phrases[b*8+:8])profile_unique=1'b0;
  end
 endfunction
 localparam PROFILE_VALID=profile_unique(COMMAND_IDS,PHRASE_IDS);
 wire profile_enabled=PROFILE_READY&&PROFILE_VALID;
 function [2:0] logical_command;
  input [7:0] module_id;integer n;
  begin
   logical_command=0;
   for(n=0;n<6;n=n+1)
    if(module_id==COMMAND_IDS[n*8+:8])logical_command=n+1;
  end
 endfunction
 reg [2:0] state;reg [7:0] kind,id,last_cmd;reg [63:0] last_rx,last_accept,next_speech;
 wire [2:0] decoded_cmd=logical_command(id);
 wire phrase_known=phrase_id>=8'd10&&phrase_id<=8'd24;
 wire [7:0] mapped_phrase=phrase_known ? PHRASE_IDS[(phrase_id-8'd10)*8+:8] : 8'd0;
 reg have_cmd,pending,sending;reg [7:0] pending_id,send_id;reg [2:0] send_index;
 assign tx_valid=profile_enabled&&sending;
 assign tx_data=send_index==0?8'haa:send_index==1?8'h55:send_index==2?8'hff:send_index==3?send_id:8'hfb;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=0;kind<=0;id<=0;last_cmd<=0;last_rx<=0;last_accept<=0;next_speech<=0;have_cmd<=0;
   pending<=0;sending<=0;pending_id<=0;send_id<=0;send_index<=0;cmd_valid<=0;cmd<=0;rejected<=0;
  end else begin
   cmd_valid<=0;
   if(rx_error||(state!=0&&(now_us<last_rx||now_us-last_rx>FRAME_TIMEOUT_US)))begin state<=0;rejected<=rejected+1'b1;end
   else if(rx_valid)begin
    last_rx<=now_us;
    case(state)
     0:if(rx_data==8'haa)state<=1;
     1:if(rx_data==8'h55)state<=2;else state<=rx_data==8'haa ? 1:0;
     2:begin kind<=rx_data;state<=3;end
     3:begin id<=rx_data;state<=4;end
     4:begin
      state<=rx_data==8'haa ? 1:0;
      if(profile_enabled&&rx_data==8'hfb&&kind==0&&decoded_cmd!=0&&
       (!have_cmd||id!=last_cmd||now_us>=last_accept&&now_us-last_accept>=REPEAT_GAP_US))begin
       cmd_valid<=1;cmd<=decoded_cmd;last_cmd<=id;last_accept<=now_us;have_cmd<=1;
      end else rejected<=rejected+1'b1;
     end
     default:state<=0;
    endcase
   end
   if(invalidate)pending<=0;
   // Latest relevant phrase replaces unsent old phrases; in-flight five-byte
   // packet is completed. There is no claimed playback-complete acknowledgement.
   if(phrase_valid&&profile_enabled&&phrase_known&&!invalidate)begin pending<=1;pending_id<=mapped_phrase;end
   if(!sending&&pending&&!invalidate&&!phrase_valid&&now_us>=next_speech)begin
    sending<=1;send_index<=0;send_id<=pending_id;pending<=0;
   end
   if(sending&&tx_ready)begin
    if(send_index==4)begin sending<=0;next_speech<=now_us+SPEECH_GAP_US;end
    else send_index<=send_index+1'b1;
   end
  end
 end
endmodule
`default_nettype wire

