`timescale 1ns/1ps
`default_nettype none
// Runtime-only peripheral configuration. No game state or move output exists.
module qy_peripheral_settings #(
 parameter [63:0] LEARN_US=30000000,NOTICE_US=4000000
)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire settings_active,input wire [3:0] key_press,
 input wire uid_valid,input wire [79:0] uid,input wire [3:0] uid_length,
 input wire card_present,nfc_ready,nfc_fault,
 input wire config_initialized,config_valid,input wire [255:0] config_data,
 input wire [7:0] config_error,
 output reg save_valid,output wire [255:0] save_data,input wire save_ready,
 input wire done_valid,output wire done_ready,input wire [7:0] done_error,
 output wire [239:0] card_uids,output wire [11:0] card_lengths,output wire [2:0] card_enabled,
 output reg voice_enabled,nfc_restart,output reg card_valid,output reg [1:0] card_action,
 output reg [2:0] selection,output reg learning,voice_confirm,saving,dirty,
 output reg [4:0] notice,output reg notice_toggle,output wire busy
);
 reg [239:0] uids;reg [11:0] lengths;reg [2:0] enabled;
 reg loaded,settings_d;reg [63:0] learn_deadline,notice_deadline;
 reg [255:0] save_snapshot;
 assign card_uids=uids;assign card_lengths=lengths;assign card_enabled=enabled;
 assign save_data=save_snapshot;assign done_ready=saving&&!save_valid;
 assign busy=saving;
 function legal_length(input [3:0] n);begin legal_length=n==4||n==7||n==10;end endfunction
 function [79:0] canonical(input [79:0] value,input [3:0] n);
  integer k;begin canonical=0;for(k=0;k<10;k=k+1)if(k<n)canonical[k*8+:8]=value[k*8+:8];end
 endfunction
 function good_config(input [255:0] value);
  integer a,b;begin
   good_config=1;
   for(a=0;a<3;a=a+1)if(value[252+a])begin
    if(!legal_length(value[240+a*4+:4]))good_config=0;
    for(b=0;b<a;b=b+1)if(value[252+b]&&value[240+a*4+:4]==value[240+b*4+:4]&&
     canonical(value[a*80+:80],value[240+a*4+:4])==canonical(value[b*80+:80],value[240+b*4+:4]))good_config=0;
   end
  end
 endfunction
 reg [79:0] captured_uid;reg [3:0] captured_length;reg capture_learning;
 reg [1:0] capture_slot;reg [1:0] check_stage;reg [2:0] match;
 wire any_key=|key_press;
 task tell(input [4:0] message);
  begin notice<=message;notice_toggle<=!notice_toggle;notice_deadline<=now_us+NOTICE_US;end
 endtask
 // notice: 0 none,1 tap,2 remove,3 registered,4 duplicate,5 timeout,
 // 6 unknown,7 enabled,8 disabled,9 saved,10 save error,11 retry,
 // 12 waiting init,13 invalid stored config,14 need NFC,15 invalid UID.
 always @(posedge clk)begin
  if(!rst_n)begin
   uids<=0;lengths<=0;enabled<=0;voice_enabled<=0;loaded<=0;settings_d<=0;
   selection<=0;learning<=0;voice_confirm<=0;saving<=0;dirty<=0;
   save_valid<=0;save_snapshot<=0;nfc_restart<=0;card_valid<=0;card_action<=0;
   notice<=0;notice_toggle<=0;learn_deadline<=0;notice_deadline<=0;captured_uid<=0;captured_length<=0;
   capture_learning<=0;capture_slot<=0;check_stage<=0;match<=0;
  end else begin
   nfc_restart<=0;card_valid<=0;settings_d<=settings_active;
   if(notice!=0&&now_us>=notice_deadline)notice<=0;
   if(config_initialized&&!loaded)begin
    loaded<=1;
    if(config_valid&&good_config(config_data))begin
     uids<=config_data[239:0];lengths<=config_data[251:240];enabled<=config_data[254:252];voice_enabled<=config_data[255];
    end else if(config_valid||config_error!=0)tell(13);
   end
   if(settings_d!=settings_active)begin
    learning<=0;voice_confirm<=0;check_stage<=0;
    if(!settings_d&&settings_active)begin selection<=0;notice<=0;end
   end
   if(learning&&now_us>=learn_deadline)begin learning<=0;tell(5);end
   if(save_valid&&save_ready)save_valid<=0;
   if(done_valid&&done_ready)begin
    saving<=0;
    if(done_error==0)begin dirty<=0;tell(9);end else tell(10);
   end
   // A physical action wins over the complete in-flight card comparison,
   // including outside this page; do not defer its event until the key ends.
   if(any_key)check_stage<=0;
   if(settings_active&&settings_d&&!saving&&loaded&&any_key)begin
    check_stage<=0;
    if(key_press[0])begin learning<=0;voice_confirm<=0;end
    else if(key_press[1]||key_press[2])begin
     learning<=0;voice_confirm<=0;
     if(key_press[1]&&!key_press[2])selection<=selection==0?3'd5:selection-1'b1;
     else if(key_press[2]&&!key_press[1])selection<=selection==5?3'd0:selection+1'b1;
    end else if(key_press[3])begin
     if(selection<3)begin
      if(nfc_ready&&!nfc_fault)begin learning<=1;voice_confirm<=0;learn_deadline<=now_us+LEARN_US;tell(card_present?5'd2:5'd1);end
      else tell(14);
     end else if(selection==3)begin
      learning<=0;
      if(voice_enabled)begin voice_enabled<=0;dirty<=1;voice_confirm<=0;tell(8);end
      else if(voice_confirm)begin voice_enabled<=1;dirty<=1;voice_confirm<=0;tell(7);end
      else begin voice_confirm<=1;notice<=0;end
     end else if(selection==4)begin learning<=0;voice_confirm<=0;nfc_restart<=1;tell(11);end
     else begin
      learning<=0;voice_confirm<=0;saving<=1;save_valid<=1;
      save_snapshot<={voice_enabled,enabled,lengths,uids};notice<=0;
     end
    end
   end else if(settings_active&&!loaded&&any_key)tell(12);
   // Pipeline comparisons of three fixed 80-bit UIDs. Inputs remain stable
   // through both stages, and a configuration/page action cancels the result.
   if(uid_valid&&check_stage==0&&loaded&&!saving&&!any_key&&settings_d==settings_active)begin
    if(legal_length(uid_length))begin
     captured_uid<=canonical(uid,uid_length);captured_length<=uid_length;
     capture_learning<=settings_active&&learning;capture_slot<=selection[1:0];check_stage<=1;
    end else tell(15);
   end else if(check_stage==1&&!any_key&&settings_d==settings_active)begin
    match[0]<=enabled[0]&&lengths[3:0]==captured_length&&canonical(uids[79:0],lengths[3:0])==captured_uid;
    match[1]<=enabled[1]&&lengths[7:4]==captured_length&&canonical(uids[159:80],lengths[7:4])==captured_uid;
    match[2]<=enabled[2]&&lengths[11:8]==captured_length&&canonical(uids[239:160],lengths[11:8])==captured_uid;
    check_stage<=2;
   end else if(check_stage==2&&!any_key&&settings_d==settings_active)begin
    check_stage<=0;
    if(capture_learning)begin
     if(settings_active&&learning&&selection==capture_slot&&now_us<learn_deadline)begin
      if((match&~(3'b001<<capture_slot))!=0)tell(4);
      else begin
       case(capture_slot)
        0:begin uids[79:0]<=captured_uid;lengths[3:0]<=captured_length;enabled[0]<=1;end
        1:begin uids[159:80]<=captured_uid;lengths[7:4]<=captured_length;enabled[1]<=1;end
        2:begin uids[239:160]<=captured_uid;lengths[11:8]<=captured_length;enabled[2]<=1;end
       endcase
       learning<=0;dirty<=1;tell(3);
      end
     end
    end else if(!settings_active)begin
     case(match)
      1:begin card_valid<=1;card_action<=1;end
      2:begin card_valid<=1;card_action<=2;end
      4:begin card_valid<=1;card_action<=3;end
      default:tell(6);
     endcase
    end
   end
  end
 end
endmodule
`default_nettype wire
