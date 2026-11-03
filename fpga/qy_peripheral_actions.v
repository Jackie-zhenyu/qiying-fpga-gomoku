`timescale 1ns/1ps
`default_nettype none
// This adapter can request UI transitions; it has no path to a move-commit port.
module qy_peripheral_actions #(
 parameter [63:0] NOTICE_US=4000000
)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire game_active,replay_active,settings_active,storage_busy,storage_intercept,
 input wire physical_key,input wire card_valid,input wire [1:0] card_action,
 input wire voice_cmd_valid,input wire [3:0] voice_cmd,
 input wire navigation_done,navigation_is_replay,navigation_home,
 input wire camera_ready,calibrated,paused,fault,game_over,draw,target_valid,
 input wire [7:0] target_index,
 input wire [2:0] mode,input wire [3:0] phase,
 input wire [1:0] next_color,human_color,winner,
 input wire event_valid,input wire [1:0] event_color,
 input wire [3:0] coach_fact,input wire coach_uncertain,coach_answer_valid,coach_answer_correct,
 output reg navigate_valid,navigate_replay,home_request,
 output reg request_valid,output reg [2:0] request,
 output reg phrase_valid,output reg [7:0] phrase_id,output wire speech_cancel,
 output reg [4:0] notice,output reg notice_toggle
);
 wire command_valid=card_valid||voice_cmd_valid;
 wire [3:0] command=card_valid?(card_action==1?4'd1:card_action==2?4'd2:card_action==3?4'd7:4'd0):voice_cmd;
 wire allowed=game_active&&!settings_active&&!storage_intercept&&!storage_busy;
 wire human_turn=phase==3&&next_color==human_color;
 wire hint_allowed=allowed&&mode==0&&human_turn&&!paused&&camera_ready&&calibrated&&!fault&&!coach_uncertain&&!game_over;
 reg game_d,replay_d,settings_d,fault_d,camera_d,over_d,target_d;
 reg calibrated_d,paused_d,uncertain_d,storage_busy_d,storage_intercept_d;
 reg [2:0] mode_d;reg [3:0] fact_d,phase_d;
 reg [1:0] next_d,human_d;reg [7:0] target_index_d;
 reg last_hint_valid;reg [7:0] last_hint;
 reg generated_valid;reg [7:0] generated_phrase;
 reg cancel_pending,speech_sensitive;
 reg [63:0] notice_deadline;
 wire page_change=game_d!=game_active||replay_d!=replay_active||settings_d!=settings_active;
 wire hard_context_change=page_change||mode_d!=mode||event_valid||fault_d!=fault||camera_d!=camera_ready||
  over_d!=game_over||calibrated_d!=calibrated||paused_d!=paused||
  storage_busy_d!=storage_busy||storage_intercept_d!=storage_intercept;
 wire soft_context_change=phase_d!=phase||next_d!=next_color||human_d!=human_color||
  uncertain_d!=coach_uncertain||fact_d!=coach_fact||target_d!=target_valid||
  (target_valid&&target_index_d!=target_index);
 wire context_change=hard_context_change||soft_context_change;
 // A confirmed move/answer remains true while the game advances through
 // WAIT_RULES/SELECT_TURN. Hints, targets and turn queries are state-sensitive.
 wire generated_confirmed=generated_phrase==8'hd7||generated_phrase==8'hd8||
  generated_phrase==8'hdd||generated_phrase==8'hde;
 wire emit_generated=generated_valid&&!physical_key&&!hard_context_change&&
  (!soft_context_change||generated_confirmed);
 // The voice engine may accept its first AA on this same edge. Include the
 // current comparison directly, then retain one flush cycle after it, so an
 // unsent old frame cannot start before a registered cancel reaches it.
 assign speech_cancel=rst_n&&(hard_context_change||(soft_context_change&&speech_sensitive)||physical_key||cancel_pending);
 // notice 16 new game request,17 history request,18 cannot teach,
 // 19 unavailable/busy,20 no repeat,21 home requested.
 task say(input [7:0] value);
  begin generated_valid<=1;generated_phrase<=value;end
 endtask
 task tell(input [4:0] value);
  begin notice<=value;notice_toggle<=!notice_toggle;notice_deadline<=now_us+NOTICE_US;end
 endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   navigate_valid<=0;navigate_replay<=0;home_request<=0;request_valid<=0;request<=0;
   phrase_valid<=0;phrase_id<=0;generated_valid<=0;generated_phrase<=0;cancel_pending<=0;speech_sensitive<=1;notice<=0;notice_toggle<=0;notice_deadline<=0;
   game_d<=0;replay_d<=0;settings_d<=0;fault_d<=0;camera_d<=0;over_d<=0;target_d<=0;
   calibrated_d<=0;paused_d<=0;uncertain_d<=0;storage_busy_d<=0;storage_intercept_d<=0;
   mode_d<=1;fact_d<=0;phase_d<=0;next_d<=0;human_d<=0;target_index_d<=0;last_hint_valid<=0;last_hint<=0;
  end else begin
   navigate_valid<=0;home_request<=0;request_valid<=0;
   phrase_valid<=emit_generated;phrase_id<=generated_phrase;generated_valid<=0;cancel_pending<=hard_context_change||physical_key;
   if(hard_context_change||physical_key)speech_sensitive<=1;
   else if(emit_generated)speech_sensitive<=!generated_confirmed;
   game_d<=game_active;replay_d<=replay_active;settings_d<=settings_active;fault_d<=fault;
   camera_d<=camera_ready;over_d<=game_over;target_d<=target_valid;mode_d<=mode;fact_d<=coach_fact;
   calibrated_d<=calibrated;paused_d<=paused;uncertain_d<=coach_uncertain;phase_d<=phase;next_d<=next_color;human_d<=human_color;
   storage_busy_d<=storage_busy;storage_intercept_d<=storage_intercept;target_index_d<=target_index;
   if(notice!=0&&now_us>=notice_deadline)notice<=0;
   if(context_change||!hint_allowed)last_hint_valid<=0;
   // context changes first cancel the old queue; announcements below are
   // emitted on the following stable cycle via pending_phrase.
   if(game_active&&!settings_active)begin
    if(fault&&!fault_d)say(8'hdf);
    else if(!camera_ready&&camera_d)say(8'he0);
    else if(game_over&&!over_d)say(draw?8'he4:winner==1?8'he2:8'he3);
    else if(mode==3&&mode_d!=3)say(8'hd0);
    else if(mode==4&&mode_d!=4)say(8'hd2);
    else if(mode==0&&mode_d==4)say(8'hd3);
    else if(coach_answer_valid)say(coach_answer_correct?8'hdd:8'hde);
    else if(event_valid)say(event_color==1?8'hd7:8'hd8);
    else if(target_valid&&(!target_d||target_index!=target_index_d)&&allowed&&mode==0&&
      camera_ready&&calibrated&&!fault&&!game_over&&!paused)say(8'hd6);
    else if(hint_allowed&&coach_fact!=fact_d)begin
     case(coach_fact)
      1:begin say(8'hd9);last_hint<=8'hd9;last_hint_valid<=1;end
      2:begin say(8'hda);last_hint<=8'hda;last_hint_valid<=1;end
      3:begin say(8'he8);last_hint<=8'he8;last_hint_valid<=1;end
      4:begin say(8'hdb);last_hint<=8'hdb;last_hint_valid<=1;end
     endcase
    end
   end
   // The menu acknowledges only after its frame-boundary transition has
   // committed. Cancelled or rejected requests must never claim completion.
   if(navigation_done)begin
    if(navigation_home)begin tell(21);say(8'he1);end
    else if(navigation_is_replay)begin tell(17);say(8'hd1);end
    else begin tell(16);say(8'hd0);end
   end
   if(command_valid&&!physical_key&&!page_change&&!context_change)begin
    // History keeps intercept asserted for its whole page, including idle
    // selection/view. Navigation may leave that read-only page once the actual
    // storage transaction is idle; gameplay requests remain intercepted.
    if(storage_busy||settings_active||(storage_intercept&&command!=7&&command!=8&&
       !(command==1&&!game_active)))begin tell(19);say(8'he5);end
    else case(command)
     1:begin
      if(game_active)begin
       if(mode==0||mode==4)begin request_valid<=1;request<=1;tell(16);end
       else begin tell(16);say(8'he6);end
      end else begin navigate_valid<=1;navigate_replay<=0;end
     end
     2:begin
      if(hint_allowed)begin request_valid<=1;request<=2;end
      else begin tell(18);say(8'hdc);end
     end
     3:begin if(last_hint_valid&&hint_allowed)say(last_hint);else begin tell(20);say(8'he7);end end
     4:begin
      if(allowed&&mode==0)begin request_valid<=1;request<=3;end
      else if(allowed&&mode==4)say(8'hd2);
      else begin tell(19);say(8'he5);end
     end
     5:begin
      if(allowed&&mode==4&&camera_ready&&!fault)begin request_valid<=1;request<=4;end
      else if(allowed&&mode==0)say(8'hd3);
      else begin tell(19);say(!camera_ready?8'he0:8'he6);end
     end
     6:begin
      if(!game_active)say(8'he6);
      else if(fault)say(8'hdf);
      else if(!camera_ready)say(8'he0);
      else if(mode==4)say(8'hd2);
      else if(mode!=0||!calibrated)say(8'he6);
      else if(game_over)say(draw?8'he4:winner==1?8'he2:8'he3);
      else if(target_valid)say(8'hd6);
      else say(next_color==1?8'hd4:8'hd5);
     end
     7:begin navigate_valid<=1;navigate_replay<=1;end
     8:begin home_request<=1;end
     default:begin end
    endcase
   end
  end
 end
endmodule
`default_nettype wire
