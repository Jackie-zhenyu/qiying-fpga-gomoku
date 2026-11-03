`timescale 1ns/1ps
module tb_controls;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,camera_ready=1;reg [3:0] key_press=0,key_held=0;
 reg external_request_valid=0;reg [2:0] external_request=0;
 reg calibration_done=0,calibration_success=0;reg [7:0] move_count=7;
 wire paused,human_white,new_game_request,calibrate_request,setup_error,show_target,points_ready;
 wire [31:0] calibration_version,safety_epoch;wire [2872:0] nominal_points;wire [67:0] corners;
 wire [2:0] mode,field;wire [8:0] field_value;
 integer checks=0,failures=0;reg [31:0] epoch;
 qy_interaction_controls #(.CLK_HZ(1000),.AUTO_SIZE(1)) dut(.*);
 task tick;begin @(posedge clk);#1;end endtask
 task check;input condition;input [1023:0] message;begin checks=checks+1;if(condition!==1'b1)begin failures=failures+1;$display("FAIL controls %0s mode=%0d",message,mode);end end endtask
 task request;input [2:0] value;begin @(negedge clk);external_request=value;external_request_valid=1;tick;@(negedge clk);external_request_valid=0;end endtask
 task press;input [3:0] value;begin @(negedge clk);key_press=value;tick;@(negedge clk);key_press=0;tick;end endtask
 task enter_play;begin
  @(negedge clk);rst_n=0;key_press=0;key_held=0;external_request_valid=0;calibration_done=0;repeat(3)tick;
  @(negedge clk);rst_n=1;tick;check(mode==1,"boot requires setup");press(8);check(mode==5,"physical confirmation starts calibration");
  @(negedge clk);calibration_done=1;calibration_success=1;tick;check(mode==0&&new_game_request,"only successful visual calibration commits new-game pulse");
  @(negedge clk);calibration_done=0;tick;check(!new_game_request,"new-game pulse is one clock");
 end endtask
 initial begin
  enter_play;epoch=safety_epoch;key_held=8;request(3);check(mode==0&&safety_epoch==epoch,"held physical key blocks external pause");key_held=0;
  enter_play;request(3);check(mode==4&&paused&&!new_game_request,"external pause requests pause only");epoch=safety_epoch;
  request(3);check(mode==4&&safety_epoch==epoch,"repeated pause is idempotent");request(4);check(mode==0&&!paused,"external resume targets play");epoch=safety_epoch;
  request(4);check(mode==0&&safety_epoch==epoch,"repeated resume is idempotent");
  @(negedge clk);key_press=8;external_request=3;external_request_valid=1;tick;check(mode==0,"physical KEY4 wins same-cycle external pause");
  @(negedge clk);key_press=0;external_request_valid=0;tick;
  request(1);check(mode==3&&!new_game_request,"external new game only opens confirmation");
  request(1);request(2);request(3);request(4);check(mode==3&&!new_game_request&&!calibrate_request,"external requests cannot confirm new game");
  press(8);check(mode==1&&!new_game_request,"physical KEY4 confirms setup while formal game preserved");
  request(1);request(3);request(4);check(mode==1&&!calibrate_request,"external requests cannot calibrate from setup");
  enter_play;request(3);camera_ready=0;request(4);check(mode==4,"unready camera blocks external resume");camera_ready=1;
  key_held=2;request(4);check(mode==4,"held key blocks resume");key_held=0;request(4);check(mode==0,"fresh resume works when key released");
  if(failures)begin $display("FAIL_CONTROLS checks=%0d failures=%0d",checks,failures);$fatal(1);end
  $display("PASS_CONTROLS checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"controls watchdog");end
endmodule
