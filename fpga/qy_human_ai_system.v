`timescale 1ns/1ps
`default_nettype none
// All game state, camera classification and search execute in the pixel domain.
// Only asynchronous physical keys enter through their two-stage frontend.
module qy_human_ai_system #(
 parameter CLK_HZ=137500000, DEBOUNCE_MS=20, AUTO_SIZE=0, ORIGIN_OPENING=0,
 parameter OFFSET_FILE="stone_ring_offsets.hex"
)(
 input wire clk,rst_n,camera_ready,app_active,
 input wire [3:0] key_press,key_held,
 input wire external_request_valid,input wire [2:0] external_request,
 output wire [63:0] now_us_o,
 output wire [191:0] calibration_diag_data,output wire [7:0] calibration_diag_events,
 input wire [23:0] rgb,input wire de,vs,
 output wire result_valid,output wire [6143:0] boxes,output wire [7:0] box_count,error,
 output wire [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
 output wire [337:0] board,output wire [7:0] last_index,move_count,
 output wire last_valid,game_over,draw,output wire [1:0] next_color,winner,human_color,
 output wire ai_target_valid,output wire [7:0] ai_target_index,output wire [1:0] ai_target_reason,
 output wire [3:0] phase,output wire [7:0] observation_reason,output wire fault,
 output wire calibrated,paused,setup_error,show_target,selected_human_white,
 output wire [3:0] board_size,formal_board_size,
 output wire origin_pending,origin_valid,output wire [7:0] origin_index,
 output wire [16:0] target_point,origin_point,output wire [31:0] origin_status,output wire camera_origin_valid,camera_target_valid,
 output wire [2:0] mode,field,output wire [8:0] field_value,
 output wire [67:0] corners,output wire [2872:0] points,
 output wire [337:0] coach_board,
 output wire [3:0] coach_fact,coach_feedback,
 output wire [1:0] coach_level,
 output wire [7:0] coach_own_count,coach_opp_count,coach_target,coach_move,coach_number,
 output wire [168:0] coach_targets,coach_line,
 output wire coach_review,coach_review_valid,coach_uncertain,
 output wire coach_counterexample_valid,output wire [7:0] coach_counterexample_index,
 output wire [168:0] coach_counterexample_line,
 output wire coach_answer_valid,coach_answer_correct,
 output wire [31:0] coach_cycles,output wire [15:0] coach_attempts,coach_hints,
 output wire event_valid,event_is_ai,output wire [7:0] event_index,output wire [1:0] event_color
);
 wire [31:0] state_version;
 wire controls_paused;
 // In the confirmed human turn, KEY4 requests teaching. During setup and
 // AI placement it retains its original calibration/target-display role.
 wire external_allowed=external_request_valid&&app_active&&key_press==0&&key_held==0&&!event_valid;
 wire coach_hint_press=(key_press[3]||(external_allowed&&external_request==2&&camera_ready&&calibrated&&!fault&&!game_over&&!coach_uncertain))&&app_active&&mode==0&&phase==3&&
                       next_color==human_color&&!paused;
 wire [3:0] control_key_press=coach_hint_press?{1'b0,key_press[2:0]}:key_press;
 assign paused=controls_paused||!app_active;
 wire human_white,new_game_request,calibrate_request,calibration_done,calibration_success,points_ready;
 assign selected_human_white=human_white;
 wire [31:0] calibration_version,safety_epoch;
 wire [2872:0] nominal_points;wire [67:0] manual_corners;
 wire anchor_seed_valid;wire [7:0] anchor_seed_index;
 wire signed [2:0] track_tx,track_ty;wire signed [4:0] track_sx,track_sy;
 // Geometry is based on the calibrated identity, including while a new first
 // move is awaiting confirmation. Formal board size changes only on reset.
 function automatic signed [5:0] model_delta;
  input signed [2:0] t;input signed [4:0] slope;input [3:0] coordinate,origin;
  reg signed [5:0] distance;reg signed [10:0] product,rounded;
  begin distance=$signed({2'b00,coordinate})-$signed({2'b00,origin});
   product=slope*distance;rounded=product+11'sd8;
   model_delta=$signed({{3{t[2]}},t})+(rounded>>>4);end
 endfunction
 function automatic [16:0] corrected_point_rc;
  input [7:0] index;
  input [3:0] index_row,index_col;
  input [2872:0] base_points;
  input seed_valid;input [7:0] seed_index;
  input signed [2:0] tx,ty;input signed [4:0] sx,sy;
  reg [16:0] base;reg signed [5:0] dx,dy;reg signed [10:0] xsum;reg signed [9:0] ysum;
  begin
   corrected_point_rc=0;
   if(index<169)begin
    base=base_points[index*17+:17];dx=0;dy=0;
    if(ORIGIN_OPENING&&seed_valid)begin
     dx=model_delta(tx,sx,index_row,seed_index/13);
     dy=model_delta(ty,sy,index_col,seed_index%13);
    end
    xsum=$signed({2'b00,base[8:0]})+$signed({{5{dx[5]}},dx});
    ysum=$signed({2'b00,base[16:9]})+$signed({{4{dy[5]}},dy});
    if(xsum>=0&&xsum<320&&ysum>=0&&ysum<180)corrected_point_rc={ysum[7:0],xsum[8:0]};
   end
  end
 endfunction
 function automatic [16:0] corrected_point;
  input [7:0] index;input [2872:0] base_points;input seed_valid;input [7:0] seed_index;
  input signed [2:0] tx,ty;input signed [4:0] sx,sy;
  begin corrected_point=corrected_point_rc(index,index/13,index%13,base_points,seed_valid,seed_index,tx,ty,sx,sy);end
 endfunction
 wire [7:0] bottom_left=(board_size-1'b1)*13;
 wire [7:0] bottom_right=(board_size-1'b1)*14;
 // These four coordinates are already known. Avoid deriving row/column by
 // division after the variable corner index on the routed board-size path.
 wire [3:0] last_coordinate=board_size-1'b1;
 wire [16:0] corrected_br=corrected_point_rc(bottom_right,last_coordinate,last_coordinate,points,anchor_seed_valid,anchor_seed_index,track_tx,track_ty,track_sx,track_sy);
 wire [16:0] corrected_bl=corrected_point_rc(bottom_left,last_coordinate,4'd0,points,anchor_seed_valid,anchor_seed_index,track_tx,track_ty,track_sx,track_sy);
 wire [16:0] corrected_tr=corrected_point_rc(board_size-1'b1,4'd0,last_coordinate,points,anchor_seed_valid,anchor_seed_index,track_tx,track_ty,track_sx,track_sy);
 wire [16:0] corrected_tl=corrected_point_rc(8'd0,4'd0,4'd0,points,anchor_seed_valid,anchor_seed_index,track_tx,track_ty,track_sx,track_sy);
 assign corners=AUTO_SIZE?(calibrated?{corrected_br,corrected_bl,corrected_tr,corrected_tl}:68'd0):manual_corners;
 // A calibration can publish new geometry before controls consumes its
 // completion. Do not overlay an old origin/target on that new geometry.
 assign camera_origin_valid=ORIGIN_OPENING&&origin_valid&&calibrated&&anchor_seed_valid&&
  origin_index==anchor_seed_index&&mode!=1&&mode!=2&&mode!=5&&!new_game_request&&!calibrate_request;
 assign camera_target_valid=ai_target_valid&&calibrated&&mode==0&&!new_game_request&&!calibrate_request;
 assign target_point=corrected_point(ai_target_index,points,anchor_seed_valid,anchor_seed_index,track_tx,track_ty,track_sx,track_sy);
 assign origin_point=corrected_point(origin_index,points,anchor_seed_valid,anchor_seed_index,track_tx,track_ty,track_sx,track_sy);
 wire [15:0] calibration_start_count,calibration_consume_count;
 wire calibration_start_event,calibration_consume_event;
 wire [191:0] detector_calibration_diag;wire [7:0] detector_calibration_events;
 wire [15:0] calibration_flags={
  (&calibration_start_count)||(&calibration_consume_count)||detector_calibration_diag[95],
  setup_error,app_active,detector_calibration_diag[92:80]};
 assign calibration_diag_data={detector_calibration_diag[191:104],mode,detector_calibration_diag[100:96],
  calibration_flags,detector_calibration_diag[79:64],calibration_consume_count,
  detector_calibration_diag[47:16],calibration_start_count};
 assign calibration_diag_events={1'b0,detector_calibration_events[6:4],calibration_consume_event,
  detector_calibration_events[2:1],calibration_start_event};
 qy_interaction_controls #(.CLK_HZ(CLK_HZ),.AUTO_SIZE(AUTO_SIZE),.CALIBRATION_LEVEL_HANDSHAKE(1)) controls(
  .clk(clk),.rst_n(rst_n),.camera_ready(camera_ready&&app_active),.key_press(control_key_press),.key_held(key_held),
  .external_request_valid(external_allowed),.external_request(external_request),
  .calibration_done(calibration_done),.calibration_success(calibration_success),.move_count(move_count),
  .calibration_start_count(calibration_start_count),.calibration_consume_count(calibration_consume_count),
  .calibration_start_event(calibration_start_event),.calibration_consume_event(calibration_consume_event),
  .paused(controls_paused),.human_white(human_white),.new_game_request(new_game_request),.calibrate_request(calibrate_request),
  .calibration_version(calibration_version),.safety_epoch(safety_epoch),.nominal_points(nominal_points),.corners(manual_corners),
  .mode(mode),.field(field),.field_value(field_value),.setup_error(setup_error),.show_target(show_target),.points_ready(points_ready));
 // A fractional accumulator preserves the real 137.5 MHz timebase. No slow
 // divided clock is created; microseconds are merely a clock-enable counter.
 reg [31:0] us_fraction;reg [63:0] now_us;
 assign now_us_o=now_us;
 always @(posedge clk)begin
  if(!rst_n)begin us_fraction<=0;now_us<=0;end
  else if(us_fraction>=CLK_HZ-1000000)begin us_fraction<=us_fraction-(CLK_HZ-1000000);now_us<=now_us+1'b1;end
  else us_fraction<=us_fraction+1000000;
 end
 wire [191:0] context_now,det_context;wire [31:0] det_epoch;
 wire [63:0] det_frame,det_time;wire det_valid,det_observable;
 wire [337:0] det_cells;wire [168:0] det_seen;wire [1351:0] det_confidence;wire [15:0] det_quality;
 qy_stone_grid_detector #(.AUTO_SIZE(AUTO_SIZE),.ORIGIN_OPENING(ORIGIN_OPENING),.OFFSET_FILE(OFFSET_FILE),.CALIBRATION_LEVEL_HANDSHAKE(1)) detector(
  .clk(clk),.rst_n(rst_n),.camera_ready(camera_ready),.rgb(rgb),.de(de),.vs(vs),
  .context_i(context_now),.safety_epoch_i(safety_epoch),.now_us(now_us),
  .calibrate_request(calibrate_request),.anchor_mode(!human_white),.nominal_points(AUTO_SIZE?2873'd0:nominal_points),
  .anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),
  .track_tx(track_tx),.track_ty(track_ty),.track_sx(track_sx),.track_sy(track_sy),
  .result_valid(result_valid),.boxes(boxes),.box_count(box_count),.result_sequence(result_sequence),
  .source_frame(source_frame),.compute_cycles(compute_cycles),.total_cycles(total_cycles),.error(error),.busy(),
  .calibration_diag_data(detector_calibration_diag),.calibration_diag_events(detector_calibration_events),
  .observation_valid(det_valid),.cells(det_cells),.observable(det_seen),.confidence(det_confidence),
  .quality(det_quality),.board_observable(det_observable),.observation_context(det_context),.observation_epoch(det_epoch),
  .observation_frame(det_frame),.observation_time(det_time),.calibrated(calibrated),
  .board_size(board_size),.calibration_done(calibration_done),.calibration_success(calibration_success),.points(points));
 // One-record same-clock queue makes the ready/valid handoff explicit. Any
 // unexpected overrun is rejected, never silently merged with another frame.
 reg queued,queue_observable;reg [191:0] queue_context;reg [31:0] queue_epoch;
 reg [63:0] queue_frame,queue_time;reg [337:0] queue_cells;
 reg [168:0] queue_seen;reg [1351:0] queue_confidence;reg [15:0] queue_quality;
 // GAM2 diagnostic snapshot. These bits never feed game decisions.
 assign origin_status={5'd0,anchor_seed_valid,origin_pending,origin_valid,origin_index,det_quality};
 wire observation_ready;
 always @(posedge clk)begin
  if(!rst_n)begin
   queued<=0;queue_observable<=0;queue_context<=0;queue_epoch<=0;queue_frame<=0;queue_time<=0;
   queue_cells<=0;queue_seen<=0;queue_confidence<=0;queue_quality<=0;
  end else begin
   if(queued&&observation_ready)queued<=0;
   if(det_valid)begin
    queued<=1;queue_observable<=det_observable;queue_context<=det_context;queue_epoch<=det_epoch;
    queue_frame<=det_frame;queue_time<=det_time;queue_cells<=det_cells;queue_seen<=det_seen;
    queue_confidence<=det_confidence;queue_quality<=det_quality|((queued&&!observation_ready)?16'h8000:16'd0);
   end
   if(new_game_request||calibrate_request||!app_active)queued<=0;
  end
 end
 qy_human_ai_game #(.DYNAMIC_SIZE(AUTO_SIZE),.ORIGIN_OPENING(ORIGIN_OPENING&&AUTO_SIZE)) game(
  .anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),
  .origin_pending(origin_pending),.origin_valid(origin_valid),.origin_index(origin_index),.formal_board_size(formal_board_size),
  .board_size_i(board_size),
  .clk(clk),.rst_n(rst_n),.new_game_request(new_game_request),.human_white(human_white),.paused(paused),
  .calibrated(calibrated),.safety_clear(camera_ready&&app_active),.calibration_version(calibration_version),
  .safety_epoch(safety_epoch),.now_us(now_us),.obs_valid(queued),.obs_ready(observation_ready),
  .obs_context(queue_context),.obs_safety_epoch(queue_epoch),.obs_frame(queue_frame),.obs_capture_us(queue_time),
  .obs_complete(1'b1),.obs_board_observable(queue_observable),.obs_quality(queue_quality),
  .obs_cells(queue_cells),.obs_observable(queue_seen),.obs_confidence(queue_confidence),.context_o(context_now),
  .board_o(board),.last_index_o(last_index),.move_count_o(move_count),.last_valid_o(last_valid),
  .game_over_o(game_over),.draw_o(draw),.next_color_o(next_color),.winner_o(winner),.human_color_o(human_color),
  .ai_target_valid(ai_target_valid),.ai_target_index(ai_target_index),.ai_target_reason(ai_target_reason),
  .phase(phase),.observation_reason(observation_reason),.fault(fault),
  .event_valid(event_valid),.event_is_ai(event_is_ai),.event_index(event_index),.event_color(event_color),.state_version_o(state_version));
 // Teaching reads the last actual camera observation; it cannot supply a
 // board or an observation to the formal game. Use its existing500ms age
 // budget and exact context/board identity, including after every commit.
 // Confirmed new-game setup starts a fresh teaching session immediately.
 // The original game retains its formal board until calibration is accepted.
 wire coach_reset=new_game_request||calibrate_request||!app_active||
                  mode==1||mode==2||mode==5;
 wire coach_safe;
 qy_coach_visual_guard coach_guard(
  .clk(clk),.rst_n(rst_n),.clear_i(coach_reset),.active_i(app_active),
  .camera_ready_i(camera_ready),.calibrated_i(calibrated),
  .origin_ok_i(!ORIGIN_OPENING||origin_valid),.paused_i(paused),.fault_i(fault),
  .board_i(board),.context_i(context_now),.epoch_i(safety_epoch),.now_us(now_us),
  .obs_valid_i(det_valid),.obs_observable_i(det_observable),.obs_quality_i(det_quality),
  .obs_cells_i(det_cells),.obs_context_i(det_context),.obs_epoch_i(det_epoch),
  .obs_time_i(det_time),.safe_o(coach_safe));
 assign coach_board=board;
 qy_coach_session coach(
  .clk(clk),.rst_n(rst_n),.new_game(coach_reset),.board_i(board),.version_i(state_version),
  .size_i(formal_board_size),.phase_i(phase),.human_i(human_color),.next_i(next_color),
  .move_count_i(move_count),.mode_i(mode),.safe_i(coach_safe),
  .hint_press_i(coach_hint_press),.review_press_i(1'b0),
  .event_valid_i(event_valid),.event_is_ai_i(event_is_ai),
  .event_index_i(event_index),.event_color_i(event_color),
  .level_o(),.fact_o(coach_fact),.feedback_o(),
  .own_count_o(coach_own_count),.opp_count_o(coach_opp_count),.target_o(coach_target),
  .targets_o(coach_targets),.line_o(coach_line),.uncertain_o(coach_uncertain),
  .review_o(coach_review),.review_valid_o(coach_review_valid),.display_board_o(),
  .review_move_o(coach_move),.review_number_o(coach_number),
  .display_feedback_o(coach_feedback),.display_level_o(coach_level),
  .counterexample_valid_o(coach_counterexample_valid),
  .counterexample_index_o(coach_counterexample_index),.counterexample_line_o(coach_counterexample_line),
  .answer_valid_o(coach_answer_valid),.answer_correct_o(coach_answer_correct),
  .tactics_cycles_o(coach_cycles),.attempts_o(coach_attempts),.hints_o(coach_hints));
endmodule
`default_nettype wire
