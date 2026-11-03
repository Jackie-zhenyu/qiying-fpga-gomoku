`timescale 1ns/1ps
`default_nettype none
// Board-local setup. Four-corner values are proposals until an empty grid is
// measured successfully. New-game confirmation does not erase the game here.
module qy_interaction_controls #(
 parameter CLK_HZ=137500000, parameter AUTO_SIZE=0,
 parameter CALIBRATION_LEVEL_HANDSHAKE=0
)(
 input wire clk,rst_n,camera_ready,input wire [3:0] key_press,key_held,
 input wire external_request_valid,input wire [2:0] external_request,
 input wire calibration_done,calibration_success,input wire [7:0] move_count,
 output wire paused,output reg human_white,output reg new_game_request,calibrate_request,
 output reg [31:0] calibration_version,safety_epoch,
 output reg [2872:0] nominal_points,output wire [67:0] corners,
 output reg [2:0] mode,output reg [2:0] field,output wire [8:0] field_value,
 output reg setup_error,output reg show_target,output reg points_ready,
 output reg [15:0] calibration_start_count,calibration_consume_count,
 output reg calibration_start_event,calibration_consume_event
);
 localparam PLAY=0,SETUP=1,EDIT=2,CONFIRM_NEW=3,PAUSE=4,CALIBRATING=5;
 reg [8:0] corner_x[0:3];reg [7:0] corner_y[0:3];
 reg pending_new,camera_d;
 wire external_idle=external_request_valid&&key_press==0&&key_held==0;
 reg [31:0] repeat_count;reg [1:0] held_direction;reg repeat_minus,repeat_plus;
 wire minus=key_press[1]||repeat_minus,plus=key_press[2]||repeat_plus;
 assign paused=mode!=PLAY;
 assign field_value=field[0]?{1'b0,corner_y[field[2:1]]}:corner_x[field[2:1]];
 genvar q;generate for(q=0;q<4;q=q+1)begin:corner_ports
  assign corners[q*17+:17]={corner_y[q],corner_x[q]};
 end endgenerate
 wire geometry_good=corner_x[1]>=corner_x[0]+96&&corner_x[3]>=corner_x[2]+96&&
  corner_y[2]>=corner_y[0]+96&&corner_y[3]>=corner_y[1]+96&&
  corner_x[0]+32>=corner_x[2]&&corner_x[2]+32>=corner_x[0]&&
  corner_x[1]+32>=corner_x[3]&&corner_x[3]+32>=corner_x[1]&&
  {1'b0,corner_y[0]}+32>={1'b0,corner_y[1]}&&{1'b0,corner_y[1]}+32>={1'b0,corner_y[0]}&&
  {1'b0,corner_y[2]}+32>={1'b0,corner_y[3]}&&{1'b0,corner_y[3]}+32>={1'b0,corner_y[2]};
 reg [2:0] gen_state;reg [3:0] row,col;reg [7:0] index;
 reg [12:0] top_x,bottom_x,top_y,bottom_y;
 reg [16:0] sum_x,sum_y;reg [16:0] generated_point;
 reg regenerate;
 always @(posedge clk)begin
  if(!rst_n)begin
   mode<=SETUP;field<=0;human_white<=0;new_game_request<=0;calibrate_request<=0;
   calibration_start_count<=0;calibration_consume_count<=0;
   calibration_start_event<=0;calibration_consume_event<=0;
   calibration_version<=1;safety_epoch<=1;setup_error<=0;show_target<=1;pending_new<=1;camera_d<=0;
   // Initial proposals from the user's aligned empty-board capture on2026-10-14.
   // Hardware must still measure and validate every crossing before play.
   corner_x[0]<=100;corner_y[0]<=31;corner_x[1]<=225;corner_y[1]<=29;
   corner_x[2]<=97;corner_y[2]<=155;corner_x[3]<=225;corner_y[3]<=158;
   regenerate<=1;repeat_count<=0;held_direction<=0;repeat_minus<=0;repeat_plus<=0;
  end else begin
   new_game_request<=0;calibration_start_event<=0;calibration_consume_event<=0;
   // The optional four-phase channel keeps the request until its final
   // result is consumed. The detector then clears done after seeing req=0.
   if(!CALIBRATION_LEVEL_HANDSHAKE)calibrate_request<=0;
   regenerate<=0;repeat_minus<=0;repeat_plus<=0;camera_d<=camera_ready;
   if(camera_d&&!camera_ready)safety_epoch<=safety_epoch+1'b1;
   if(mode==EDIT&&(key_held[2:1]==1||key_held[2:1]==2))begin
    if(held_direction!=key_held[2:1])begin held_direction<=key_held[2:1];repeat_count<=CLK_HZ/2;end
    else if(repeat_count==0)begin repeat_count<=CLK_HZ/12;repeat_minus<=key_held[1];repeat_plus<=key_held[2];end
    else repeat_count<=repeat_count-1'b1;
   end else begin repeat_count<=0;held_direction<=0;end
   case(mode)
    PLAY:begin
     if(key_press[0])begin mode<=CONFIRM_NEW;setup_error<=0;safety_epoch<=safety_epoch+1'b1;end
     else if(key_press[1])begin
      if(move_count==0)begin mode<=SETUP;pending_new<=1;setup_error<=0;safety_epoch<=safety_epoch+1'b1;end
      else setup_error<=0; // No secondary function during play.
     end else if(key_press[2])begin mode<=PAUSE;setup_error<=0;safety_epoch<=safety_epoch+1'b1;end
     else if(key_press[3])begin show_target<=!show_target;setup_error<=0;end
     else if(external_idle&&external_request==1)begin mode<=CONFIRM_NEW;setup_error<=0;safety_epoch<=safety_epoch+1'b1;end
     else if(external_idle&&external_request==3)begin mode<=PAUSE;setup_error<=0;safety_epoch<=safety_epoch+1'b1;end
    end
    PAUSE:begin
     if(key_press[2])begin mode<=PLAY;safety_epoch<=safety_epoch+1'b1;setup_error<=0;end
     else if(key_press[0])begin mode<=CONFIRM_NEW;safety_epoch<=safety_epoch+1'b1;end
     else if(external_idle&&external_request==1)begin mode<=CONFIRM_NEW;safety_epoch<=safety_epoch+1'b1;end
     else if(external_idle&&external_request==4&&camera_ready)begin mode<=PLAY;safety_epoch<=safety_epoch+1'b1;setup_error<=0;end
    end
    CONFIRM_NEW:begin
     if(key_press[0])begin mode<=PLAY;safety_epoch<=safety_epoch+1'b1;end
     else if(key_press[3])begin mode<=SETUP;pending_new<=1;setup_error<=0;safety_epoch<=safety_epoch+1'b1;end
    end
    SETUP:begin
     if(key_press[0])human_white<=!human_white;
     else if(key_press[1]&&!AUTO_SIZE)begin mode<=EDIT;field<=0;setup_error<=0;end
     else if(key_press[3]&&(!CALIBRATION_LEVEL_HANDSHAKE||!calibration_done))begin
      if((AUTO_SIZE||(points_ready&&geometry_good))&&camera_ready)begin
       mode<=CALIBRATING;calibrate_request<=1;setup_error<=0;safety_epoch<=safety_epoch+1'b1;
       calibration_start_event<=1;
       if(calibration_start_count!=16'hffff)calibration_start_count<=calibration_start_count+1'b1;
      end
      else setup_error<=1;
     end
    end
    EDIT:begin
     if(key_press[0])mode<=SETUP;
     else if(key_press[3])begin if(field==7)mode<=SETUP;else field<=field+1'b1;end
     else if(minus&&!plus)begin
      if(field[0])begin if(corner_y[field[2:1]]>5)corner_y[field[2:1]]<=corner_y[field[2:1]]-1'b1;end
      else if(corner_x[field[2:1]]>5)corner_x[field[2:1]]<=corner_x[field[2:1]]-1'b1;
      regenerate<=1;
     end else if(plus&&!minus)begin
      if(field[0])begin if(corner_y[field[2:1]]<174)corner_y[field[2:1]]<=corner_y[field[2:1]]+1'b1;end
      else if(corner_x[field[2:1]]<314)corner_x[field[2:1]]<=corner_x[field[2:1]]+1'b1;
      regenerate<=1;
     end
    end
    CALIBRATING:begin
     if(calibration_done&&(!CALIBRATION_LEVEL_HANDSHAKE||calibrate_request))begin
      calibration_consume_event<=1;
      if(calibration_consume_count!=16'hffff)calibration_consume_count<=calibration_consume_count+1'b1;
      if(CALIBRATION_LEVEL_HANDSHAKE)calibrate_request<=0;
      if(calibration_success&&(!CALIBRATION_LEVEL_HANDSHAKE||camera_ready))begin
       calibration_version<=calibration_version+1'b1;safety_epoch<=safety_epoch+1'b1;
       mode<=PLAY;setup_error<=0;new_game_request<=pending_new;pending_new<=0;
      end else begin mode<=SETUP;setup_error<=1;end
     end
    end
    default:begin
     // Do not abandon an outstanding level transaction on mode recovery.
     mode<=CALIBRATION_LEVEL_HANDSHAKE&&calibrate_request?CALIBRATING:SETUP;
     setup_error<=1;safety_epoch<=safety_epoch+1'b1;
    end
   endcase
  end
 end
 // Bilinear interpolation only proposes locations. Actual line measurements
 // validate and refine these points before calibrated becomes true.
 always @(posedge clk)begin
  if(!rst_n)begin
   gen_state<=0;row<=0;col<=0;index<=0;top_x<=0;bottom_x<=0;top_y<=0;bottom_y<=0;
   sum_x<=0;sum_y<=0;generated_point<=0;nominal_points<=0;points_ready<=0;
  end else if(regenerate)begin gen_state<=1;row<=0;col<=0;index<=0;points_ready<=0;end
  else case(gen_state)
   1:begin
    top_x<=corner_x[0]*(13'd12-col)+corner_x[1]*col;bottom_x<=corner_x[2]*(13'd12-col)+corner_x[3]*col;
    top_y<=corner_y[0]*(13'd12-col)+corner_y[1]*col;bottom_y<=corner_y[2]*(13'd12-col)+corner_y[3]*col;gen_state<=2;
   end
   2:begin sum_x<=top_x*(17'd12-row)+bottom_x*row+17'd72;sum_y<=top_y*(17'd12-row)+bottom_y*row+17'd72;gen_state<=3;end
   3:begin generated_point[8:0]<=sum_x/144;generated_point[16:9]<=sum_y/144;gen_state<=4;end
   4:begin
    nominal_points[index*17+:17]<=generated_point;
    if(index==168)begin points_ready<=1;gen_state<=0;end
    else begin index<=index+1'b1;if(col==12)begin col<=0;row<=row+1'b1;end else col<=col+1'b1;gen_state<=1;end
   end
   default:gen_state<=0;
  endcase
 end
endmodule
`default_nettype wire
