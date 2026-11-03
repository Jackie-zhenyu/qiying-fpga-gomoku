`timescale 1ns/1ps
`default_nettype none
// Image-only local classification around a measured intersection. The formal
// board, current turn and AI target are deliberately absent from this interface.
// Non-cardinal rays observe the gaps between closely spaced circular stones.
// Each sampled gray value is a complete integer 3x3 average from this frozen frame.
module qy_grid_stone_probe #(
 parameter OFFSET_FILE="grid_probe_offsets.hex"
)(
 input wire clk,rst_n,start,
 input wire [8:0] point_x,input wire [7:0] point_y,input wire [3:0] radius_limit,
 output reg [15:0] raw_address,input wire [16:0] raw_data,
 output reg busy,done,output reg [1:0] color,
 output reg [8:0] found_x,output reg [7:0] found_y,output reg [3:0] found_radius,
 output reg [31:0] cycles
);
 localparam IDLE=0,CENTER=1,SMOOTH_INIT=2,PIX_ADDR=3,PIX_WAIT=4,PIX_USE=5,
  SMOOTH_DONE=6,CENTER_DONE=7,RADIUS_INIT=8,ROM_ADDR=9,ROM_WAIT=10,
  ROM_USE=11,SAMPLE_DONE=12,RAY_SCORE=13,RADIUS_CALC=14,RADIUS_TEST=15,
  NEXT_CENTER=16,FINISH=17,NEXT_RADIUS=18,AXIS_DONE=19;
 reg [4:0] state,center_index;
 reg [8:0] base_x;reg [7:0] base_y;reg [3:0] limit,radius,direction;
 reg signed [3:0] shift_x,shift_y;
 reg signed [10:0] cx,cy,sample_x,sample_y;
 reg [1:0] px,py;
 reg [11:0] smooth_sum;
 reg [7:0] smooth_value,center_value,inner_value,outside_value,edge_min;
 reg [3:0] smooth_neutral;
 reg smooth_paper,outside_paper,center_sample,axis_sample,center_neutral_good;
 reg [1:0] axis_index;reg [7:0] axis_max;
 reg [2:0] phase;
 reg [9:0] radius_base,angle_base;
 (* ram_style="bram" *) reg [15:0] offsets[0:1023];
 (* keep="true" *) reg [9:0] offset_address;
 reg [15:0] offset_data;
 initial $readmemh(OFFSET_FILE,offsets);
 always @(posedge clk)offset_data<=offsets[offset_address];
 reg [11:0] inner_sum,outer_sum;
 reg [9:0] score;
 reg [3:0] votes,white_votes,outer_neutral,quadrants;
 reg [18:0] inner100,outer40,outer55,center1200,outer45,axis1200,outer50,outer65;
 reg fallback_valid;reg [1:0] fallback_color;reg [8:0] fallback_x;reg [7:0] fallback_y;reg [3:0] fallback_radius,fallback_limit;
 wire edge_good=outside_value>=edge_min&&({1'b0,outside_value}-{1'b0,edge_min})>=9;
 wire [8:0] contrast=outside_value>=edge_min?{1'b0,outside_value}-{1'b0,edge_min}:9'd0;
 wire [6:0] clipped=contrast>64?7'd64:contrast[6:0];
 wire [1:0] quadrant=direction<3?2'd0:direction<6?2'd1:direction<9?2'd2:2'd3;
 wire common_good=votes>=9&&quadrants==15&&score>=180&&outer_sum>=780&&outer_neutral>=9;
 wire black_good=inner100<outer40&&center1200<outer45&&score>=225&&axis1200<=outer50;
 wire fallback_black=inner100<outer40&&center1200<outer45&&score>=225&&axis1200<=outer65&&{1'b0,axis_max}<=({1'b0,center_value}+9'd32);
 wire fallback_white=center_neutral_good&&inner100>=outer55&&inner_sum>=1080&&center_value>=90&&white_votes>=4&&score>=180;
 wire white_good=center_neutral_good&&inner100>=outer55&&inner_sum>=1080&&center_value>=90&&white_votes>=6&&score>=240;
 // The newly visited center class cannot satisfy original BLACK or WHITE.
 // Reuse votes/quadrants and white_votes[0] only in this disjoint class.
 // Equal fallback_color bits (00 or11) privately mark color-only WHITE.
 // Its radius MSB is encoded there, preserving the deployed three-bit
 // fallback-radius storage. Original strict/fallback results keep priority.
 wire color_mode=!center_neutral_good&&center_value>=115;
 wire color_white_good=color_mode&&votes>=9&&quadrants==15&&
  outer_neutral>=9&&outer_sum>=780&&inner_sum>=1080&&inner100>=outer55;
 wire color_edge_good=!white_votes[0]&&outside_paper;
 wire fallback_color_only=fallback_color[1]==fallback_color[0];
 always @*begin
  shift_x=0;shift_y=0;
  case(center_index)
   1:shift_x=-1;2:shift_x=1;3:shift_y=-1;4:shift_y=1;
   5:begin shift_x=-1;shift_y=-1;end
   6:begin shift_x=1;shift_y=-1;end
   7:begin shift_x=-1;shift_y=1;end
   8:begin shift_x=1;shift_y=1;end
   9:begin shift_x=-2;shift_y=-2;end
   10:begin shift_x=-1;shift_y=-2;end
   11:begin shift_x=0;shift_y=-2;end
   12:begin shift_x=1;shift_y=-2;end
   13:begin shift_x=2;shift_y=-2;end
   14:begin shift_x=-2;shift_y=-1;end
   15:begin shift_x=2;shift_y=-1;end
   16:begin shift_x=-2;shift_y=0;end
   17:begin shift_x=2;shift_y=0;end
   18:begin shift_x=-2;shift_y=1;end
   19:begin shift_x=2;shift_y=1;end
   20:begin shift_x=-2;shift_y=2;end
   21:begin shift_x=-1;shift_y=2;end
   22:begin shift_x=0;shift_y=2;end
   23:begin shift_x=1;shift_y=2;end
   24:begin shift_x=2;shift_y=2;end
   default:begin shift_x=0;shift_y=0;end
  endcase
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;center_index<=0;base_x<=0;base_y<=0;limit<=0;radius<=3;direction<=0;
   cx<=0;cy<=0;sample_x<=0;sample_y<=0;px<=0;py<=0;smooth_sum<=0;smooth_value<=0;
   center_value<=0;inner_value<=0;outside_value<=0;edge_min<=0;smooth_neutral<=0;
   smooth_paper<=0;outside_paper<=0;center_sample<=0;axis_sample<=0;center_neutral_good<=0;axis_index<=0;axis_max<=0;phase<=0;radius_base<=0;angle_base<=0;
   offset_address<=0;inner_sum<=0;outer_sum<=0;score<=0;votes<=0;white_votes<=0;outer_neutral<=0;quadrants<=0;
   inner100<=0;outer40<=0;outer55<=0;center1200<=0;outer45<=0;axis1200<=0;outer50<=0;outer65<=0;fallback_valid<=0;fallback_color<=3;fallback_x<=0;fallback_y<=0;fallback_radius<=0;fallback_limit<=0;
   raw_address<=0;busy<=0;done<=0;color<=3;found_x<=0;found_y<=0;found_radius<=0;cycles<=0;
  end else begin
   done<=0;
   if(busy)cycles<=cycles+1'b1;
   case(state)
    IDLE:if(start)begin
     busy<=1;color<=3;found_x<=point_x;found_y<=point_y;found_radius<=0;cycles<=0;
     fallback_valid<=0;
     case(radius_limit)
      0,1,2: fallback_limit<=0;
      3,4: fallback_limit<=2;
      5: fallback_limit<=3;
      6,7: fallback_limit<=4;
      8: fallback_limit<=5;
      9,10: fallback_limit<=6;
      default: fallback_limit<=7;
     endcase
     base_x<=point_x;base_y<=point_y;limit<=radius_limit>11?4'd11:radius_limit;
     center_index<=0;state<=radius_limit>=3?CENTER:FINISH;
    end
    CENTER:begin
     cx<=$signed({2'b0,base_x})+shift_x;cy<=$signed({3'b0,base_y})+shift_y;
     sample_x<=$signed({2'b0,base_x})+shift_x;sample_y<=$signed({3'b0,base_y})+shift_y;
     center_sample<=1;axis_sample<=0;radius<=limit;radius_base<=({6'd0,limit}-10'd3)*10'd72;state<=SMOOTH_INIT;
    end
    SMOOTH_INIT:begin
     px<=0;py<=0;smooth_sum<=0;smooth_neutral<=0;smooth_paper<=0;
     if(sample_x<1||sample_x>318||sample_y<1||sample_y>178)state<=center_sample?NEXT_CENTER:NEXT_RADIUS;
     else state<=PIX_ADDR;
    end
    PIX_ADDR:begin raw_address<=(sample_y+py-1)*320+sample_x+px-1;state<=PIX_WAIT;end
    PIX_WAIT:state<=PIX_USE;
    PIX_USE:begin
     smooth_sum<=smooth_sum+{4'd0,raw_data[7:0]};smooth_neutral<=smooth_neutral+raw_data[8];
     if(px==1&&py==1)smooth_paper<=raw_data[8];
     if(px==2)begin px<=0;if(py==2)state<=SMOOTH_DONE;else begin py<=py+1'b1;state<=PIX_ADDR;end end
     else begin px<=px+1'b1;state<=PIX_ADDR;end
    end
    SMOOTH_DONE:begin smooth_value<=smooth_sum/9;state<=center_sample?CENTER_DONE:axis_sample?AXIS_DONE:SAMPLE_DONE;end
    CENTER_DONE:begin
     center_value<=smooth_value;center_sample<=0;center_neutral_good<=smooth_neutral>=8;
     // Paper chroma is evidence for WHITE, not a prerequisite for BLACK.
     // A gain change can lift a non-neutral black center above65 while its
     // complete ring, dark interior, axes and paper surroundings stay valid.
     // BLACK requires center < 45% of outer mean, hence never reaches115
     // even with outer mean255. Skip only when neither color can pass.
     if(smooth_neutral<8&&smooth_value>=115&&smooth_neutral>1)state<=NEXT_CENTER;else state<=RADIUS_INIT;
    end
    RADIUS_INIT:begin
     direction<=0;phase<=0;angle_base<=0;inner_sum<=0;outer_sum<=0;score<=0;
     votes<=0;white_votes<=0;outer_neutral<=0;quadrants<=0;edge_min<=255;axis_sample<=0;
     if(cx<$signed({7'd0,radius})+4||cx>315-$signed({7'd0,radius})||
        cy<$signed({7'd0,radius})+4||cy>175-$signed({7'd0,radius}))state<=NEXT_RADIUS;
     else state<=ROM_ADDR;
    end
    ROM_ADDR:begin
     offset_address<=axis_sample?10'd768+({6'd0,radius}-10'd3)*10'd4+axis_index:radius_base+angle_base+phase;
     state<=ROM_WAIT;
    end
    ROM_WAIT:state<=ROM_USE;
    ROM_USE:begin
     sample_x<=cx+$signed(offset_data[7:0]);sample_y<=cy+$signed(offset_data[15:8]);state<=SMOOTH_INIT;
    end
    SAMPLE_DONE:begin
     if(phase==0)begin
      inner_value<=smooth_value;inner_sum<=inner_sum+{4'd0,smooth_value};
      if(color_mode)white_votes[0]<=smooth_paper;
     end
     else if(phase==1)edge_min<=smooth_value;
     else if(phase==2||phase==3)begin if(smooth_value<edge_min)edge_min<=smooth_value;end
     else if(phase==4||smooth_value>outside_value)begin outside_value<=smooth_value;outside_paper<=smooth_paper;end
     if(phase==5)state<=RAY_SCORE;
     else begin phase<=phase+1'b1;state<=ROM_ADDR;end
    end
    RAY_SCORE:begin
     outer_sum<=outer_sum+{4'd0,outside_value};score<=score+{3'd0,clipped};outer_neutral<=outer_neutral+outside_paper;
     if(color_mode?color_edge_good:edge_good)begin votes<=votes+1'b1;quadrants[quadrant]<=1;end
     if(!color_mode&&edge_good&&{1'b0,inner_value}>={1'b0,edge_min}+9'd4)white_votes<=white_votes+1'b1;
     if(direction==11)begin axis_sample<=1;axis_index<=0;axis_max<=0;state<=ROM_ADDR;end
     else begin direction<=direction+1'b1;angle_base<=angle_base+10'd6;phase<=0;state<=ROM_ADDR;end
    end
    RADIUS_CALC:begin
     inner100<={7'd0,inner_sum}*19'd100;outer40<={7'd0,outer_sum}*19'd40;
     outer55<={7'd0,outer_sum}*19'd55;center1200<={11'd0,center_value}*19'd1200;
     outer45<={7'd0,outer_sum}*19'd45;axis1200<={11'd0,axis_max}*19'd1200;
     outer65<={7'd0,outer_sum}*19'd65;outer50<={7'd0,outer_sum}*19'd50;state<=RADIUS_TEST;
    end
    AXIS_DONE:begin
     if(smooth_value>axis_max)axis_max<=smooth_value;
     if(axis_index==3)state<=RADIUS_CALC;
     else begin axis_index<=axis_index+1'b1;state<=ROM_ADDR;end
    end
    RADIUS_TEST:begin
     if(!fallback_valid&&color_white_good)begin
      fallback_valid<=1;fallback_color<=radius[3]?2'd3:2'd0;fallback_x<=cx[8:0];fallback_y<=cy[7:0];fallback_radius<={1'b0,radius[2:0]};
     end
     // An original fallback overwrites any color-only proposal; strict wins.
     if((!fallback_valid||fallback_color_only)&&radius>=4&&radius==fallback_limit&&common_good&&(fallback_black||fallback_white))begin
      fallback_valid<=1;fallback_color<=fallback_black?2'd1:2'd2;fallback_x<=cx[8:0];fallback_y<=cy[7:0];fallback_radius<=radius;
     end
     if(common_good&&(black_good||white_good))begin
      color<=black_good?2'd1:2'd2;found_x<=cx[8:0];found_y<=cy[7:0];found_radius<=radius;state<=FINISH;
     end else state<=NEXT_RADIUS;
    end
    NEXT_RADIUS:begin
     if(radius>3)begin radius<=radius-1'b1;radius_base<=radius_base-10'd72;state<=RADIUS_INIT;end
     else state<=NEXT_CENTER;
    end
    NEXT_CENTER:begin
     if(center_index==24)begin
      if(fallback_valid)begin color<=fallback_color_only?2'd2:fallback_color;found_x<=fallback_x;found_y<=fallback_y;found_radius<={fallback_color==2'd3,fallback_radius[2:0]};end
      state<=FINISH;
     end
     else begin center_index<=center_index+1'b1;state<=CENTER;end
    end
    FINISH:begin done<=1;busy<=0;state<=IDLE;end
    default:begin busy<=0;color<=3;done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
`default_nettype wire
