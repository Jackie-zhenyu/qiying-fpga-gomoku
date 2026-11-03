`timescale 1ns/1ps
`default_nettype none
// Same frozen 320x180 image and same result as the radial detector.
// raw[8:0] retains the accepted gray/paper sample; raw[16:9] is the
// minimum gray of the corresponding complete 6x6 source block, for grid lines.
// Calibration starts from explicitly confirmed four-corner nominal points and
// refines EACH measured intersection. Missing lines are not interpolated as valid.
module qy_grid_observer(
 input wire clk,rst_n,start,calibrate,
 input wire [2872:0] nominal_points,
 input wire [6143:0] boxes,input wire [7:0] box_count,detector_error,
 output reg [15:0] raw_address,input wire [16:0] raw_data,
 output reg busy,done,observation_valid,calibration_done,calibration_success,
 output reg calibrated,output reg [2872:0] points,
 output reg [337:0] cells,output reg [168:0] observable,
 output reg [1351:0] confidence,output reg [15:0] quality,
 output wire board_observable
);
 localparam IDLE=0,MAP_INIT=1,MAP_DIFF=2,MAP_DIST=3,MAP_PICK=4,MAP_DONE=5,
  CELL_INIT=6,PIX_ADDR=7,PIX_WAIT=8,PIX_USE=9,LINE_INIT=10,LINE_SCAN=11,
  CLASSIFY=12,NEXT_CELL=13,FINISH=14,VERIFY_INIT=15,VERIFY_POINT=16,
  VERIFY_LOAD=17,VERIFY_CHECK=18,MAP_READ=19;
 reg [4:0] state;
 reg calibration_mode,failed,calibration_verify;
 reg [6143:0] frozen_boxes;
 reg [2872:0] work_points;
 reg [337:0] mapped;
 reg [7:0] box_index,point_index,cell_index,best_index;
 reg [31:0] box_word;
 reg [8:0] dx;
 reg [7:0] dy;
 reg [18:0] distance,best_distance,second_distance;
 reg [16:0] map_point;
 wire [16:0] cell_point=work_points[cell_index*17+:17];
 wire [8:0] mx=map_point[8:0];wire [7:0] my=map_point[16:9];
 reg [8:0] cx;reg [7:0] cy;
 reg [2:0] px,py,line_index,h_index,v_index;
 reg [10:0] hsum[0:6],vsum[0:6];
 reg [10:0] hmin,hmax,vmin,vmax;
 reg [5:0] neutral,bright;
 reg point_bounds;
 wire [1:0] mapped_color=mapped[cell_index*2+:2];
 wire visible_paper=neutral>=35&&bright>=35;
 wire line_good=hmax>=hmin+11'd50&&vmax>=vmin+11'd50;
 wire aligned=h_index>=2&&h_index<=4&&v_index>=2&&v_index<=4;
 wire [8:0] refined_x=cx+{6'd0,v_index}-9'd3;
 wire [7:0] refined_y=cy+{5'd0,h_index}-8'd3;
 reg [16:0] verify_point,verify_left,verify_above;
 reg [7:0] verify_left_index,verify_above_index;
 reg [3:0] verify_col;
 reg verify_has_left,verify_has_above;
 assign board_observable=calibrated&&quality==0&&(&observable);
 integer j;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;raw_address<=0;busy<=0;done<=0;observation_valid<=0;
   calibrated<=0;calibration_done<=0;calibration_success<=0;points<=0;
   cells<=0;observable<=0;confidence<=0;quality<=0;calibration_mode<=0;failed<=0;calibration_verify<=0;
   frozen_boxes<=0;work_points<=0;mapped<=0;box_index<=0;point_index<=0;cell_index<=0;best_index<=0;box_word<=0;
   dx<=0;dy<=0;distance<=0;best_distance<=0;second_distance<=0;
   map_point<=0;verify_point<=0;verify_left<=0;verify_above<=0;
   verify_left_index<=0;verify_above_index<=0;verify_col<=0;verify_has_left<=0;verify_has_above<=0;
   cx<=0;cy<=0;px<=0;py<=0;line_index<=0;h_index<=0;v_index<=0;
   hmin<=0;hmax<=0;vmin<=0;vmax<=0;neutral<=0;bright<=0;point_bounds<=0;
   for(j=0;j<7;j=j+1)begin hsum[j]<=0;vsum[j]<=0;end
  end else begin
   done<=0;observation_valid<=0;calibration_done<=0;
   case(state)
    IDLE:if(start)begin
     busy<=1;calibration_mode<=calibrate;quality<=0;failed<=0;calibration_verify<=0;
     frozen_boxes<=boxes;box_index<=0;cell_index<=0;mapped<=0;cells<=0;observable<=0;confidence<=0;
     work_points<=calibrate?nominal_points:points;
     if(calibrate)begin
      calibrated<=0;calibration_success<=0;state<=CELL_INIT;
      if(detector_error!=0||box_count!=0)begin failed<=1;quality<=16'h0002;end
     end else if(!calibrated||detector_error!=0)begin quality<=16'h0001;state<=FINISH;end
     else state<=MAP_INIT;
    end
    MAP_INIT:begin
     box_word<=frozen_boxes[box_index*32+:32];point_index<=0;
     best_distance<=19'h7ffff;second_distance<=19'h7ffff;best_index<=0;state<=MAP_READ;
    end
    MAP_READ:begin map_point<=points[point_index*17+:17];state<=MAP_DIFF;end
    MAP_DIFF:begin
     if(!box_word[23])state<=MAP_DONE;
     else if(box_word[22:21]!=1&&box_word[22:21]!=2)begin quality[1]<=1;state<=MAP_DONE;end
     else begin
      dx<=box_word[8:0]>=mx?box_word[8:0]-mx:mx-box_word[8:0];
      dy<=box_word[16:9]>=my?box_word[16:9]-my:my-box_word[16:9];state<=MAP_DIST;
     end
    end
    MAP_DIST:begin distance<={1'b0,dx}*{1'b0,dx}+{2'd0,dy}*{2'd0,dy};state<=MAP_PICK;end
    MAP_PICK:begin
     if(distance<best_distance)begin second_distance<=best_distance;best_distance<=distance;best_index<=point_index;end
     else if(distance<second_distance)second_distance<=distance;
     if(point_index==168)state<=MAP_DONE;else begin point_index<=point_index+1'b1;state<=MAP_READ;end
    end
    MAP_DONE:begin
     if(box_word[23])begin
      if(best_distance<=9&&second_distance>best_distance+2)begin
       if(mapped[best_index*2+:2]!=0)begin mapped[best_index*2+:2]<=3;quality[2]<=1;end
       else mapped[best_index*2+:2]<=box_word[22:21];
      end else begin
       // Active area is the confirmed image-oriented grid bounding rectangle.
       // A stone elsewhere in the camera view is not a game move.
       if(box_word[8:0]+3>=points[0+:9]&&box_word[8:0]<=points[168*17+:9]+3&&
          box_word[16:9]+3>=points[9+:8]&&box_word[16:9]<=points[168*17+9+:8]+3)
        quality[3]<=1;
      end
     end
     if(box_index==191)begin cell_index<=0;state<=CELL_INIT;end
     else begin box_index<=box_index+1'b1;state<=MAP_INIT;end
    end
    CELL_INIT:begin
     cx<=cell_point[8:0];cy<=cell_point[16:9];px<=0;py<=0;neutral<=0;bright<=0;
     point_bounds<=cell_point[8:0]>=4&&cell_point[8:0]<=315&&cell_point[16:9]>=4&&cell_point[16:9]<=175;
     for(j=0;j<7;j=j+1)begin hsum[j]<=0;vsum[j]<=0;end
     state<=PIX_ADDR;
    end
    PIX_ADDR:begin
     if(!point_bounds)begin failed<=1;quality[4]<=1;state<=NEXT_CELL;end
     else begin raw_address<=({8'd0,cy}+{13'd0,py}-16'd3)*16'd320+{7'd0,cx}+{13'd0,px}-16'd3;state<=PIX_WAIT;end
    end
    PIX_WAIT:state<=PIX_USE;
    PIX_USE:begin
     neutral<=neutral+raw_data[8];bright<=bright+(raw_data[7:0]>=80);
     hsum[py]<=hsum[py]+{3'd0,raw_data[16:9]};vsum[px]<=vsum[px]+{3'd0,raw_data[16:9]};
     if(px==6)begin px<=0;if(py==6)state<=LINE_INIT;else begin py<=py+1'b1;state<=PIX_ADDR;end end
     else begin px<=px+1'b1;state<=PIX_ADDR;end
    end
    LINE_INIT:begin
     hmin<=2047;hmax<=0;vmin<=2047;vmax<=0;h_index<=0;v_index<=0;line_index<=0;state<=LINE_SCAN;
    end
    LINE_SCAN:begin
     if(hsum[line_index]<hmin)begin hmin<=hsum[line_index];h_index<=line_index;end
     if(hsum[line_index]>hmax)hmax<=hsum[line_index];
     if(vsum[line_index]<vmin)begin vmin<=vsum[line_index];v_index<=line_index;end
     if(vsum[line_index]>vmax)vmax<=vsum[line_index];
     if(line_index==6)state<=CLASSIFY;else line_index<=line_index+1'b1;
    end
    CLASSIFY:begin
     if(calibration_mode)begin
      // First pass can move at most three samples. A second full pixel pass
      // must see BOTH measured line minima near the refined center.
      if(visible_paper&&line_good&&(!calibration_verify||aligned))begin
       if(!calibration_verify)work_points[cell_index*17+:17]<={refined_y,refined_x};
      end
      else begin failed<=1;quality[5]<=1;end
     end else if(mapped_color==1||mapped_color==2)begin
      if(neutral>=35)begin cells[cell_index*2+:2]<=mapped_color;observable[cell_index]<=1;confidence[cell_index*8+:8]<=255;end
      else begin cells[cell_index*2+:2]<=3;quality[6]<=1;end
     end else if(mapped_color==0&&visible_paper&&line_good&&aligned)begin
      cells[cell_index*2+:2]<=0;observable[cell_index]<=1;confidence[cell_index*8+:8]<=255;
     end else begin cells[cell_index*2+:2]<=3;quality[6]<=1;end
     state<=NEXT_CELL;
    end
    NEXT_CELL:if(cell_index==168)begin
     if(calibration_mode&&!calibration_verify)begin calibration_verify<=1;cell_index<=0;state<=CELL_INIT;end
     else state<=calibration_mode?VERIFY_INIT:FINISH;
    end else begin cell_index<=cell_index+1'b1;state<=CELL_INIT;end
    VERIFY_INIT:begin point_index<=0;verify_col<=0;state<=VERIFY_POINT;end
    VERIFY_POINT:begin
     verify_left_index<=point_index-1'b1;verify_above_index<=point_index-8'd13;
     verify_has_left<=verify_col!=0;verify_has_above<=point_index>=13;state<=VERIFY_LOAD;
    end
    VERIFY_LOAD:begin
     verify_point<=work_points[point_index*17+:17];
     verify_left<=work_points[verify_left_index*17+:17];
     verify_above<=work_points[verify_above_index*17+:17];state<=VERIFY_CHECK;
    end
    VERIFY_CHECK:begin
     if(verify_point[8:0]<4||verify_point[8:0]>315||verify_point[16:9]<4||verify_point[16:9]>175||
        (verify_has_left&&{1'b0,verify_point[8:0]}<{1'b0,verify_left[8:0]}+10'd6)||
        (verify_has_above&&{1'b0,verify_point[16:9]}<{1'b0,verify_above[16:9]}+9'd6))begin
      failed<=1;quality[7]<=1;
     end
     if(point_index==168)state<=FINISH;else begin
      point_index<=point_index+1'b1;verify_col<=verify_col==12?0:verify_col+1'b1;state<=VERIFY_POINT;
     end
    end
    FINISH:begin
     busy<=0;done<=1;state<=IDLE;
     if(calibration_mode)begin
      calibration_done<=1;calibration_success<=!failed;calibrated<=!failed;
      if(!failed)points<=work_points;
     end else observation_valid<=1;
    end
    default:begin state<=IDLE;busy<=0;quality<=16'h8000;calibrated<=0;end
   endcase
  end
 end
endmodule
`default_nettype wire
