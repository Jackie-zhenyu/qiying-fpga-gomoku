`timescale 1ns/1ps
`default_nettype none
// Rasterize a complete result in a back-bank 640x360 mask, then publish only
// at vertical blank. Exact original two-pixel rectangles and white priority.
// Replacing an in-flight result restarts the complete mask clear/build cycle.
module qy_stone_game_overlay #(
 parameter VIEW_X=1200,VIEW_Y=192,MAX_AGE_FRAMES=30
)(
 input wire clk,rst_n,camera_ready,result_valid,input wire [6143:0] boxes,
 input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 localparam IDLE=0,CLEAR=1,LOAD=2,BOUNDS=3,PAINT_INIT=4,PAINT=5,NEXT=6,READY=7,
  WORD_WAIT=8,WORD_USE=9;
 (* ram_style="bram" *) reg [1:0] bank0[0:262143];
 (* ram_style="bram" *) reg [1:0] bank1[0:262143];
 (* keep="true" *) reg [17:0] read_address,write_address;
 reg [1:0] color0,color1,write_color;reg write_enable,write_bank;
 reg front_bank,front_valid;
 always @(posedge clk)begin
  color0<=bank0[read_address];color1<=bank1[read_address];
  if(write_enable)begin if(write_bank)bank1[write_address]<=write_color;else bank0[write_address]<=write_color;end
 end
 reg [3:0] state;reg [17:0] clear_address;wire [6143:0] snapshot;
 reg [7:0] box_index;reg pass_white;reg [31:0] box_word;
 wire snapshot_busy;wire [31:0] read_word;
 qy_banked_records snapshot_bank(.clk(clk),.rst_n(rst_n),.capture_start(result_valid&&camera_ready),
  .capture_zero(1'b0),.capture_data(boxes),.write_valid(1'b0),.write_index(8'd0),.write_data(32'd0),
  .busy(snapshot_busy),.done(),.records(snapshot));
 qy_banked_record_reader snapshot_reader(.clk(clk),.records(snapshot),.index(box_index),.data(read_word));
 reg signed [11:0] left_x,right_x,top_y,bottom_y,paint_x,paint_y;
 wire signed [11:0] cx=$signed({2'd0,box_word[8:0],1'b0});
 wire signed [11:0] cy=$signed({3'd0,box_word[16:9],1'b0});
 wire signed [11:0] radius=$signed({7'd0,box_word[20:17],1'b0})+12'sd2;
 reg [11:0] x,y;reg de_d,vs_d;wire frame_edge=vs_i&&!vs_d;
 reg [5:0] age;
 wire view=de_i&&x>=VIEW_X&&x<VIEW_X+640&&y>=VIEW_Y&&y<VIEW_Y+360;
 reg read_visible0,read_visible1,bank_q0,bank_q1;
 reg [23:0] rgb0,rgb1;reg [2:0] sync0,sync1;
 wire [1:0] mask_color=bank_q1?color1:color0;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;clear_address<=0;box_index<=0;pass_white<=0;box_word<=0;
   left_x<=0;right_x<=0;top_y<=0;bottom_y<=0;paint_x<=0;paint_y<=0;
   write_address<=0;write_color<=0;write_enable<=0;write_bank<=1;
   front_bank<=0;front_valid<=0;age<=MAX_AGE_FRAMES;
   x<=0;y<=0;de_d<=0;vs_d<=0;read_address<=0;
   read_visible0<=0;read_visible1<=0;bank_q0<=0;bank_q1<=0;rgb0<=0;rgb1<=0;sync0<=0;sync1<=0;
   rgb_o<=0;de_o<=0;hs_o<=0;vs_o<=0;
  end else begin
   de_d<=de_i;vs_d<=vs_i;
   if(frame_edge)begin x<=0;y<=0;if(age<MAX_AGE_FRAMES)age<=age+1'b1;end
   else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
   read_address<=view?(y-VIEW_Y)*18'd640+(x-VIEW_X):18'd0;
   read_visible0<=view&&front_valid&&camera_ready&&age<MAX_AGE_FRAMES;read_visible1<=read_visible0;
   bank_q0<=front_bank;bank_q1<=bank_q0;rgb0<=rgb_i;rgb1<=rgb0;
   sync0<={vs_i,hs_i,de_i};sync1<=sync0;{vs_o,hs_o,de_o}<=sync1;
   rgb_o<=!sync1[0]?24'd0:read_visible1&&mask_color==2?24'h43e9ff:
    read_visible1&&mask_color==1?24'hffcf40:rgb1;
   write_enable<=0;
   case(state)
    IDLE:begin end
    CLEAR:begin
     write_enable<=1;write_bank<=!front_bank;write_address<=clear_address;write_color<=0;
     if(clear_address==230399)begin box_index<=0;pass_white<=0;state<=LOAD;end
     else clear_address<=clear_address+1'b1;
    end
    LOAD:if(!snapshot_busy)state<=WORD_WAIT;
    WORD_WAIT:state<=WORD_USE;
    WORD_USE:begin box_word<=read_word;state<=BOUNDS;end
    BOUNDS:begin
     left_x<=cx-radius;right_x<=cx+radius;top_y<=cy-radius;bottom_y<=cy+radius;
     if(box_word[23]&&box_word[22:21]==(pass_white?2'd2:2'd1)&&box_word[8:0]<320&&box_word[16:9]<180)state<=PAINT_INIT;
     else state<=NEXT;
    end
    PAINT_INIT:begin paint_x<=left_x;paint_y<=top_y;state<=PAINT;end
    PAINT:begin
     if(paint_x>=0&&paint_x<640&&paint_y>=0&&paint_y<360&&
        (paint_x<left_x+2||paint_x>right_x-2||paint_y<top_y+2||paint_y>bottom_y-2))begin
      write_enable<=1;write_bank<=!front_bank;write_address<=paint_y*18'd640+paint_x;
      write_color<=pass_white?2'd2:2'd1;
     end
     if(paint_x==right_x)begin paint_x<=left_x;if(paint_y==bottom_y)state<=NEXT;else paint_y<=paint_y+1'b1;end
     else paint_x<=paint_x+1'b1;
    end
    NEXT:begin
     if(box_index==191)begin
      if(pass_white)state<=READY;
      else begin pass_white<=1;box_index<=0;state<=LOAD;end
     end else begin box_index<=box_index+1'b1;state<=LOAD;end
    end
    READY:if(frame_edge&&!result_valid)begin front_bank<=!front_bank;front_valid<=1;age<=0;state<=IDLE;end
    default:begin state<=IDLE;front_valid<=0;end
   endcase
   if(result_valid)begin state<=CLEAR;clear_address<=0;write_enable<=0;end
   if(!camera_ready)begin state<=IDLE;front_valid<=0;age<=MAX_AGE_FRAMES;write_enable<=0;end
  end
 end
endmodule
`default_nettype wire
