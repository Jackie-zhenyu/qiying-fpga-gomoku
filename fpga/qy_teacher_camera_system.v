`timescale 1ns/1ps
`default_nettype none
// 056 application: original image-only detector -> tagged queue -> teacher.
// Calibration geometry and its first black anchor persist across lesson changes.
module qy_teacher_camera_system #(
 parameter CLK_HZ=137500000,DEBOUNCE_MS=20,NFC_ENABLE=0,VOICE_PROFILE_READY=0,
 parameter [47:0] VOICE_COMMAND_IDS=48'h060504030201,
 parameter [119:0] VOICE_PHRASE_IDS=120'h1817161514131211100f0e0d0c0b0a,
 parameter [3:0] CARD_ENABLE=0,parameter [319:0] CARD_UIDS=0,parameter [15:0] CARD_LENGTHS=0,
 parameter SEARCH_DEPTH=3,SEARCH_NODES=20000,
 parameter OFFSET_FILE="stone_ring_offsets.hex"
)(
 input wire clk,rst_n,camera_ready,input wire [3:0] keys_n,
 input wire [23:0] rgb,input wire de,vs,input wire nfc_rx,voice_rx,output wire nfc_tx,voice_tx,
 output wire result_valid,output wire [6143:0] boxes,output wire [7:0] box_count,error,
 output wire [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
 output wire [337:0] board,setup_board,output wire [2:0] mode,pending_mode,output wire [3:0] stage,
 output wire [1:0] hint_level,output wire [168:0] hint_targets,output wire [7:0] hint_target,
 output wire [3:0] board_size,output wire [1:0] side,next_color,winner,
 output wire [7:0] move_count,last_index,output wire last_valid,game_over,
 output wire [3:0] game_phase,output wire [7:0] phrase_id,
 output wire answer_correct,retry_valid,fault,
 output wire calibrated,calibrating,setup_error,origin_valid,output wire [7:0] origin_index,
 output wire target_valid,output wire [7:0] target_index,output wire [16:0] target_point,origin_point,
 output wire [67:0] corners,output wire [31:0] origin_status,
 output wire nfc_ready,nfc_fault,unknown_card,
 output wire event_valid,event_is_ai,output wire [7:0] event_index,output wire [1:0] event_color
);
 wire [3:0] key_press,key_held;
 qy_key_frontend #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) keys(
  .clk_i(clk),.arst_n_i(rst_n),.key_i(keys_n),.armed_o(),.pressed_o(key_held),
  .press_pulse_o(key_press),.release_pulse_o());
 wire detector_calibrated,calibrate_request,calibration_done,calibration_success;
 wire [31:0] calibration_version,safety_epoch;
 wire command_valid,manual_mode_valid;wire [2:0] command,manual_mode;
 qy_teacher_controls #(.CLK_HZ(CLK_HZ)) controls(
  .clk(clk),.rst_n(rst_n),.camera_ready(camera_ready),.detector_calibrated(detector_calibrated),
  .key_press(key_press),.key_held(key_held),.mode(mode),.pending_mode(pending_mode),.stage(stage),
  .calibration_done(calibration_done),.calibration_success(calibration_success),.calibrated(calibrated),
  .calibrating(calibrating),.setup_error(setup_error),.calibrate_request(calibrate_request),
  .calibration_version(calibration_version),.safety_epoch(safety_epoch),.command_valid(command_valid),
  .command(command),.mode_valid(manual_mode_valid),.requested_mode(manual_mode));
 reg [31:0] us_fraction;reg [63:0] now_us;
 always @(posedge clk)begin
  if(!rst_n)begin us_fraction<=0;now_us<=0;end
  else if(us_fraction>=CLK_HZ-1000000)begin us_fraction<=us_fraction-(CLK_HZ-1000000);now_us<=now_us+1'b1;end
  else us_fraction<=us_fraction+1000000;
 end
 wire [191:0] context_now,det_context;wire [31:0] det_epoch;
 wire [63:0] det_frame,det_time;wire det_valid,det_observable;
 wire [337:0] det_cells;wire [168:0] det_seen;wire [1351:0] det_confidence;wire [15:0] det_quality;
 wire [2872:0] points;wire anchor_seed_valid;wire [7:0] anchor_seed_index;
 wire signed [2:0] track_tx,track_ty;wire signed [4:0] track_sx,track_sy;
 qy_stone_grid_detector #(.AUTO_SIZE(1),.ORIGIN_OPENING(1),.OFFSET_FILE(OFFSET_FILE)) detector(
  .clk(clk),.rst_n(rst_n),.camera_ready(camera_ready),.rgb(rgb),.de(de),.vs(vs),
  .context_i(context_now),.safety_epoch_i(safety_epoch),.now_us(now_us),
  .calibrate_request(calibrate_request),.anchor_mode(1'b1),.nominal_points(2873'd0),
  .anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),
  .track_tx(track_tx),.track_ty(track_ty),.track_sx(track_sx),.track_sy(track_sy),
  .result_valid(result_valid),.boxes(boxes),.box_count(box_count),.result_sequence(result_sequence),
  .source_frame(source_frame),.compute_cycles(compute_cycles),.total_cycles(total_cycles),.error(error),.busy(),
  .observation_valid(det_valid),.cells(det_cells),.observable(det_seen),.confidence(det_confidence),
  .quality(det_quality),.board_observable(det_observable),.observation_context(det_context),.observation_epoch(det_epoch),
  .observation_frame(det_frame),.observation_time(det_time),.calibrated(detector_calibrated),
  .board_size(board_size),.calibration_done(calibration_done),.calibration_success(calibration_success),.points(points));
 reg queued,queue_observable;reg [191:0] queue_context,previous_context;reg [31:0] queue_epoch;
 reg [63:0] queue_frame,queue_time;reg [337:0] queue_cells;
 reg [168:0] queue_seen;reg [1351:0] queue_confidence;reg [15:0] queue_quality;
 wire observation_ready;
 always @(posedge clk)begin
  if(!rst_n)begin
   queued<=0;queue_observable<=0;queue_context<=0;previous_context<=0;queue_epoch<=0;queue_frame<=0;queue_time<=0;
   queue_cells<=0;queue_seen<=0;queue_confidence<=0;queue_quality<=0;
  end else begin
   previous_context<=context_now;
   if(queued&&observation_ready)queued<=0;
   if(det_valid)begin
    queued<=1;queue_observable<=det_observable;queue_context<=det_context;queue_epoch<=det_epoch;
    queue_frame<=det_frame;queue_time<=det_time;queue_cells<=det_cells;queue_seen<=det_seen;
    queue_confidence<=det_confidence;queue_quality<=det_quality|((queued&&!observation_ready)?16'h8000:16'd0);
   end
   // Discard old captured identities, never retag them to the new session.
   if(calibrate_request||calibration_done||previous_context!=context_now)queued<=0;
  end
 end
 wire ai_target;wire [7:0] ai_index;wire [3:0] formal_size;
 wire raw_game_over;wire [1:0] raw_winner;
 qy_teacher_preflight_top #(.CLK_HZ(CLK_HZ),.NFC_ENABLE(NFC_ENABLE),.VOICE_PROFILE_READY(VOICE_PROFILE_READY),
  .VOICE_COMMAND_IDS(VOICE_COMMAND_IDS),.VOICE_PHRASE_IDS(VOICE_PHRASE_IDS),
  .CARD_ENABLE(CARD_ENABLE),.CARD_UIDS(CARD_UIDS),.CARD_LENGTHS(CARD_LENGTHS),
  .ORIGIN_OPENING(1),.SEARCH_DEPTH(SEARCH_DEPTH),.SEARCH_NODES(SEARCH_NODES)) teacher(
  .clk(clk),.rst_n(rst_n),.now_us(now_us),.nfc_rx(nfc_rx),.voice_rx(voice_rx),.nfc_tx(nfc_tx),.voice_tx(voice_tx),
  .key_cmd_valid(command_valid),.key_cmd(command),.manual_mode_valid(manual_mode_valid),.manual_mode(manual_mode),
  .calibrated(calibrated),.safety_clear(camera_ready&&!calibrating),.board_size_i(board_size),
  .anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),
  .calibration_version(calibration_version),.safety_epoch(safety_epoch),
  .obs_valid(queued),.obs_ready(observation_ready),.obs_context(queue_context),.obs_safety_epoch(queue_epoch),
  .obs_frame(queue_frame),.obs_capture_us(queue_time),.obs_complete(1'b1),.obs_board_observable(queue_observable),
  .obs_quality(queue_quality),.obs_cells(queue_cells),.obs_observable(queue_seen),.obs_confidence(queue_confidence),
  .context_o(context_now),.board_o(board),.setup_board_o(setup_board),.mode_o(mode),.pending_mode_o(pending_mode),
  .stage_o(stage),.hint_level_o(hint_level),.hint_targets_o(hint_targets),.hint_target_o(hint_target),
  .size_o(formal_size),.side_o(side),.ai_target_valid(ai_target),.ai_target_index(ai_index),
  .game_phase(game_phase),.move_count(move_count),.game_over(raw_game_over),.winner(raw_winner),
  .next_color_o(next_color),.last_index_o(last_index),.last_valid_o(last_valid),
  .event_valid(event_valid),.event_is_ai(event_is_ai),.event_index(event_index),.event_color(event_color),
  .retry_valid(retry_valid),.answer_valid(),.answer_correct(answer_correct),.fault(fault),
  .phrase_valid(),.phrase_id(phrase_id),.nfc_ready(nfc_ready),.nfc_fault(nfc_fault),.unknown_card(unknown_card),
  .nfc_errors(),.uid_valid(),.uid(),.uid_length());
 assign game_over=mode==3&&raw_game_over;
 assign winner=mode==3?raw_winner:2'd0;
 assign origin_valid=calibrated&&anchor_seed_valid;
 assign origin_index=anchor_seed_index;
 assign target_index=ai_target?ai_index:hint_target;
 assign target_valid=calibrated&&stage==2&&pending_mode==0&&
  (ai_target||(hint_level==2&&hint_targets!=0))&&target_index<169&&
  target_index/13<board_size&&target_index%13<board_size;
 assign origin_status={5'd0,anchor_seed_valid,(mode==3&&game_phase==11),origin_valid,origin_index,det_quality};
 function automatic signed [5:0] model_delta;
  input signed [2:0] t;input signed [4:0] slope;input [3:0] coordinate,origin;
  reg signed [5:0] distance;reg signed [10:0] product,rounded;
  begin distance=$signed({2'b00,coordinate})-$signed({2'b00,origin});
   product=slope*distance;rounded=product+11'sd8;
   model_delta=$signed({{3{t[2]}},t})+(rounded>>>4);end
 endfunction
 function automatic [16:0] corrected_point;
  input [7:0] index;
  input [2872:0] grid_points;
  input valid_origin;input [7:0] seed_index;
  input signed [2:0] tx,ty;input signed [4:0] sx,sy;
  reg [16:0] base;reg signed [5:0] dx,dy;reg signed [10:0] xs;reg signed [9:0] ys;
  begin
   corrected_point=0;
   if(index<169&&valid_origin)begin
    base=grid_points[index*17+:17];
    dx=model_delta(tx,sx,index/13,seed_index/13);
    dy=model_delta(ty,sy,index%13,seed_index%13);
    xs=$signed({2'b00,base[8:0]})+$signed({{5{dx[5]}},dx});
    ys=$signed({2'b00,base[16:9]})+$signed({{4{dy[5]}},dy});
    if(xs>=0&&xs<320&&ys>=0&&ys<180)corrected_point={ys[7:0],xs[8:0]};
   end
  end
 endfunction
 // All geometry inputs are explicit: even a fixed target index must update
 // when calibration completes or the camera tracking model changes.
 assign target_point=corrected_point(target_index,points,origin_valid,origin_index,track_tx,track_ty,track_sx,track_sy);
 assign origin_point=corrected_point(origin_index,points,origin_valid,origin_index,track_tx,track_ty,track_sx,track_sy);
 assign corners={
  corrected_point((board_size-1'b1)*14,points,origin_valid,origin_index,track_tx,track_ty,track_sx,track_sy),
  corrected_point((board_size-1'b1)*13,points,origin_valid,origin_index,track_tx,track_ty,track_sx,track_sy),
  corrected_point(board_size-1'b1,points,origin_valid,origin_index,track_tx,track_ty,track_sx,track_sy),
  corrected_point(8'd0,points,origin_valid,origin_index,track_tx,track_ty,track_sx,track_sy)};
endmodule
`default_nettype wire
