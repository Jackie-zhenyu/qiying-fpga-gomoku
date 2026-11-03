`timescale 1ns/1ps
`default_nettype none
// KEY1 mode request; KEY2 hint; KEY3 pause/resume/cancel; KEY4 context action.
// Recalibration is deliberate: only while paused, hold KEY4 for two seconds.
module qy_teacher_controls #(parameter CLK_HZ=137500000)(
 input wire clk,rst_n,camera_ready,detector_calibrated,
 input wire [3:0] key_press,key_held,
 input wire [2:0] mode,pending_mode,input wire [3:0] stage,
 input wire calibration_done,calibration_success,
 output wire calibrated,output reg calibrating,setup_error,calibrate_request,
 output reg [31:0] calibration_version,safety_epoch,
 output reg command_valid,output reg [2:0] command,
 output reg mode_valid,output reg [2:0] requested_mode
);
 reg needs_calibration,camera_d,long_issued;reg [31:0] hold_count,cal_count;
 assign calibrated=camera_ready&&detector_calibrated&&!needs_calibration&&!calibrating;
 wire long_cal=stage==3&&key_held[3]&&!long_issued&&hold_count>=2*CLK_HZ-1;
 task begin_calibration;
  begin calibrating<=1;needs_calibration<=1;setup_error<=0;calibrate_request<=1;
   cal_count<=0;safety_epoch<=safety_epoch+1'b1;end
 endtask
 always @(posedge clk)begin
  if(!rst_n)begin needs_calibration<=1;camera_d<=0;long_issued<=0;hold_count<=0;cal_count<=0;
   calibrating<=0;setup_error<=0;calibrate_request<=0;calibration_version<=1;safety_epoch<=1;
   command_valid<=0;command<=0;mode_valid<=0;requested_mode<=0;end
  else begin
   calibrate_request<=0;command_valid<=0;mode_valid<=0;camera_d<=camera_ready;
   if(stage==3&&key_held[3])begin if(hold_count<2*CLK_HZ)hold_count<=hold_count+1'b1;end
   else begin hold_count<=0;long_issued<=0;end
   if(camera_d&&!camera_ready)begin needs_calibration<=1;safety_epoch<=safety_epoch+1'b1;end
   if(calibrating)begin
    if(calibration_done)begin
     calibrating<=0;needs_calibration<=!(calibration_success&&camera_ready);setup_error<=!(calibration_success&&camera_ready);
     if(calibration_success&&camera_ready)begin calibration_version<=calibration_version+1'b1;safety_epoch<=safety_epoch+1'b1;end
    end else if(cal_count>=CLK_HZ*2-1)begin calibrating<=0;setup_error<=1;needs_calibration<=1;end
    else cal_count<=cal_count+1'b1;
   end else if(long_cal&&camera_ready)begin long_issued<=1;begin_calibration();end
   else if(key_press[2])begin command_valid<=1;command<=pending_mode!=0||stage==3?3'd5:3'd4;end
   else if(key_press[0])begin
    mode_valid<=1;
    if(pending_mode!=0)requested_mode<=pending_mode==4?1:pending_mode+1'b1;
    else requested_mode<=mode==4?1:mode+1'b1;
   end else if(key_press[3])begin
    if(!calibrated)begin if(camera_ready)begin_calibration();else setup_error<=1;end
    else begin command_valid<=1;command<=pending_mode!=0?3'd1:stage==5?3'd6:3'd3;end
   end else if(key_press[1])begin command_valid<=1;command<=2;end
  end
 end
endmodule
`default_nettype wire
