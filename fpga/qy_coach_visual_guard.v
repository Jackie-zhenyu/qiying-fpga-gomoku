`timescale 1ns/1ps
// Read-only permission for coaching the latest confirmed physical position.
// No command, board-write, calibration override or observation output exists.
module qy_coach_visual_guard #(parameter [63:0] MAX_AGE_US=500000)(
 input wire clk,rst_n,clear_i,active_i,camera_ready_i,calibrated_i,
 input wire origin_ok_i,paused_i,fault_i,
 input wire [337:0] board_i,input wire [191:0] context_i,
 input wire [31:0] epoch_i,input wire [63:0] now_us,
 input wire obs_valid_i,obs_observable_i,input wire [15:0] obs_quality_i,
 input wire [337:0] obs_cells_i,input wire [191:0] obs_context_i,
 input wire [31:0] obs_epoch_i,input wire [63:0] obs_time_i,
 output wire safe_o
);
 reg good;reg [337:0] cells;reg [191:0] captured_context;
 reg [31:0] epoch;reg [63:0] captured;
 always @(posedge clk)begin
  if(!rst_n||clear_i||!active_i)begin good<=0;cells<=0;captured_context<=0;epoch<=0;captured<=0;end
  else if(obs_valid_i)begin
   good<=obs_observable_i&&obs_quality_i==0;cells<=obs_cells_i;
   captured_context<=obs_context_i;epoch<=obs_epoch_i;captured<=obs_time_i;
  end
 end
 assign safe_o=rst_n&&!clear_i&&active_i&&camera_ready_i&&calibrated_i&&
  origin_ok_i&&!paused_i&&!fault_i&&good&&cells==board_i&&captured_context==context_i&&
  epoch==epoch_i&&now_us>=captured&&now_us-captured<=MAX_AGE_US;
endmodule
