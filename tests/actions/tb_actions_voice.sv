`timescale 1ns/1ps
module tb_actions_voice;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0;reg [63:0] now_us=0;
 reg game_active=1,replay_active=0,settings_active=0,storage_busy=0,storage_intercept=0;
 reg physical_key=0,card_valid=0,voice_cmd_valid=0;reg [1:0] card_action=0;reg [3:0] voice_cmd=0;
 reg navigation_done=0,navigation_is_replay=0,navigation_home=0;
 reg camera_ready=1,calibrated=1,paused=0,fault=0,game_over=0,draw=0,target_valid=0;
 reg [7:0] target_index=0;reg [2:0] mode=0;reg [3:0] phase=3;reg [1:0] next_color=1,human_color=1,winner=0;
 reg event_valid=0;reg [1:0] event_color=1;reg [3:0] coach_fact=0;
 reg coach_uncertain=0,coach_answer_valid=0,coach_answer_correct=0;
 wire navigate_valid,navigate_replay,home_request,request_valid,phrase_valid,speech_cancel;
 wire [2:0] request;wire [7:0] phrase_id;wire [4:0] notice;wire notice_toggle;
 wire tx_valid;wire [7:0] tx_data;reg tx_ready=0;wire speech_busy;
 integer checks=0,failures=0,accepted=0,budget;reg [7:0] bytes[0:31];
 qy_peripheral_actions dut(.*);
 qy_peripheral_voice #(.SPEECH_GAP_US(0)) voice(.clk(clk),.rst_n(rst_n),.now_us(now_us),.enabled(1'b1),
  .rx_valid(1'b0),.rx_error(1'b0),.rx_data(8'd0),.cmd_valid(),.cmd(),
  .phrase_valid(phrase_valid),.phrase_id(phrase_id),.invalidate(speech_cancel),
  .tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready),.speech_busy(speech_busy),.rejected());
 always @(posedge clk)if(rst_n&&tx_valid&&tx_ready)begin bytes[accepted]=tx_data;accepted=accepted+1;end
 task tick;begin @(posedge clk);#1;now_us=now_us+1;end endtask
 task check;input condition;input [1023:0] message;begin checks=checks+1;if(condition!==1'b1)begin failures=failures+1;$display("FAIL actions_voice %0s",message);end end endtask
 task query;begin @(negedge clk);voice_cmd_valid=1;voice_cmd=6;tick;@(negedge clk);voice_cmd_valid=0;end endtask
 task wait_unsent;begin budget=0;while(!(voice.sending&&voice.send_index==0)&&budget<20)begin tick;budget=budget+1;end
  check(voice.sending&&voice.send_index==0,"real voice transport has an unsent queued frame");end endtask
 initial begin
  repeat(4)tick;@(negedge clk);rst_n=1;repeat(6)tick;
  query;wait_unsent;
  @(negedge clk);phase=5;tx_ready=1;tick;
  check(accepted==0,"state change cancels queued AA before same-edge UART acceptance");repeat(5)tick;
  check(!speech_busy&&accepted==0,"cancelled phrase has no later bytes");
  phase=3;tx_ready=0;repeat(5)tick;query;wait_unsent;
  @(negedge clk);tx_ready=1;tick;check(accepted==1&&bytes[0]==8'haa,"current phrase starts normally");
  @(negedge clk);phase=5;repeat(8)tick;
  check(accepted==5&&bytes[1]==8'h55&&bytes[2]==8'hff&&bytes[3]==8'hd4&&bytes[4]==8'hfb,"already-started frame completes all five bytes after context change");
  @(negedge clk);tx_ready=0;phase=3;repeat(5)tick;
  @(negedge clk);event_valid=1;event_color=2;phase=7;tick;
  @(negedge clk);event_valid=0;phase=2;tick;
  @(negedge clk);phase=5;tick;repeat(5)tick;tx_ready=1;repeat(10)tick;
  check(accepted==10&&bytes[8]==8'hd8,"real confirmed-move fact survives routine game phase progression");
  if(failures)begin $display("FAIL_ACTIONS_VOICE checks=%0d failures=%0d",checks,failures);$fatal(1);end
  $display("PASS_ACTIONS_VOICE checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"actions voice watchdog");end
endmodule
