`timescale 1ns/1ps
`default_nettype none
// Setup retains the accepted radial preview. Once calibrated, each frozen
// frame goes directly to image-only grid probes; radial merging cannot erase
// crowded stones. The formal guard still requires multiple fresh frames.
module qy_stone_grid_detector #(
 parameter AUTO_SIZE=0, parameter ORIGIN_OPENING=0, parameter OFFSET_FILE="stone_ring_offsets.hex",
 parameter PROBE_OFFSET_FILE="grid_probe_offsets.hex",
 parameter CALIBRATION_LEVEL_HANDSHAKE=0
)(
 input wire clk,rst_n,camera_ready,input wire [23:0] rgb,input wire de,vs,
 input wire [191:0] context_i,input wire [31:0] safety_epoch_i,input wire [63:0] now_us,
 input wire calibrate_request,input wire anchor_mode,input wire [2872:0] nominal_points,
 output wire anchor_seed_valid,output wire [7:0] anchor_seed_index,
 output wire signed [2:0] track_tx,track_ty,output wire signed [4:0] track_sx,track_sy,
 output reg result_valid,output wire [6143:0] boxes,output reg [7:0] box_count,
 output reg [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
 output reg [7:0] error,output wire busy,
 output wire observation_valid,output wire [337:0] cells,output wire [168:0] observable,
 output wire [1351:0] confidence,output wire [15:0] quality,output wire board_observable,
 output reg [191:0] observation_context,output reg [31:0] observation_epoch,
 output reg [63:0] observation_frame,observation_time,
 output wire [3:0] board_size,
 output wire calibrated,output reg calibration_done,calibration_success,output wire [2872:0] points
 ,output wire [191:0] calibration_diag_data,output wire [7:0] calibration_diag_events
);
 localparam IDLE=0,CAPTURE=1,DETECT=2,CONFIRM_INIT=3,CONFIRM_CHECK=4,PUBLISH=5,OBSERVE=6,
  CONFIRM_CURRENT=7,CONFIRM_LOAD=8,CONFIRM_MATCH=9,CONFIRM_WRITE=10,LOCATE=11,
  PUBLISH_WAIT=12,GRID_PUBLISH_WAIT=13,BAD_PUBLISH_WAIT=14,
  CORE_WORD_WAIT=15,CORE_WORD_USE=16,PREVIOUS_WORD_WAIT=17,PREVIOUS_WORD_USE=18;
 reg [4:0] state;
 reg [11:0] x,y;reg [2:0] xm,ym;reg de_d,vs_d,bad;
 reg [16:0] samples;reg [31:0] frame_counter,capture_frame,elapsed;
 reg [63:0] frame_counter64;
 // Capture pixels/context at the original frame edge; tag the accepted frame
 // one clock later from the already incremented counters. This isolates the
 // wide tag enables from the frame-edge/state decode and removes tag adders.
 reg capture_tag_pending;
 reg [15:0] diag_accept_count,diag_finish_count;
 reg diag_accept_event,diag_finish_event,diag_capture_event;
 reg run_grid,compute_lost;reg [31:0] compute_start;
 reg calibrate_pending,run_calibrate,run_anchor_mode;reg [2872:0] run_nominal;
 wire observer_calibration_done,observer_calibration_success;
 wire [7:0] locator_anchor_index,locator_error;
 reg locator_retry;
 wire frame_edge=vs&&!vs_d;
 // In level mode the requester itself retains a waiting transaction. A
 // held completion blocks a second acceptance until req/done return low.
 // Keep the pulse/pending contract for legacy callers by default.
 wire calibration_requested=CALIBRATION_LEVEL_HANDSHAKE?
  (calibrate_request&&!calibration_done):(calibrate_pending||calibrate_request);
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
 wire [15:0] core_address,observer_address,locator_address;
 wire locator_done,locator_success;wire [3:0] locator_size;wire [2872:0] locator_points;
 reg locator_start;reg [3:0] run_size;
 wire [15:0] read_address=state==LOCATE?locator_address:state==OBSERVE?observer_address:core_address;
 always @(posedge clk)begin
  if(write_enable)raw[write_address]<=write_data;
  raw_data<=raw[read_address];
 end
 reg core_start,observer_start;
 wire core_busy,core_done,core_overflow,observer_busy,observer_done;
 wire [6143:0] core_boxes;wire [7:0] core_count;wire [31:0] core_cycles;
 wire seed_ok=core_count==1&&!core_overflow&&core_boxes[23]&&core_boxes[22:21]==2'd1;
 generate if(AUTO_SIZE)begin:auto_grid
 qy_grid_autoselect locator(.clk(clk),.rst_n(rst_n),.start(locator_start),
  .anchor_mode(run_anchor_mode),.seed_valid(seed_ok),.seed_x(core_boxes[8:0]),.seed_y(core_boxes[16:9]),
  .retry_next(locator_retry),.anchor_row(),.anchor_col(),.anchor_index(locator_anchor_index),.error_reason(locator_error),
  .busy(),.done(locator_done),.success(locator_success),.board_size(locator_size),.points(locator_points),
  .raw_address(locator_address),.raw_data(raw_data),.cycles());
 end else begin:manual_grid
  assign locator_done=1'b0;assign locator_success=1'b0;assign locator_size=4'd13;
  assign locator_points=2873'd0;assign locator_address=16'd0;
  assign locator_anchor_index=8'd255;assign locator_error=8'd0;
 end endgenerate
 qy_stone_ring_core_game #(.OFFSET_FILE(OFFSET_FILE)) core(
  .clk(clk),.rst_n(rst_n),.start(core_start),.busy(core_busy),.done(core_done),.overflow(core_overflow),
  .raw_address(core_address),.raw_data(raw_data[8:0]),.boxes(core_boxes),.box_count(core_count),.cycles(core_cycles));
 wire [6143:0] grid_boxes;wire [7:0] grid_count;
 qy_grid_observer_v2 #(.DYNAMIC_SIZE(AUTO_SIZE),.ORIGIN_OPENING(ORIGIN_OPENING&&AUTO_SIZE),.PROBE_OFFSET_FILE(PROBE_OFFSET_FILE)) observer(.clk(clk),.rst_n(rst_n),.start(observer_start),.calibrate(run_calibrate),
  .anchor_mode(run_anchor_mode),.anchor_index_i(locator_anchor_index),
  .anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),
  .track_tx(track_tx),.track_ty(track_ty),.track_sx(track_sx),.track_sy(track_sy),
  .nominal_points(run_nominal),.nominal_size(run_size),.board_size(board_size),
  .box_count(run_calibrate&&(!AUTO_SIZE||run_anchor_mode)?core_count:8'd0),.detector_error(error),
  .raw_address(observer_address),.raw_data(raw_data),.busy(observer_busy),.done(observer_done),
  .observation_valid(observation_valid),.calibration_done(observer_calibration_done),.calibration_success(observer_calibration_success),
  .calibrated(calibrated),.points(points),.cells(cells),.observable(observable),.confidence(confidence),
  .quality(quality),.board_observable(board_observable),.observed_boxes(grid_boxes),.observed_count(grid_count));
 wire [6143:0] previous,confirmed;
 reg previous_start,previous_zero,confirmed_clear,confirmed_write,boxes_start,boxes_zero,publish_grid;
 reg [7:0] confirmed_index;reg [31:0] confirmed_data;
 wire previous_busy,confirmed_busy,boxes_busy;
 qy_banked_records previous_bank(.clk(clk),.rst_n(rst_n),.capture_start(previous_start),
  .capture_zero(previous_zero),.capture_data(core_boxes),.write_valid(1'b0),.write_index(8'd0),.write_data(32'd0),
  .busy(previous_busy),.done(),.records(previous));
 qy_banked_records confirmed_bank(.clk(clk),.rst_n(rst_n),.capture_start(confirmed_clear),
  .capture_zero(1'b1),.capture_data(6144'd0),.write_valid(confirmed_write),.write_index(confirmed_index),.write_data(confirmed_data),
  .busy(confirmed_busy),.done(),.records(confirmed));
 qy_banked_records publication_bank(.clk(clk),.rst_n(rst_n),.capture_start(boxes_start),
  .capture_zero(boxes_zero),.capture_data(publish_grid?grid_boxes:confirmed),.write_valid(1'b0),.write_index(8'd0),.write_data(32'd0),
  .busy(boxes_busy),.done(),.records(boxes));
 reg [7:0] current_index,previous_index,confirmed_count;reg matched;
 reg [31:0] current_word,previous_word;
 reg match_registered;
 wire [31:0] core_read_word,previous_read_word;
 qy_banked_record_reader core_reader(.clk(clk),.records(core_boxes),.index(current_index),.data(core_read_word));
 qy_banked_record_reader previous_reader(.clk(clk),.records(previous),.index(previous_index),.data(previous_read_word));
 wire [8:0] dx=current_word[8:0]>=previous_word[8:0]?current_word[8:0]-previous_word[8:0]:previous_word[8:0]-current_word[8:0];
 wire [7:0] dy=current_word[16:9]>=previous_word[16:9]?current_word[16:9]-previous_word[16:9]:previous_word[16:9]-current_word[16:9];
 wire [3:0] dr=current_word[20:17]>=previous_word[20:17]?current_word[20:17]-previous_word[20:17]:previous_word[20:17]-current_word[20:17];
 wire match_now=current_word[23]&&previous_word[23]&&current_word[22:21]==previous_word[22:21]&&dx<=24&&dy<=24&&dr<=2;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;locator_start<=0;locator_retry<=0;run_anchor_mode<=0;calibration_done<=0;calibration_success<=0;run_size<=13;x<=0;y<=0;xm<=0;ym<=0;de_d<=0;vs_d<=0;bad<=0;samples<=0;
   frame_counter<=0;frame_counter64<=0;capture_frame<=0;elapsed<=0;capture_tag_pending<=0;
   diag_accept_count<=0;diag_finish_count<=0;diag_accept_event<=0;diag_finish_event<=0;diag_capture_event<=0;
   write_address<=0;write_data<=0;write_enable<=0;core_start<=0;observer_start<=0;
   block_col<=0;block_read_address<=0;block_write_address<=0;center_write_address<=0;
   block_write_min<=0;row_min<=0;center_write<=0;sample_center<=0;block_we<=0;center_we<=0;
   previous_start<=0;previous_zero<=0;confirmed_clear<=0;confirmed_write<=0;confirmed_index<=0;confirmed_data<=0;
   boxes_start<=0;boxes_zero<=0;publish_grid<=0;current_index<=0;previous_index<=0;confirmed_count<=0;matched<=0;
   current_word<=0;previous_word<=0;match_registered<=0;
   result_valid<=0;box_count<=0;result_sequence<=0;source_frame<=0;compute_cycles<=0;total_cycles<=0;error<=0;
   calibrate_pending<=0;run_calibrate<=0;run_nominal<=0;run_grid<=0;compute_lost<=0;compute_start<=0;
   observation_context<=0;observation_epoch<=0;observation_frame<=0;observation_time<=0;
  end else begin
   result_valid<=0;
   capture_tag_pending<=0;diag_accept_event<=0;diag_finish_event<=0;diag_capture_event<=0;
   if(capture_tag_pending)begin capture_frame<=frame_counter;observation_frame<=frame_counter64;end
   // Consumers latch this tag only with result_valid. Following the stable
   // captured tag continuously removes the former publication-state CE path.
   source_frame<=capture_frame;
   if(!CALIBRATION_LEVEL_HANDSHAKE||!calibrate_request)calibration_done<=0;
   core_start<=0;observer_start<=0;locator_start<=0;locator_retry<=0;de_d<=de;vs_d<=vs;
   previous_start<=0;confirmed_clear<=0;confirmed_write<=0;boxes_start<=0;
   write_enable<=0;block_we<=0;center_we<=0;
   if(!CALIBRATION_LEVEL_HANDSHAKE&&calibrate_request)calibrate_pending<=1;
   if(state!=IDLE)elapsed<=elapsed+1'b1;
   if(state!=IDLE&&!camera_ready)compute_lost<=1;
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
     samples<=0;bad<=0;elapsed<=0;compute_lost<=0;run_grid<=0;capture_tag_pending<=1;diag_capture_event<=1;state<=CAPTURE;
     observation_context<=context_i;observation_epoch<=safety_epoch_i;
     observation_time<=now_us;
     if(calibration_requested)begin
      if(diag_accept_count!=16'hffff)diag_accept_count<=diag_accept_count+1'b1;
      diag_accept_event<=1;
     end
     run_calibrate<=calibration_requested;run_nominal<=nominal_points;
     run_anchor_mode<=ORIGIN_OPENING&&AUTO_SIZE&&anchor_mode;
     if(!CALIBRATION_LEVEL_HANDSHAKE&&(calibrate_pending||calibrate_request))calibrate_pending<=0;
    end
    CAPTURE:begin
     if(!camera_ready||(de&&(x>=1920||y>=1080))||(!de&&de_d&&x!=1920))bad<=1;
     if(frame_edge)begin
      if(!bad&&camera_ready&&!de&&y==1080&&samples==57600)begin
       if(AUTO_SIZE&&run_calibrate)begin
        compute_start<=elapsed;error<=0;
        if(run_anchor_mode)begin core_start<=1;state<=DETECT;end
        else begin locator_start<=1;state<=LOCATE;end
       end
       else if(calibrated&&!run_calibrate)begin run_grid<=1;compute_start<=elapsed;error<=0;observer_start<=1;state<=OBSERVE;end
       else begin run_grid<=0;core_start<=1;state<=DETECT;end
      end
      else begin
       previous_start<=1;previous_zero<=1;boxes_start<=1;boxes_zero<=1;box_count<=0;error<=8'd2;
       compute_cycles<=0;state<=BAD_PUBLISH_WAIT;
      end
     end
    end
    LOCATE:if(locator_done)begin
     run_nominal<=locator_points;run_size<=locator_success?locator_size:4'd0;
     error<=locator_success?8'd0:8'd16;observer_start<=1;state<=OBSERVE;
    end
    DETECT:if(core_done)begin
     compute_cycles<=core_cycles;confirmed_clear<=1;confirmed_count<=0;current_index<=0;
     if(AUTO_SIZE&&run_calibrate&&run_anchor_mode)begin
      if(seed_ok)begin error<=0;locator_start<=1;state<=LOCATE;end
      else begin error<=8'd17;run_size<=0;observer_start<=1;state<=OBSERVE;end
     end else begin error<=core_overflow?8'd1:8'd0;state<=CONFIRM_INIT;end
    end
    CONFIRM_INIT:if(!confirmed_clear&&!confirmed_busy&&!confirmed_write)begin
     previous_index<=0;matched<=0;
     if(current_index==192)state<=PUBLISH;
     else state<=CORE_WORD_WAIT;
    end
    CORE_WORD_WAIT:state<=CORE_WORD_USE;
    CORE_WORD_USE:begin current_word<=core_read_word;state<=CONFIRM_CURRENT;end
    CONFIRM_CURRENT:begin
     if(!current_word[23])begin current_index<=current_index+1'b1;state<=CONFIRM_INIT;end
     else state<=CONFIRM_LOAD;
    end
    CONFIRM_LOAD:state<=PREVIOUS_WORD_WAIT;
    PREVIOUS_WORD_WAIT:state<=PREVIOUS_WORD_USE;
    PREVIOUS_WORD_USE:begin previous_word<=previous_read_word;state<=CONFIRM_MATCH;end
    CONFIRM_MATCH:begin match_registered<=match_now;state<=CONFIRM_CHECK;end
    CONFIRM_CHECK:begin
     if(match_registered)matched<=1;
     if(previous_index==191)state<=CONFIRM_WRITE;
     else begin previous_index<=previous_index+1'b1;state<=CONFIRM_LOAD;end
    end
    CONFIRM_WRITE:begin
     if(matched)begin confirmed_write<=1;confirmed_index<=current_index;confirmed_data<=current_word;confirmed_count<=confirmed_count+1'b1;end
     current_index<=current_index+1'b1;state<=CONFIRM_INIT;
    end
    PUBLISH:begin
     previous_start<=1;previous_zero<=!camera_ready||core_overflow;
     boxes_start<=1;boxes_zero<=!camera_ready||core_overflow;publish_grid<=0;state<=PUBLISH_WAIT;
    end
    PUBLISH_WAIT:begin
     // Loss while copying invalidates the complete result before its pulse.
     if(!camera_ready&&!boxes_zero)begin boxes_start<=1;boxes_zero<=1;previous_start<=1;previous_zero<=1;end
     else if(!boxes_start&&!previous_start&&!boxes_busy&&!previous_busy)begin
     box_count<=boxes_zero?8'd0:confirmed_count;
     if(boxes_zero&&!core_overflow)error<=8'd4;
     result_valid<=1;result_sequence<=result_sequence+1'b1;total_cycles<=elapsed;
     observer_start<=1;state<=OBSERVE;
     end
    end
    OBSERVE:if(observer_done)begin
     if(run_grid)begin
      boxes_start<=1;boxes_zero<=!camera_ready||compute_lost;publish_grid<=1;state<=GRID_PUBLISH_WAIT;
     end else if(run_calibrate&&observer_calibration_done)begin
      // Intermediate candidate failures remain inside the same frozen image.
      // Controls see only final success or exhaustion, never a retry failure.
      if(AUTO_SIZE&&!observer_calibration_success&&locator_success&&error==0&&camera_ready&&!compute_lost)begin
       locator_retry<=1;state<=LOCATE;
      end else begin
       calibration_done<=1;calibration_success<=observer_calibration_success&&camera_ready&&!compute_lost;state<=IDLE;
       if(diag_finish_count!=16'hffff)diag_finish_count<=diag_finish_count+1'b1;
       diag_finish_event<=1;
      end
     end else state<=IDLE;
    end
    GRID_PUBLISH_WAIT:begin
     if((!camera_ready||compute_lost)&&!boxes_zero)begin boxes_start<=1;boxes_zero<=1;end
     else if(!boxes_start&&!boxes_busy)begin
      box_count<=boxes_zero?8'd0:grid_count;
      if(boxes_zero)error<=8'd4;
      result_valid<=1;result_sequence<=result_sequence+1'b1;
      compute_cycles<=elapsed-compute_start;total_cycles<=elapsed;state<=IDLE;
     end
    end
    BAD_PUBLISH_WAIT:if(!boxes_start&&!previous_start&&!boxes_busy&&!previous_busy)begin
     result_valid<=1;result_sequence<=result_sequence+1'b1;total_cycles<=elapsed;
     observer_start<=1;state<=OBSERVE;
    end
    default:begin state<=IDLE;boxes_start<=1;boxes_zero<=1;previous_start<=1;previous_zero<=1;box_count<=0;error<=8'd8;end
   endcase
  end
 end
 // Read-only calibration evidence. These registers never feed the detector,
 // controls or game. Retain transaction evidence across ordinary previews.
 reg diag_request_d,diag_transaction_live;reg [4:0] diag_state_d;
 reg [15:0] diag_sticky,diag_last_quality;
 reg [7:0] diag_last_error,diag_last_locator_error;
 reg diag_stage_event,diag_error_event;
 wire diag_new_request=calibrate_request&&!diag_request_d;
 reg [15:0] diag_event_mask;
 reg [7:0] diag_error_now;
 wire diag_cal_capture=run_calibrate&&state==CAPTURE&&frame_edge;
 wire diag_capture_good=!bad&&camera_ready&&!de&&y==1080&&samples==57600;
 wire diag_cal_core=run_calibrate&&state==DETECT&&core_done;
 wire diag_cal_locator=run_calibrate&&state==LOCATE&&locator_done;
 wire diag_cal_observer=run_calibrate&&state==OBSERVE&&observer_done;
 wire diag_retry=diag_cal_observer&&!run_grid&&observer_calibration_done&&AUTO_SIZE&&
  !observer_calibration_success&&locator_success&&error==0&&camera_ready&&!compute_lost;
 always @*begin
  diag_event_mask=0;diag_error_now=0;
  if(diag_new_request)diag_event_mask[0]=1;
  if(diag_accept_event)diag_event_mask[1]=1;
  if(diag_cal_capture)begin
   if(diag_capture_good)diag_event_mask[2]=1;
   else begin diag_event_mask[3]=1;diag_error_now=8'd2;end
  end
  if(diag_cal_core)begin
   diag_event_mask[4]=1;
   if(AUTO_SIZE&&run_anchor_mode&&!seed_ok)begin diag_event_mask[5]=1;diag_error_now=8'd17;end
  end
  if(diag_cal_locator)begin
   diag_event_mask[6]=1;diag_event_mask[7]=locator_success;
   if(!locator_success)diag_error_now=8'd16;
  end
  if(diag_cal_observer)begin
   diag_event_mask[8]=1;diag_event_mask[9]=observer_calibration_done;
   diag_event_mask[10]=observer_calibration_done&&observer_calibration_success;
  end
  if(diag_retry)diag_event_mask[11]=1;
  if(diag_finish_event)begin diag_event_mask[12]=1;diag_event_mask[13]=calibration_success;end
  if((diag_transaction_live||diag_new_request)&&!camera_ready)diag_event_mask[14]=1;
  if(run_calibrate&&state>PREVIOUS_WORD_USE)begin diag_event_mask[15]=1;diag_error_now=8'd8;end
 end
 wire [15:0] diag_new_bits=diag_event_mask&~(diag_new_request?16'd0:diag_sticky);
 always @(posedge clk)begin
  if(!rst_n)begin
   diag_request_d<=0;diag_transaction_live<=0;diag_state_d<=IDLE;
   diag_sticky<=0;diag_last_quality<=0;diag_last_error<=0;diag_last_locator_error<=0;
   diag_stage_event<=0;diag_error_event<=0;
  end else begin
   diag_request_d<=calibrate_request;diag_state_d<=state;
   diag_stage_event<=(|diag_new_bits)||(run_calibrate&&state!=diag_state_d);
   diag_error_event<=(diag_error_now!=0)||diag_new_bits[14]||diag_new_bits[15];
   diag_sticky<=(diag_new_request?16'd0:diag_sticky)|diag_event_mask;
   if(diag_new_request)begin
    diag_transaction_live<=1;diag_last_quality<=0;diag_last_error<=0;diag_last_locator_error<=0;
   end
   if(diag_finish_event)diag_transaction_live<=0;
   if(diag_error_now!=0)diag_last_error<=diag_error_now;
   if(diag_cal_locator&&locator_error!=0)diag_last_locator_error<=locator_error;
   if(diag_cal_observer)diag_last_quality<=quality;
  end
 end
 wire [15:0] diag_flags={(&diag_accept_count)||(&diag_finish_count),2'b00,
  observer_calibration_success,observer_calibration_done,locator_success,observer_busy,core_busy,
  calibrated,bad,compute_lost,camera_ready,calibration_success,calibration_done,run_calibrate,calibrate_request};
 assign calibration_diag_data={capture_frame,diag_last_quality,quality,diag_last_locator_error,
  diag_last_error,error,3'd0,state,diag_flags,diag_sticky,16'd0,diag_finish_count,diag_accept_count,16'd0};
 assign calibration_diag_events={1'b0,diag_capture_event,diag_error_event,diag_stage_event,
  1'b0,diag_finish_event,diag_accept_event,1'b0};
endmodule
`default_nettype wire
