`timescale 1ns/1ps
module tb_menu;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,frame_tick=0,lock_exit=0,navigate_valid=0,navigate_replay=0,home_request=0;
 reg [3:0] keys_n=15;
 wire game_active,replay_active,settings_active,physical_key;
 wire [0:0] selected;wire [3:0] game_press,game_held,settings_press;
 wire navigation_done,navigation_home;
 integer checks=0,failures=0;
 qy_function_menu #(.CLK_HZ(1000),.DEBOUNCE_MS(1),.RETURN_MS(30)) dut(.*);
 task tick;begin @(posedge clk);#1;end endtask
 task check;input condition;input [1023:0] message;begin checks=checks+1;if(condition!==1'b1)begin failures=failures+1;$display("FAIL menu %0s state=%0d",message,dut.state);end end endtask
 task reset_case;begin @(negedge clk);rst_n=0;keys_n=15;frame_tick=0;lock_exit=0;navigate_valid=0;home_request=0;repeat(4)tick;rst_n=1;repeat(12)tick;end endtask
 task key;input [3:0] value;begin @(negedge clk);keys_n=~value;repeat(10)tick;@(negedge clk);keys_n=15;repeat(10)tick;end endtask
 task frame;begin @(negedge clk);frame_tick=1;tick;@(negedge clk);frame_tick=0;tick;end endtask
 task nav;input replay;begin @(negedge clk);navigate_valid=1;navigate_replay=replay;tick;@(negedge clk);navigate_valid=0;tick;end endtask
 initial begin
  reset_case;key(8);check(!game_active&&!replay_active,"entry waits for frame boundary");
  nav(1);frame;check(game_active&&!replay_active,"physical selected entry commits");frame;
  check(game_active&&!replay_active,"navigation during enter-release is discarded, never replays later");
  reset_case;nav(1);check(!game_active&&!replay_active,"voice history never enters app");frame;check(selected==1&&!game_active&&!replay_active,"history navigation selects entrance only");
  key(8);frame;check(replay_active&&!game_active,"history requires physical KEY4");
  lock_exit=1;home_request=1;tick;home_request=0;frame;check(replay_active,"storage lock refuses home");lock_exit=0;frame;check(replay_active,"refused home never replays");
  nav(0);lock_exit=1;tick;lock_exit=0;frame;check(replay_active,"new busy lock cancels pending navigation");
  home_request=1;tick;home_request=0;frame;check(!game_active&&!replay_active,"accepted home commits at frame");
  reset_case;key(1);check(!settings_active,"settings entry waits for frame");frame;check(settings_active&&!game_active&&!replay_active,"physical KEY1 enters settings");
  nav(1);frame;check(settings_active,"voice navigation cannot leave settings");
  @(negedge clk);keys_n=14;repeat(10)tick;
`ifndef BASELINE
  check(settings_active,"settings return waits for vertical blank");
`endif
  frame;check(!settings_active,"settings physical return commits at frame");keys_n=15;repeat(10)tick;
  reset_case;nav(1);keys_n=7;repeat(10)tick;frame;check(!replay_active&&selected==0,"physical key cancels pending navigation");
  if(failures)begin $display("FAIL_MENU checks=%0d failures=%0d",checks,failures);$fatal(1);end
  $display("PASS_MENU checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"menu watchdog");end
endmodule
