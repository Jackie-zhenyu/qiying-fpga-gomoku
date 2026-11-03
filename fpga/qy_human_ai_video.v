`timescale 1ns/1ps
`default_nettype none
// 058: one menu entry and the retained human/AI camera application.
module qy_human_ai_video #(parameter CLK_HZ=137500000,DEBOUNCE_MS=20)(
 input wire clk_i,rst_n_i,camera_ready_i,input wire [3:0] keys_n,
 input wire [20:0] status_i,input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 output wire frame_tick_o,output wire [23:0] rgb_o,output wire de_o,hs_o,vs_o,
 output wire result_valid,output wire [337:0] game_board,output wire [95:0] game_meta,
 output wire [31:0] game_origin_status,result_sequence,source_frame,compute_cycles,total_cycles,
 output wire [191:0] game_calibration_diag_data,output wire [7:0] game_calibration_diag_events,
 output wire flash_cs_n,flash_sclk,flash_mosi,input wire flash_miso,
 input wire nfc_rx,voice_rx,output wire nfc_tx,voice_tx
);
 wire active,replay_active,menu_selected,storage_busy,storage_intercept;wire [3:0] key_press,key_held;
 wire settings_active,physical_key;wire [3:0] settings_press;
 wire navigate_valid,navigate_replay,home_request;
 wire navigation_done,navigation_home;
 wire config_owner,settings_saving;wire [63:0] now_us;
 wire external_request_valid;wire [2:0] external_request;
 qy_function_menu #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) menu(
  .clk(clk_i),.rst_n(rst_n_i),.frame_tick(frame_tick_o),.keys_n(keys_n),
  .navigate_valid(navigate_valid),.navigate_replay(navigate_replay),.home_request(home_request),
  .navigation_done(navigation_done),.navigation_home(navigation_home),
  .settings_active(settings_active),.settings_press(settings_press),.physical_key(physical_key),
  .game_active(active),.replay_active(replay_active),.selected(menu_selected),
  .lock_exit(storage_busy||settings_saving||config_owner),.game_press(key_press),.game_held(key_held));
 wire [6143:0] boxes;wire [7:0] count,error,last_index,move_count,target_index,reason;
 wire [1:0] next_color,winner,human_color,target_reason;wire [3:0] phase,size,formal_size;
 wire last_valid,game_over,draw,fault,calibrated,paused,setup_error,show_target,human_white;
 wire origin_pending,origin_valid,camera_origin_valid,camera_target_valid,target_valid;
 wire [7:0] origin_index;wire [16:0] target_point,origin_point;wire [67:0] corners;
 wire [2872:0] points;wire [2:0] mode,field;wire [8:0] field_value;
 wire event_valid;wire [7:0] event_index;wire [1:0] event_color;
 wire [337:0] coach_board;
 wire [3:0] coach_fact,coach_feedback;wire [1:0] coach_level;
 wire [7:0] coach_own_count,coach_opp_count,coach_target,coach_move,coach_number;
 wire [168:0] coach_targets,coach_line,coach_counterexample_line;
 wire coach_review,coach_review_valid,coach_uncertain,coach_counterexample_valid;
 wire [7:0] coach_counterexample_index;wire coach_answer_valid,coach_answer_correct;
 wire [31:0] coach_cycles;wire [15:0] coach_attempts,coach_hints;
 reg [1351:0] move_history;
 always @(posedge clk_i)begin
  if(!rst_n_i||move_count==0)move_history<={1352{1'b1}};
  else if(event_valid&&move_count<=169)move_history[(move_count-1'b1)*8+:8]<=event_index;
 end
 // Setup must display the requested ownership before a formal game exists.
 // The formal human_color is committed only after successful calibration.
 wire [1:0] display_human_color=(mode==1||mode==2||mode==5)?
  (human_white?2'd2:2'd1):human_color;
 qy_human_ai_system #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS),.AUTO_SIZE(1),.ORIGIN_OPENING(1)) system(
  .clk(clk_i),.rst_n(rst_n_i),.camera_ready(camera_ready_i),.app_active(active),
  .key_press(storage_intercept?4'd0:key_press),.key_held(storage_intercept?4'd0:key_held),
  .external_request_valid(external_request_valid&&!physical_key&&!storage_intercept&&!storage_busy&&!config_owner&&!settings_active),
  .external_request(external_request),.now_us_o(now_us),
  .calibration_diag_data(game_calibration_diag_data),.calibration_diag_events(game_calibration_diag_events),
  .rgb(rgb_i),.de(de_i),.vs(vs_i),.result_valid(result_valid),.boxes(boxes),.box_count(count),.error(error),
  .result_sequence(result_sequence),.source_frame(source_frame),.compute_cycles(compute_cycles),.total_cycles(total_cycles),
  .board(game_board),.last_index(last_index),.move_count(move_count),.last_valid(last_valid),
  .game_over(game_over),.draw(draw),.next_color(next_color),.winner(winner),.human_color(human_color),
  .ai_target_valid(target_valid),.ai_target_index(target_index),.ai_target_reason(target_reason),
  .phase(phase),.observation_reason(reason),.fault(fault),.calibrated(calibrated),.paused(paused),
  .setup_error(setup_error),.show_target(show_target),.selected_human_white(human_white),
  .board_size(size),.formal_board_size(formal_size),.origin_pending(origin_pending),.origin_valid(origin_valid),
  .origin_index(origin_index),.target_point(target_point),.origin_point(origin_point),.origin_status(game_origin_status),
  .camera_origin_valid(camera_origin_valid),.camera_target_valid(camera_target_valid),
  .mode(mode),.field(field),.field_value(field_value),.corners(corners),.points(points),
  .event_valid(event_valid),.event_index(event_index),.event_color(event_color),
  .coach_board(coach_board),.coach_fact(coach_fact),.coach_feedback(coach_feedback),.coach_level(coach_level),
  .coach_own_count(coach_own_count),.coach_opp_count(coach_opp_count),.coach_target(coach_target),
  .coach_move(coach_move),.coach_number(coach_number),.coach_targets(coach_targets),.coach_line(coach_line),
  .coach_review(coach_review),.coach_review_valid(coach_review_valid),.coach_uncertain(coach_uncertain),
  .coach_counterexample_valid(coach_counterexample_valid),.coach_counterexample_index(coach_counterexample_index),
  .coach_counterexample_line(coach_counterexample_line),.coach_answer_valid(coach_answer_valid),
  .coach_answer_correct(coach_answer_correct),.coach_cycles(coach_cycles),
  .coach_attempts(coach_attempts),.coach_hints(coach_hints));
 // Preserve the legacy human/AI diagnostic word layout (reserved nibble zero).
 assign game_meta[31:0]={8'd0,1'b0,camera_ready_i,target_valid,1'b0,game_over,fault,paused,calibrated,4'h0,phase,error};
 assign game_meta[63:32]={count,last_index,target_index,move_count};
 assign game_meta[95:64]={size,formal_size,9'd0,1'b1,setup_error,last_valid,3'd0,mode,human_color,winner,next_color};
 wire [23:0] fit_rgb;wire fit_de,fit_hs,fit_vs,fit_ready;
 wire freeze_request,frozen,dump_start,dump_valid,dump_ready,load_begin,load_commit,load_abort;
 wire image_load_valid,image_load_ready;wire [7:0] dump_data,image_load_data;
 wire [31:0] frozen_frame;wire initialized;wire [7:0] init_error,storage_error,record_error;
 wire [3:0] slot_valid,storage_ui;wire [31:0] slot_moves;wire [1:0] selected_slot;
 wire save_valid,save_ready,load_valid,load_ready,record_done,record_done_ready;
 wire [2015:0] save_metadata;wire [2047:0] loaded_header;
 qy_storage_thumbnail fit(.clk_i(clk_i),.rst_n_i(rst_n_i),.rgb_i(rgb_i),.de_i(de_i),.hs_i(hs_i),.vs_i(vs_i),
  .camera_ready_i(camera_ready_i),.rgb_o(fit_rgb),.de_o(fit_de),.hs_o(fit_hs),.vs_o(fit_vs),.frame_valid_o(fit_ready),
  .freeze_request(freeze_request),.frozen(frozen),.frozen_frame(frozen_frame),
  .dump_start(dump_start),.dump_valid(dump_valid),.dump_ready(dump_ready),.dump_data(dump_data),
  .load_begin(load_begin),.load_valid(image_load_valid),.load_ready(image_load_ready),.load_data(image_load_data),
  .load_commit(load_commit),.load_abort(load_abort));
 qy_storage_session #(.CLK_HZ(CLK_HZ)) storage_session(
  .clk(clk_i),.rst_n(rst_n_i),.game_active(active),.replay_active(replay_active),.key_press(key_press),
  .game_mode(mode),.camera_ready(camera_ready_i),.calibrated(calibrated),.fault(fault),.phase(phase),
  .board_size(formal_size),.board(game_board),.moves(move_count),.last_index(last_index),.origin_index(origin_index),
  .human(human_color),.next_color(next_color),.winner(winner),.last_valid(last_valid),.game_over(game_over),.draw(draw),
  .origin_valid(origin_valid),.history(move_history),.initialized(initialized),.init_error(init_error),.slot_valid(slot_valid),
  .selected(selected_slot),.ui_state(storage_ui),.error(storage_error),.busy(storage_busy),.intercept(storage_intercept),.preview(),
  .freeze_request(freeze_request),.frozen(frozen),.frozen_frame(frozen_frame),.dump_start(dump_start),
  .load_begin(load_begin),.load_commit(load_commit),.load_abort(load_abort),
  .save_valid(save_valid),.save_ready(save_ready),.save_metadata(save_metadata),.load_valid(load_valid),.load_ready(load_ready),
  .done_valid(record_done),.done_ready(record_done_ready),.done_error(record_error));
 wire records_rst_n,records_cs_n,records_sclk,records_mosi;
 qy_storage_records #(.HALF_CYCLES((CLK_HZ+12499999)/12500000),.BUSY_TIMEOUT(CLK_HZ*3),.STREAM_TIMEOUT(CLK_HZ)) storage_records(
  .clk(clk_i),.rst_n(records_rst_n),.initialized(initialized),.init_error(init_error),.slot_valid(slot_valid),.slot_moves(slot_moves),
  .save_valid(save_valid),.save_ready(save_ready),.save_slot(selected_slot),.save_metadata(save_metadata),
  .image_in_valid(dump_valid),.image_in_ready(dump_ready),.image_in_data(dump_data),
  .load_valid(load_valid),.load_ready(load_ready),.load_slot(selected_slot),.loaded_header(loaded_header),
  .image_out_valid(image_load_valid),.image_out_ready(image_load_ready),.image_out_data(image_load_data),
  .done_valid(record_done),.done_ready(record_done_ready),.done_is_load(),.done_error(record_error),
  .cs_n(records_cs_n),.sclk(records_sclk),.mosi(records_mosi),.miso(flash_miso));
 // The runtime card table and voice switch survive reset via the dedicated
 // dual-sector store; only an explicit Save key starts a write transaction.
 wire uid_valid,card_present,nfc_ready,nfc_fault,voice_enabled,nfc_restart;
 wire [79:0] uid;wire [3:0] uid_length,voice_cmd;wire voice_cmd_valid;
 wire [31:0] nfc_errors,voice_errors;wire speech_busy,speech_cancel,phrase_valid;wire [7:0] phrase_id;
 wire card_valid;wire [1:0] card_action;wire [239:0] card_uids;
 wire [11:0] card_lengths;wire [2:0] card_enabled,settings_selection;
 wire settings_learning,voice_confirm,settings_dirty;wire [4:0] settings_notice,action_notice;
 wire settings_notice_toggle,action_notice_toggle;
 reg settings_notice_seen,action_notice_seen,outside_settings_notice;
 wire settings_global_notice=settings_notice==6||settings_notice==13||settings_notice==15;
 // The most recent eligible event wins outside settings, including repeated
 // identical notices. Local "saved" feedback cannot hide an application error.
 always @(posedge clk_i)begin
  if(!rst_n_i)begin settings_notice_seen<=0;action_notice_seen<=0;outside_settings_notice<=0;end
  else begin
   settings_notice_seen<=settings_notice_toggle;action_notice_seen<=action_notice_toggle;
   if(settings_notice_seen!=settings_notice_toggle&&settings_global_notice)outside_settings_notice<=1;
   if(action_notice_seen!=action_notice_toggle&&action_notice!=0)outside_settings_notice<=0;
  end
 end
 wire [4:0] peripheral_notice=settings_active?settings_notice:
  outside_settings_notice?(settings_global_notice?settings_notice:action_notice):
  action_notice!=0?action_notice:(settings_global_notice?settings_notice:5'd0);
 wire config_initialized,config_valid,config_active,config_grant;
 wire [255:0] config_data,config_save_data;wire [7:0] config_error,config_done_error;
 wire config_save_valid,config_save_ready,config_done_valid,config_done_ready;
 wire config_cs_n,config_sclk,config_mosi;
 qy_peripheral_transport #(.CLK_HZ(CLK_HZ)) peripherals(
  .clk(clk_i),.rst_n(rst_n_i),.now_us(now_us),.nfc_rx(nfc_rx),.voice_rx(voice_rx),.nfc_tx(nfc_tx),.voice_tx(voice_tx),
  .nfc_restart(nfc_restart),.voice_enabled(voice_enabled),.uid_valid(uid_valid),.uid(uid),.uid_length(uid_length),
  .card_present(card_present),.nfc_ready(nfc_ready),.nfc_fault(nfc_fault),.nfc_errors(nfc_errors),.voice_errors(voice_errors),
  .voice_cmd_valid(voice_cmd_valid),.voice_cmd(voice_cmd),.phrase_valid(phrase_valid),.phrase_id(phrase_id),
  .speech_cancel(speech_cancel),.speech_busy(speech_busy));
 qy_peripheral_config_store #(.HALF_CYCLES((CLK_HZ+12499999)/12500000),.BUSY_TIMEOUT(CLK_HZ*3),.STREAM_TIMEOUT(CLK_HZ)) peripheral_config(
  .clk(clk_i),.rst_n(rst_n_i),.grant(config_grant),.initialized(config_initialized),.config_valid(config_valid),
  .config_data(config_data),.error(config_error),.save_valid(config_save_valid),.save_ready(config_save_ready),.save_data(config_save_data),
  .done_valid(config_done_valid),.done_ready(config_done_ready),.done_error(config_done_error),.active(config_active),
  .cs_n(config_cs_n),.sclk(config_sclk),.mosi(config_mosi),.miso(flash_miso));
 qy_peripheral_spi_owner peripheral_spi(
  .clk(clk_i),.rst_n(rst_n_i),.config_initialized(config_initialized),.config_active(config_active),
  .settings_active(settings_active),.game_active(active),.replay_active(replay_active),.storage_busy(storage_busy),
  .records_initialized(initialized),.records_idle(save_ready&&load_ready),.records_init_error(init_error),
  .record_save_valid(save_valid),.record_load_valid(load_valid),
  .config_cs_n(config_cs_n),.config_sclk(config_sclk),.config_mosi(config_mosi),
  .records_cs_n(records_cs_n),.records_sclk(records_sclk),.records_mosi(records_mosi),
  .config_grant(config_grant),.records_rst_n(records_rst_n),.config_owner(config_owner),
  .cs_n(flash_cs_n),.sclk(flash_sclk),.mosi(flash_mosi));
 qy_peripheral_settings peripheral_settings(
  .clk(clk_i),.rst_n(rst_n_i),.now_us(now_us),.settings_active(settings_active),.key_press(settings_press),
  .uid_valid(uid_valid),.uid(uid),.uid_length(uid_length),.card_present(card_present),.nfc_ready(nfc_ready),.nfc_fault(nfc_fault),
  .config_initialized(config_initialized),.config_valid(config_valid),.config_data(config_data),.config_error(config_error),
  .save_valid(config_save_valid),.save_data(config_save_data),.save_ready(config_save_ready),
  .done_valid(config_done_valid),.done_ready(config_done_ready),.done_error(config_done_error),
  .card_uids(card_uids),.card_lengths(card_lengths),.card_enabled(card_enabled),.voice_enabled(voice_enabled),
  .nfc_restart(nfc_restart),.card_valid(card_valid),.card_action(card_action),.selection(settings_selection),
  .learning(settings_learning),.voice_confirm(voice_confirm),.saving(settings_saving),.dirty(settings_dirty),
  .notice(settings_notice),.notice_toggle(settings_notice_toggle),.busy());
 qy_peripheral_actions peripheral_actions(
  .clk(clk_i),.rst_n(rst_n_i),.now_us(now_us),.game_active(active),.replay_active(replay_active),.settings_active(settings_active),
  .storage_busy(storage_busy||config_owner),.storage_intercept(storage_intercept),.physical_key(physical_key),
  .card_valid(card_valid),.card_action(card_action),.voice_cmd_valid(voice_cmd_valid),.voice_cmd(voice_cmd),
  .navigation_done(navigation_done),.navigation_is_replay(menu_selected),.navigation_home(navigation_home),
  .camera_ready(camera_ready_i),.calibrated(calibrated),.paused(paused),.fault(fault),.game_over(game_over),.draw(draw),
  .target_valid(target_valid),.target_index(target_index),.mode(mode),.phase(phase),.next_color(next_color),.human_color(human_color),.winner(winner),
  .event_valid(event_valid),.event_color(event_color),.coach_fact(coach_fact),.coach_uncertain(coach_uncertain),
  .coach_answer_valid(coach_answer_valid),.coach_answer_correct(coach_answer_correct),
  .navigate_valid(navigate_valid),.navigate_replay(navigate_replay),.home_request(home_request),
  .request_valid(external_request_valid),.request(external_request),.phrase_valid(phrase_valid),.phrase_id(phrase_id),
  .speech_cancel(speech_cancel),.notice(action_notice),.notice_toggle(action_notice_toggle));
 reg replay_view_frame;
 wire viewing=replay_active&&storage_ui==10;
 wire [337:0] display_board=replay_active?(viewing?loaded_header[32*8+:338]:338'd0):game_board;
 wire [3:0] display_size=replay_active?(viewing?loaded_header[9*8+:4]:4'd13):size;
 wire [7:0] display_moves=replay_active?(viewing?loaded_header[12*8+:8]:8'd0):move_count;
 wire [1:0] display_next=replay_active?loaded_header[11*8+:2]:next_color;
 reg [11:0] x,y;reg de_d,vs_d,frame_bad;reg [20:0] status_frame;reg ready_frame;
 wire frame_edge=fit_vs&&!vs_d;wire frame_good=y==1080&&!frame_bad;
 assign frame_tick_o=frame_edge;
 always @(posedge clk_i)begin
  if(!rst_n_i)replay_view_frame<=0;
  else if(frame_edge)replay_view_frame<=replay_active&&storage_ui==10;
 end
 always @(posedge clk_i)begin
  if(!rst_n_i)begin x<=0;y<=0;de_d<=0;vs_d<=0;frame_bad<=0;status_frame<=0;ready_frame<=0;end
  else begin
   de_d<=fit_de;vs_d<=fit_vs;
   if(frame_edge)begin x<=0;y<=0;frame_bad<=0;status_frame<=status_i;ready_frame<=frame_good&&fit_ready;end
   else if(fit_de)begin if(x<4095)x<=x+1'b1;if(x>=1920||y>=1080)frame_bad<=1;end
   else begin x<=0;if(de_d)begin if(x!=1920)frame_bad<=1;if(y<4095)y<=y+1'b1;end end
  end
 end
 wire [23:0] render_rgb,base_rgb;wire render_de,render_hs,render_vs;wire [11:0] render_x,render_y;
 qy_gomoku13_renderer #(.DYNAMIC_SIZE(1),.ORIGIN_OPENING(1)) render(
  .origin_valid_i(replay_active?(viewing&&loaded_header[14*8+3]):origin_valid),
  .origin_index_i(replay_active?loaded_header[15*8+:8]:origin_index),.board_size_i(display_size),
  .clk_i(clk_i),.rst_n_i(rst_n_i),.x_i(x),.y_i(y),.de_i(fit_de),.hs_i(fit_hs),.vs_i(fit_vs),.frame_commit_i(frame_edge),
  .page_i(2'd0),.selected_i(2'd0),.board_i(display_board),.last_index_i(replay_active?loaded_header[13*8+:8]:last_index),
  .black_index_i(target_index),.white_index_i(target_index),.last_valid_i(replay_active?(viewing&&loaded_header[14*8]):last_valid),
  .black_valid_i(!replay_active&&target_valid&&human_color==2&&show_target),.white_valid_i(!replay_active&&target_valid&&human_color==1&&show_target),
  .next_color_i(display_next),.camera_ready_i(replay_active?(viewing&&fit_ready):frame_good&&fit_ready),
  .calibrated_i(replay_active?viewing:calibrated),.ai_ready_i(!replay_active&&target_valid),
  .paused_i(paused),.demo_i(1'b0),.phase_i(3'd0),.winner_i(replay_active?loaded_header[75*8+:2]:winner),
  .draw_i(replay_active?loaded_header[14*8+2]:draw),.move_count_i(display_moves),
  .black_reason_i(target_reason),.white_reason_i(target_reason),.camera_rgb_i(fit_rgb),.camera_pixel_valid_i(fit_de),
  .rgb_o(render_rgb),.de_o(render_de),.hs_o(render_hs),.vs_o(render_vs),.x_o(render_x),.y_o(render_y));
 wire status_ink;
 qy_camera_startup_text debug_line(.x_i(render_x),.y_i(render_y),.status_i(status_frame),.visible_i(!ready_frame),.ink_o(status_ink));
 assign base_rgb=render_de&&status_ink?24'hf4b65d:render_rgb;
 wire [23:0] box_rgb,panel_rgb;wire box_de,box_hs,box_vs,panel_de,panel_hs,panel_vs;
 qy_stone_game_overlay box_panel(.clk(clk_i),.rst_n(rst_n_i),.camera_ready(camera_ready_i),.result_valid(result_valid),.boxes(boxes),
  .rgb_i(base_rgb),.de_i(render_de),.hs_i(render_hs),.vs_i(render_vs),.rgb_o(box_rgb),.de_o(box_de),.hs_o(box_hs),.vs_o(box_vs));
 qy_interaction_panel #(.AUTO_SIZE(1),.ORIGIN_OPENING(1),.PRECOMPUTED_CAMERA_POINTS(1)) panel(
  .clk(clk_i),.rst_n(rst_n_i),.camera_ready(camera_ready_i),.rgb_i(box_rgb),.de_i(box_de),.hs_i(box_hs),.vs_i(box_vs),
  .board_size_i(size),.mode_i(mode),.field_i(field),.field_value_i(field_value),.phase_i(phase),.reason_i(reason),.move_count_i(move_count),
  .human_color_i(display_human_color),.winner_i(winner),.draw_i(draw),.fault_i(fault),.calibrated_i(calibrated),.setup_error_i(setup_error),
  .target_valid_i(camera_target_valid),.show_target_i(show_target),.target_index_i(target_index),
  .origin_valid_i(camera_origin_valid),.origin_pending_i(origin_pending),.origin_index_i(origin_index),
  .target_point_i(target_point),.origin_point_i(origin_point),.corners_i(corners),.points_i(points),
  .rgb_o(panel_rgb),.de_o(panel_de),.hs_o(panel_hs),.vs_o(panel_vs));
 wire [23:0] coach_rgb;wire coach_de,coach_hs,coach_vs;
 // The renderer above always receives the real formal board. Coaching adds
 // read-only marks/text; saved-history pages keep the original display path.
 qy_coach_panel coach_panel(
  .clk(clk_i),.rst_n(rst_n_i),.rgb_i(panel_rgb),.de_i(panel_de),.hs_i(panel_hs),.vs_i(panel_vs),
  .enable_i(active&&!storage_intercept&&mode==0&&phase==3&&
             next_color==human_color&&!paused),
  .paused_i(paused),.review_i(1'b0),.uncertain_i(coach_uncertain),
  .fact_i(coach_fact),.feedback_i(coach_feedback),.level_i(coach_level),
  .own_count_i(coach_own_count),.opp_count_i(coach_opp_count),.move_i(coach_move),
  .target_i(coach_counterexample_valid?coach_counterexample_index:coach_target),
  .origin_valid_i(origin_valid),.origin_index_i(origin_index),
  .targets_i(coach_counterexample_valid?(169'd1<<coach_counterexample_index):coach_targets),
  .line_i(coach_counterexample_valid?coach_counterexample_line:coach_line),
  .counterexample_valid_i(coach_counterexample_valid),.cycles_i(coach_cycles),
  .attempts_i(coach_attempts),.hints_i(coach_hints),
  .rgb_o(coach_rgb),.de_o(coach_de),.hs_o(coach_hs),.vs_o(coach_vs));
 wire [23:0] home_rgb;wire home_de,home_hs,home_vs;
 qy_storage_ui home(.clk(clk_i),.rst_n(rst_n_i),.game_active(active),.replay_active(replay_active),
  .menu_selected(menu_selected),.ui_state(storage_ui==10&&!replay_view_frame?4'd9:storage_ui),.slot(selected_slot),.slot_valid(slot_valid),.slot_moves(slot_moves),
  .storage_error(storage_error),.initialized(initialized),.init_error(init_error),.game_mode(mode),.camera_ready(camera_ready_i),
  .rgb_i(replay_active?render_rgb:coach_rgb),.de_i(replay_active?render_de:coach_de),
  .hs_i(replay_active?render_hs:coach_hs),.vs_i(replay_active?render_vs:coach_vs),
  .rgb_o(home_rgb),.de_o(home_de),.hs_o(home_hs),.vs_o(home_vs));
 qy_peripheral_settings_panel peripheral_panel(
  .clk(clk_i),.rst_n(rst_n_i),.enable_i(settings_active),.home_i(!active&&!replay_active&&!settings_active),
  .selection_i(settings_selection),.learning_i(settings_learning),.voice_confirm_i(voice_confirm),
  .saving_i(settings_saving),.dirty_i(settings_dirty),.voice_enabled_i(voice_enabled),
  .card_uids_i(card_uids),.card_lengths_i(card_lengths),.card_enabled_i(card_enabled),
  .notice_i(peripheral_notice),
  .nfc_ready_i(nfc_ready),.nfc_fault_i(nfc_fault),.card_present_i(card_present),
  .config_initialized_i(config_initialized),.config_error_i(config_error),
  .rgb_i(home_rgb),.de_i(home_de),.hs_i(home_hs),.vs_i(home_vs),
  .rgb_o(rgb_o),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o));
endmodule
`default_nettype wire
