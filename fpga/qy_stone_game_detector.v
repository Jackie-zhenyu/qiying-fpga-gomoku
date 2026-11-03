`timescale 1ns/1ps
`default_nettype none
// Expanded radial results plus an intersection observation from the SAME
// frozen frame. Capture identities are latched when acquisition starts.
module qy_stone_game_detector #(
 parameter OFFSET_FILE="stone_ring_offsets.hex"
)(
 input wire clk,rst_n,camera_ready,input wire [23:0] rgb,input wire de,vs,
 input wire [191:0] context_i,input wire [31:0] safety_epoch_i,input wire [63:0] now_us,
 input wire calibrate_request,input wire [2872:0] nominal_points,
 output reg result_valid,output reg [6143:0] boxes,output reg [7:0] box_count,
 output reg [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
 output reg [7:0] error,output wire busy,
 output wire observation_valid,output wire [337:0] cells,output wire [168:0] observable,
 output wire [1351:0] confidence,output wire [15:0] quality,output wire board_observable,
 output reg [191:0] observation_context,output reg [31:0] observation_epoch,
 output reg [63:0] observation_frame,observation_time,
 output wire calibrated,calibration_done,calibration_success,output wire [2872:0] points
);
 localparam IDLE=0,CAPTURE=1,DETECT=2,CONFIRM_INIT=3,CONFIRM_CHECK=4,PUBLISH=5,OBSERVE=6,
  CONFIRM_CURRENT=7,CONFIRM_LOAD=8,CONFIRM_MATCH=9,CONFIRM_WRITE=10;
 reg [3:0] state;
 reg [11:0] x,y;reg [2:0] xm,ym;reg de_d,vs_d,bad;
 reg [16:0] samples;reg [31:0] frame_counter,capture_frame,elapsed;
 reg [63:0] frame_counter64;
 reg calibrate_pending,run_calibrate;reg [2872:0] run_nominal;
 wire frame_edge=vs&&!vs_d;
 wire active=state==CAPTURE&&!bad&&!frame_edge&&camera_ready&&de&&x<1920&&y<1080;
 wire [9:0] gray_sum={2'b0,rgb[23:16]}+{1'b0,rgb[15:8],1'b0}+{2'b0,rgb[7:0]};
 wire [7:0] gray=gray_sum[9:2];
 wire paper=({1'b0,rgb[23:16]}+9'd12>={1'b0,rgb[15:8]})&&
  ({1'b0,rgb[7:0]}<={1'b0,rgb[15:8]}+9'd20)&&
  ({1'b0,rgb[23:16],2'b0}<={1'b0,rgb[7:0],2'b0}+{3'd0,rgb[15:8]}+11'd16);
 // 320 block accumulators are synchronous, with no reset on their RAM ports.
 (* ram_style="bram" *) reg [7:0] block_min[0:511];
 (* ram_style="bram" *) reg [8:0] block_center[0:511];
 reg [8:0] block_col;
 (* keep="true" *) reg [8:0] block_read_address,block_write_address,center_write_address;
 reg [7:0] block_read_min,block_write_min,row_min;
 reg [8:0] center_read,center_write,sample_center;
 reg block_we,center_we;
 wire [7:0] row_min_next=xm==0?gray:(gray<row_min?gray:row_min);
 wire [7:0] block_min_next=ym==0?row_min_next:(row_min_next<block_read_min?row_min_next:block_read_min);
 always @(posedge clk)begin
  block_read_min<=block_min[block_read_address];center_read<=block_center[block_read_address];
  if(block_we)block_min[block_write_address]<=block_write_min;
  if(center_we)block_center[center_write_address]<=center_write;
 end
 (* ram_style="bram" *) reg [16:0] raw[0:65535];
 (* keep="true" *) reg [15:0] write_address;
 reg [16:0] write_data,raw_data;reg write_enable;
 wire [15:0] core_address,observer_address;
 wire [15:0] read_address=state==OBSERVE?observer_address:core_address;
 always @(posedge clk)begin
  if(write_enable)raw[write_address]<=write_data;
  raw_data<=raw[read_address];
 end
 reg core_start,observer_start;
 wire core_busy,core_done,core_overflow,observer_busy,observer_done;
 wire [6143:0] core_boxes;wire [7:0] core_count;wire [31:0] core_cycles;
 qy_stone_ring_core_game #(.OFFSET_FILE(OFFSET_FILE)) core(
  .clk(clk),.rst_n(rst_n),.start(core_start),.busy(core_busy),.done(core_done),.overflow(core_overflow),
  .raw_address(core_address),.raw_data(raw_data[8:0]),.boxes(core_boxes),.box_count(core_count),.cycles(core_cycles));
 qy_grid_observer observer(.clk(clk),.rst_n(rst_n),.start(observer_start),.calibrate(run_calibrate),
  .nominal_points(run_nominal),.boxes(boxes),.box_count(run_calibrate?core_count:box_count),.detector_error(error),
  .raw_address(observer_address),.raw_data(raw_data),.busy(observer_busy),.done(observer_done),
  .observation_valid(observation_valid),.calibration_done(calibration_done),.calibration_success(calibration_success),
  .calibrated(calibrated),.points(points),.cells(cells),.observable(observable),.confidence(confidence),
  .quality(quality),.board_observable(board_observable));
 reg [6143:0] previous,confirmed;
 reg [7:0] current_index,previous_index,confirmed_count;reg matched;
 reg [31:0] current_word,previous_word;
 reg match_registered;
 wire [8:0] dx=current_word[8:0]>=previous_word[8:0]?current_word[8:0]-previous_word[8:0]:previous_word[8:0]-current_word[8:0];
 wire [7:0] dy=current_word[16:9]>=previous_word[16:9]?current_word[16:9]-previous_word[16:9]:previous_word[16:9]-current_word[16:9];
 wire [3:0] dr=current_word[20:17]>=previous_word[20:17]?current_word[20:17]-previous_word[20:17]:previous_word[20:17]-current_word[20:17];
 wire match_now=current_word[23]&&previous_word[23]&&current_word[22:21]==previous_word[22:21]&&dx<=24&&dy<=24&&dr<=2;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;x<=0;y<=0;xm<=0;ym<=0;de_d<=0;vs_d<=0;bad<=0;samples<=0;
   frame_counter<=0;frame_counter64<=0;capture_frame<=0;elapsed<=0;
   write_address<=0;write_data<=0;write_enable<=0;core_start<=0;observer_start<=0;
   block_col<=0;block_read_address<=0;block_write_address<=0;center_write_address<=0;
   block_write_min<=0;row_min<=0;center_write<=0;sample_center<=0;block_we<=0;center_we<=0;
   previous<=0;confirmed<=0;current_index<=0;previous_index<=0;confirmed_count<=0;matched<=0;
   current_word<=0;previous_word<=0;match_registered<=0;
   result_valid<=0;boxes<=0;box_count<=0;result_sequence<=0;source_frame<=0;compute_cycles<=0;total_cycles<=0;error<=0;
   calibrate_pending<=0;run_calibrate<=0;run_nominal<=0;
   observation_context<=0;observation_epoch<=0;observation_frame<=0;observation_time<=0;
  end else begin
   result_valid<=0;core_start<=0;observer_start<=0;de_d<=de;vs_d<=vs;
   write_enable<=0;block_we<=0;center_we<=0;
   if(calibrate_request)calibrate_pending<=1;
   if(state!=IDLE)elapsed<=elapsed+1'b1;
   if(frame_edge)begin
    frame_counter<=frame_counter+1'b1;frame_counter64<=frame_counter64+1'b1;
    x<=0;y<=0;xm<=0;ym<=0;block_col<=0;
   end else if(de)begin
    if(x<4095)x<=x+1'b1;xm<=xm==5?0:xm+1'b1;
    if(xm==5)block_col<=block_col+1'b1;
   end else begin
    x<=0;xm<=0;block_col<=0;
    if(de_d)begin if(y<4095)y<=y+1'b1;ym<=ym==5?0:ym+1'b1;end
   end
   if(active)begin
    row_min<=row_min_next;
    if(xm==0)block_read_address<=block_col;
    if(xm==1&&ym==1)sample_center<={paper,gray};
    if(xm==5)begin
     block_write_address<=block_col;block_write_min<=block_min_next;block_we<=1;
     if(ym==1)begin center_write_address<=block_col;center_write<=sample_center;center_we<=1;end
     if(ym==5&&samples<57600)begin
      write_enable<=1;write_address<=samples[15:0];write_data<={block_min_next,center_read};samples<=samples+1'b1;
     end
    end
   end
   case(state)
    IDLE:if(frame_edge&&camera_ready)begin
     samples<=0;bad<=0;elapsed<=0;capture_frame<=frame_counter+1'b1;state<=CAPTURE;
     observation_context<=context_i;observation_epoch<=safety_epoch_i;
     observation_frame<=frame_counter64+1'b1;observation_time<=now_us;
     run_calibrate<=calibrate_pending||calibrate_request;run_nominal<=nominal_points;
     if(calibrate_pending||calibrate_request)calibrate_pending<=0;
    end
    CAPTURE:begin
     if(!camera_ready||(de&&(x>=1920||y>=1080))||(!de&&de_d&&x!=1920))bad<=1;
     if(frame_edge)begin
      if(!bad&&camera_ready&&!de&&y==1080&&samples==57600)begin core_start<=1;state<=DETECT;end
      else begin
       previous<=0;boxes<=0;box_count<=0;error<=8'd2;result_valid<=1;
       result_sequence<=result_sequence+1'b1;source_frame<=capture_frame;compute_cycles<=0;total_cycles<=elapsed;
       observer_start<=1;state<=OBSERVE;
      end
     end
    end
    DETECT:if(core_done)begin
     compute_cycles<=core_cycles;confirmed<=0;confirmed_count<=0;current_index<=0;
     error<=core_overflow?8'd1:8'd0;state<=CONFIRM_INIT;
    end
    CONFIRM_INIT:begin
     previous_index<=0;matched<=0;
     if(current_index==192)state<=PUBLISH;
     else begin current_word<=core_boxes[current_index*32+:32];state<=CONFIRM_CURRENT;end
    end
    CONFIRM_CURRENT:begin
     if(!current_word[23])begin current_index<=current_index+1'b1;state<=CONFIRM_INIT;end
     else state<=CONFIRM_LOAD;
    end
    CONFIRM_LOAD:begin previous_word<=previous[previous_index*32+:32];state<=CONFIRM_MATCH;end
    CONFIRM_MATCH:begin match_registered<=match_now;state<=CONFIRM_CHECK;end
    CONFIRM_CHECK:begin
     if(match_registered)matched<=1;
     if(previous_index==191)state<=CONFIRM_WRITE;
     else begin previous_index<=previous_index+1'b1;state<=CONFIRM_LOAD;end
    end
    CONFIRM_WRITE:begin
     if(matched)begin confirmed[current_index*32+:32]<=current_word;confirmed_count<=confirmed_count+1'b1;end
     current_index<=current_index+1'b1;state<=CONFIRM_INIT;
    end
    PUBLISH:begin
     previous<=camera_ready&&!core_overflow?core_boxes:6144'd0;
     boxes<=camera_ready&&!core_overflow?confirmed:6144'd0;box_count<=camera_ready&&!core_overflow?confirmed_count:8'd0;
     if(!camera_ready)error<=8'd4;
     result_valid<=1;result_sequence<=result_sequence+1'b1;source_frame<=capture_frame;total_cycles<=elapsed;
     observer_start<=1;state<=OBSERVE;
    end
    OBSERVE:if(observer_done)state<=IDLE;
    default:begin state<=IDLE;boxes<=0;previous<=0;box_count<=0;error<=8'd8;end
   endcase
  end
 end
endmodule
`default_nettype wire
