`timescale 1ns/1ps
`default_nettype none
// CI1302/YB-MAD01 custom profile: RX AA 55 00 C1..C8 FB,
// TX AA 55 FF D0..E8 FB. The supplied factory profile is not this profile.
// Runtime enabled is deliberately not a compile-time parameter.
module qy_peripheral_voice #(
 parameter [63:0] FRAME_TIMEOUT_US=20000,
 parameter [63:0] REPEAT_GAP_US=300000,
 // Conservative start spacing for the longest fixed sentence. Actual audio
 // duration still needs module measurement; no playback-complete ACK exists.
 parameter [63:0] SPEECH_GAP_US=12000000
)(
 input wire clk,rst_n,input wire [63:0] now_us,input wire enabled,
 input wire rx_valid,rx_error,input wire [7:0] rx_data,
 output reg cmd_valid,output reg [3:0] cmd,
 input wire phrase_valid,input wire [7:0] phrase_id,input wire invalidate,
 output wire tx_valid,output wire [7:0] tx_data,input wire tx_ready,
 output wire speech_busy,output reg [31:0] rejected
);
 reg enabled_d;
 wire context_clear=invalidate||(enabled!=enabled_d)||!enabled;
 reg [2:0] rx_state;
 reg [7:0] rx_kind,rx_id,last_cmd;
 reg [63:0] last_rx,last_accept,last_speech;
 reg have_cmd,have_speech;
 wire command_known=rx_id>=8'hc1&&rx_id<=8'hc8;
 wire phrase_known=phrase_id>=8'hd0&&phrase_id<=8'he8;
 wire repeat_allowed=!have_cmd||rx_id!=last_cmd||
     (now_us>=last_accept&&now_us-last_accept>=REPEAT_GAP_US);
 wire speech_allowed=!have_speech||
     (now_us>=last_speech&&now_us-last_speech>=SPEECH_GAP_US);
 reg pending,sending;
 reg [7:0] pending_id,send_id;
 reg [2:0] send_index;

 // Until the first AA byte is accepted the frame is still cancellable.
 // Once accepted, every remaining byte survives disable/invalidate. The UART
 // must use global reset, not enabled, so its final serial byte is not cut off.
 assign tx_valid=sending&&((send_index!=0)||!context_clear);
 assign tx_data=send_index==0?8'haa:send_index==1?8'h55:
                send_index==2?8'hff:send_index==3?send_id:8'hfb;
 // This is queue/transport occupancy, not an audio-playback acknowledgement.
 assign speech_busy=pending||sending;

 always @(posedge clk)begin
  if(!rst_n)begin
   enabled_d<=0;rx_state<=0;rx_kind<=0;rx_id<=0;last_cmd<=0;
   last_rx<=0;last_accept<=0;last_speech<=0;have_cmd<=0;have_speech<=0;
   pending<=0;sending<=0;pending_id<=0;send_id<=0;send_index<=0;
   cmd_valid<=0;cmd<=0;rejected<=0;
  end else begin
   enabled_d<=enabled;
   cmd_valid<=0;
   if(context_clear)begin
    rx_state<=0;have_cmd<=0;pending<=0;
    if(send_index==0)sending<=0;
   end else begin
    if(rx_error)begin
     rx_state<=0;rejected<=rejected+1'b1;
    end else if(rx_state!=0&&
       (now_us<last_rx||now_us-last_rx>FRAME_TIMEOUT_US))begin
     // A new header arriving exactly when the old packet expires must not
     // be lost; no old type/id field can reach the command output.
     rx_state<=rx_valid&&rx_data==8'haa ? 1:0;
     if(rx_valid)last_rx<=now_us;
     rejected<=rejected+1'b1;
    end else if(rx_valid)begin
     last_rx<=now_us;
     case(rx_state)
      0:if(rx_data==8'haa)rx_state<=1;
      1:if(rx_data==8'h55)rx_state<=2;
        else rx_state<=rx_data==8'haa ? 1:0;
      2:begin rx_kind<=rx_data;rx_state<=3;end
      3:begin rx_id<=rx_data;rx_state<=4;end
      4:begin
       // A malformed trailer AA may also be the next packet's header.
       rx_state<=rx_data==8'haa ? 1:0;
       if(rx_data==8'hfb&&rx_kind==0&&command_known&&repeat_allowed)begin
        cmd_valid<=1;cmd<=rx_id-8'hc0;last_cmd<=rx_id;
        last_accept<=now_us;have_cmd<=1;
       end else rejected<=rejected+1'b1;
      end
      default:rx_state<=0;
     endcase
    end
    // One replaceable pending entry prevents stale speech backlogs.
    if(phrase_valid&&phrase_known)begin
     if(sending&&send_index==0)begin send_id<=phrase_id;pending<=0;end
     else begin pending<=1;pending_id<=phrase_id;end
    end
    if(!sending&&pending&&!phrase_valid&&speech_allowed)begin
     sending<=1;send_index<=0;send_id<=pending_id;pending<=0;
    end
   end
   if(tx_valid&&tx_ready)begin
    if(send_index==4)begin
     sending<=0;send_index<=0;last_speech<=now_us;have_speech<=1;
    end else send_index<=send_index+1'b1;
   end
  end
 end
endmodule
`default_nettype wire
