`timescale 1ns/1ps
module tb_actions;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0;reg [63:0] now_us=0;
 reg game_active=0,replay_active=0,settings_active=0,storage_busy=0,storage_intercept=0;
 reg physical_key=0,card_valid=0,voice_cmd_valid=0;
 reg [1:0] card_action=0;reg [3:0] voice_cmd=0;
 reg camera_ready=1,calibrated=1,paused=0,fault=0,game_over=0,draw=0,target_valid=0;
 reg [7:0] target_index=0;reg [2:0] mode=0;reg [3:0] phase=3;
 reg [1:0] next_color=1,human_color=1,winner=0;
 reg event_valid=0;reg [1:0] event_color=1;
 reg [3:0] coach_fact=0;reg coach_uncertain=0,coach_answer_valid=0,coach_answer_correct=0;
 reg navigation_done=0,navigation_is_replay=0,navigation_home=0;
 wire navigate_valid,navigate_replay,home_request,request_valid,phrase_valid,speech_cancel;
 wire [2:0] request;wire [7:0] phrase_id;wire [4:0] notice;wire notice_toggle;
 integer checks=0,failures=0;
 qy_peripheral_actions #(.NOTICE_US(100)) dut(.*);
 task tick;begin @(posedge clk);#1;now_us=now_us+1;end endtask
 task check;input condition;input [1023:0] message;begin
  checks=checks+1;if(condition!==1'b1)begin failures=failures+1;$display("FAIL actions %0s",message);end
 end endtask
 task stable;begin repeat(4)tick;end endtask
 task command;input [3:0] value;begin @(negedge clk);voice_cmd=value;voice_cmd_valid=1;tick;@(negedge clk);voice_cmd_valid=0;end endtask
 task reset_case;begin
  @(negedge clk);rst_n=0;game_active=0;replay_active=0;settings_active=0;storage_busy=0;storage_intercept=0;
  physical_key=0;card_valid=0;voice_cmd_valid=0;camera_ready=1;calibrated=1;paused=0;fault=0;game_over=0;
  target_valid=0;target_index=0;mode=0;phase=3;next_color=1;human_color=1;event_valid=0;coach_fact=0;coach_uncertain=0;
  navigation_done=0;navigation_home=0;navigation_is_replay=0;coach_answer_valid=0;repeat(3)tick;
  @(negedge clk);rst_n=1;game_active=1;stable;
 end endtask
 initial begin
  reset_case;
  command(6);check(!phrase_valid,"phrase is staged one clock");
  phase=5;#1;check(speech_cancel,"phase cancellation is visible before the sampling edge");tick;check(!phrase_valid,"phase change cancels staged human-turn phrase");stable;
  phase=3;stable;command(6);next_color=2;#1;check(speech_cancel,"turn cancellation is visible before the sampling edge");tick;check(!phrase_valid,"turn change cancels staged phrase");stable;
  next_color=1;stable;command(6);physical_key=1;tick;check(!phrase_valid&&speech_cancel,"physical key cancels queued speech");physical_key=0;stable;
  command(4);check(request_valid&&request==3,"pause requests target state");mode=4;paused=1;stable;
  command(4);check(!request_valid,"repeated pause does not toggle");tick;check(phrase_valid&&phrase_id==8'hd2,"repeated pause reports actual paused state");stable;
  command(5);check(request_valid&&request==4,"resume requests target state");mode=0;paused=0;stable;
  command(5);check(!request_valid,"repeated resume does not toggle");tick;check(phrase_valid&&phrase_id==8'hd3,"repeated resume reports actual running state");stable;
  command(1);check(request_valid&&request==1,"game request only asks for confirmation");tick;
`ifndef BASELINE
  check(!phrase_valid,"new game announcement waits for real confirmation mode");
`endif
  mode=3;stable;check(!request_valid,"new game request is one clock");mode=0;stable;
  physical_key=1;command(1);check(!request_valid&&!navigate_valid,"physical key wins command collision");physical_key=0;stable;
  command(2);check(request_valid&&request==2,"safe human turn requests hint");stable;
  phase=5;stable;command(2);check(!request_valid,"AI turn rejects teaching");tick;check(phrase_valid&&phrase_id==8'hdc,"teaching rejection has feedback");phase=3;stable;
  coach_uncertain=1;stable;command(2);check(!request_valid,"uncertain visual identity rejects teaching");coach_uncertain=0;stable;
  coach_fact=1;tick;tick;check(phrase_valid&&phrase_id==8'hd9,"fresh certified hint emits fixed phrase");stable;
  command(3);tick;check(phrase_valid&&phrase_id==8'hd9,"current certified hint can repeat");stable;
  event_valid=1;event_color=1;tick;event_valid=0;tick;check(phrase_valid&&phrase_id==8'hd7,"real visual event announces confirmed color");stable;
  command(3);tick;check(phrase_valid&&phrase_id==8'he7,"real move expires old repeat hint");stable;
  target_valid=1;target_index=10;tick;target_index=11;tick;
`ifndef BASELINE
  check(!phrase_valid,"changed valid AI coordinate cancels old queued target");
`endif
  stable;target_valid=0;stable;
  storage_busy=1;stable;command(7);check(!navigate_valid&&!home_request&&!request_valid,"storage busy rejects navigation");storage_busy=0;stable;
  check(!navigate_valid&&!home_request,"rejected busy navigation never replays");
  settings_active=1;stable;command(8);check(!home_request,"settings rejects voice home request");settings_active=0;stable;
`ifndef BASELINE
  game_active=0;replay_active=1;storage_intercept=1;stable;
  command(8);check(home_request,"idle read-only history allows home despite page intercept");stable;
  command(7);check(navigate_valid&&navigate_replay,"idle history may reselect its entrance");stable;
  command(1);check(navigate_valid&&!navigate_replay&&!request_valid,"idle history can select game entrance without resetting board");stable;
  storage_busy=1;stable;command(8);check(!home_request,"in-flight history load blocks home");stable;
  command(7);check(!navigate_valid,"in-flight history load blocks navigation");storage_busy=0;
  game_active=1;replay_active=0;storage_intercept=0;stable;
`endif
  command(7);check(navigate_valid&&navigate_replay&&!request_valid,"history only selects read-only entrance");tick;
`ifndef BASELINE
  check(!phrase_valid,"history announcement waits for actual menu apply");
  navigation_done=1;navigation_is_replay=1;game_active=0;tick;navigation_done=0;tick;
  check(phrase_valid&&phrase_id==8'hd1,"history announcement follows acknowledged menu transition");stable;
  command(8);check(home_request,"home command is a request only");tick;check(!phrase_valid,"home request does not claim completion early");
  navigation_done=1;navigation_home=1;tick;navigation_done=0;tick;check(phrase_valid&&phrase_id==8'he1,"home acknowledgment drives preserved-game phrase");stable;
`endif
  card_valid=1;card_action=0;tick;card_valid=0;check(!navigate_valid&&!request_valid,"invalid card action has no transition");stable;
  game_active=1;stable;
  fault=1;tick;tick;check(phrase_valid&&phrase_id==8'hdf,"actual fault transition reports fault");stable;
  camera_ready=0;tick;tick;check(phrase_valid&&phrase_id==8'he0,"camera-loss transition reports unavailable camera");
  repeat(105)tick;check(notice==0,"notice deadline expires independently");
  if(failures)begin $display("FAIL_ACTIONS checks=%0d failures=%0d",checks,failures);$fatal(1);end
  $display("PASS_ACTIONS checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"actions watchdog");end
endmodule
