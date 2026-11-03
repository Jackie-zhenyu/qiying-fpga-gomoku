`timescale 1ns/1ps
`default_nettype none
// Observation-level teaching application. No pixels or physical pin assumptions.
// Modes 1 win, 2 single-threat defence, 3 original game/search, 4 one mistake retry.
// Commands: 1 start/confirm, 2 hint, 3 repeat, 4 pause, 5 resume/cancel switch, 6 next.
module qy_teacher_core #(
 parameter MIN_FRAMES=3,parameter [63:0] STABLE_US=250000,
 parameter SEARCH_DEPTH=3,SEARCH_NODES=20000,ORIGIN_OPENING=0
)(
 input wire clk,rst_n,
 input wire card_valid,input wire [2:0] card_mode,
 input wire cmd_valid,input wire [2:0] cmd,
 input wire calibrated,safety_clear,input wire [3:0] board_size_i,
 input wire anchor_seed_valid,input wire [7:0] anchor_seed_index,
 input wire [31:0] calibration_version,safety_epoch,input wire [63:0] now_us,
 input wire obs_valid,output wire obs_ready,
 input wire [191:0] obs_context,input wire [31:0] obs_safety_epoch,
 input wire [63:0] obs_frame,obs_capture_us,input wire obs_complete,obs_board_observable,
 input wire [15:0] obs_quality,input wire [337:0] obs_cells,
 input wire [168:0] obs_observable,input wire [1351:0] obs_confidence,
 output wire [191:0] context_o,output wire [337:0] board_o,
 output wire [337:0] setup_board_o,output reg [2:0] mode_o,pending_mode_o,
 output reg [3:0] stage_o,output reg [1:0] hint_level_o,
 output wire [168:0] hint_targets_o,output wire [7:0] hint_target_o,
 output wire [3:0] size_o,output wire [1:0] side_o,
 output wire ai_target_valid,output wire [7:0] ai_target_index,
 output wire [3:0] game_phase,output wire [7:0] move_count,
 output wire [1:0] next_color_o,output wire [7:0] last_index_o,output wire last_valid_o,
 output wire game_over,output wire [1:0] winner,
 output wire event_valid,event_is_ai,output wire [7:0] event_index,output wire [1:0] event_color,
 output reg retry_valid,output reg phrase_valid,output reg [7:0] phrase_id,output wire speech_cancel,
 output reg answer_valid,answer_correct,output wire fault
);
 // IDLE, SETUP, ACTIVE, PAUSED, RECHECK, ANSWER, ERROR.
 localparam IDLE=0,SETUP=1,ACTIVE=2,PAUSED=3,RECHECK=4,ANSWER=5,ERROR=6;
 reg [3:0] resume_stage,lesson_size;reg [31:0] lesson_cal,lesson_version;
 reg [7:0] lesson_anchor,lesson_count,retry_count,retry_anchor;reg [31:0] retry_cal;
 reg [7:0] lesson_event_index;
 reg [63:0] session;
 reg [337:0] lesson_board,lesson_expected,retry_board;
 reg [3:0] retry_size;reg [1:0] lesson_side,retry_side;
 reg [168:0] lesson_answers,retry_answers;reg retry_defence,lesson_defence,vertical;
 reg [7:0] last_phrase;reg game_new;
 wire interrupted=card_valid||cmd_valid&&(cmd==1||cmd==4||cmd==5||cmd==6);
 wire anchor_ok=!ORIGIN_OPENING||(anchor_seed_valid&&anchor_seed_index<169&&
  anchor_seed_index/13<board_size_i&&anchor_seed_index%13<board_size_i);
 wire permission=calibrated&&safety_clear&&board_size_i>=5&&board_size_i<=13&&anchor_ok;
 wire lesson_identity=lesson_size==board_size_i&&lesson_cal==calibration_version&&
  (!ORIGIN_OPENING||lesson_anchor==anchor_seed_index);
 wire running=stage_o==ACTIVE&&pending_mode_o==0&&permission&&lesson_identity&&!interrupted;
 wire [337:0] rom_board;wire rom_valid;
 qy_teacher_lessons rom(.defence(mode_o==2),.vertical(vertical),.board_size(board_size_i),
  .anchor_valid(ORIGIN_OPENING?anchor_seed_valid:1'b1),.anchor_index(ORIGIN_OPENING?anchor_seed_index:8'd0),
  .board(rom_board),.valid(rom_valid));
 wire [191:0] game_context;wire [337:0] game_board;
 wire [31:0] game_version;wire game_ready,game_fault,game_event,game_ai_event;
 wire [7:0] game_index;wire [1:0] game_color,game_human,game_next;
 wire [7:0] game_count,game_last;wire game_last_valid;
 wire [3:0] game_size;wire game_target;
 wire [7:0] game_target_index;
 wire game_input_ok=obs_context==context_o;
 qy_human_ai_game #(.DYNAMIC_SIZE(1),.ORIGIN_OPENING(ORIGIN_OPENING),.MIN_FRAMES(MIN_FRAMES),
  .STABLE_US(STABLE_US),.SEARCH_DEPTH(SEARCH_DEPTH),.SEARCH_NODES(SEARCH_NODES)) game(
  .clk(clk),.rst_n(rst_n),.new_game_request(game_new),.human_white(1'b0),
  .paused(mode_o!=3||!running),.anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),
  .calibrated(calibrated),.safety_clear(safety_clear),.board_size_i(board_size_i),
  .calibration_version(calibration_version),.safety_epoch(safety_epoch),.now_us(now_us),
  .obs_valid(obs_valid&&mode_o==3&&running),.obs_ready(game_ready),
  .obs_context(game_input_ok?game_context:192'd0),.obs_safety_epoch(obs_safety_epoch),
  .obs_frame(obs_frame),.obs_capture_us(obs_capture_us),.obs_complete(obs_complete),
  .obs_board_observable(obs_board_observable),.obs_quality(obs_quality),.obs_cells(obs_cells),
  .obs_observable(obs_observable),.obs_confidence(obs_confidence),.context_o(game_context),
  .board_o(game_board),.move_count_o(game_count),.game_over_o(game_over),.winner_o(winner),
  .last_index_o(game_last),.last_valid_o(game_last_valid),
  .next_color_o(game_next),.human_color_o(game_human),.formal_board_size(game_size),
  .ai_target_valid(game_target),.ai_target_index(game_target_index),.phase(game_phase),.fault(game_fault),
  .event_valid(game_event),.event_is_ai(game_ai_event),.event_index(game_index),.event_color(game_color),
  .state_version_o(game_version));
 assign board_o=mode_o==3?game_board:lesson_board;
 assign move_count=mode_o==3?game_count:lesson_count;
 assign next_color_o=mode_o==3?game_next:lesson_side;
 assign last_index_o=mode_o==3?game_last:lesson_event_index;
 assign last_valid_o=mode_o==3?game_last_valid:stage_o==ANSWER;
 assign size_o=mode_o==3?board_size_i:lesson_size;
 assign side_o=mode_o==3?game_human:lesson_side;
 wire [31:0] version=mode_o==3?game_version:lesson_version;
 assign context_o={version,calibration_version,{60'd0,board_size_i},session};
 assign ai_target_valid=mode_o==3&&running&&game_target;
 assign ai_target_index=game_target_index;
 assign fault=stage_o==ERROR||mode_o==3&&game_fault;
 assign setup_board_o=stage_o==RECHECK?board_o:lesson_expected;
 wire matching=(stage_o==SETUP||stage_o==RECHECK)&&pending_mode_o==0&&permission&&!interrupted&&
  lesson_identity;
 wire match_ready,matched,qualified;
 wire hint_turn=mode_o!=3||game_phase==3;
 wire hint_safe=running&&hint_turn&&qualified;
 // A queued tactical phrase expires when its supporting observation does.
 assign speech_cancel=(last_phrase==15||last_phrase==16)&&!hint_safe;
 qy_teacher_match #(.MIN_FRAMES(MIN_FRAMES),.STABLE_US(STABLE_US)) matcher(
  .clk(clk),.rst_n(rst_n),.enable(matching||running&&hint_turn),.expected(stage_o==ACTIVE?board_o:setup_board_o),.size(size_o),
  .context_i(context_o),.epoch_i(safety_epoch),.now_us(now_us),.obs_valid(obs_valid&&obs_ready),.obs_ready(match_ready),
  .cells(obs_cells),.seen(obs_observable),.confidence(obs_confidence),.obs_context(obs_context),
  .obs_epoch(obs_safety_epoch),.frame(obs_frame),.capture_us(obs_capture_us),
  .complete(obs_complete),.observable(obs_board_observable),.quality(obs_quality),.matched(matched),.qualified(qualified));
 wire guard_ready,proposal,allowed;wire [7:0] row,col;wire [1:0] color;
 wire [7:0] answer_index=row*13+col;
 wire lesson_running=mode_o!=3&&running&&lesson_identity;
 qy_observation_guard #(.DYNAMIC_SIZE(1),.MIN_FRAMES(MIN_FRAMES),.STABLE_US(STABLE_US)) guard(
  .clk(clk),.rst(!rst_n),.cancel(!lesson_running),.session_ready(lesson_running),
  .calibrated(calibrated),.safety_clear(safety_clear),.board_size_i(size_o),.current_context(context_o),
  .safety_epoch(safety_epoch),.now_us(now_us),.confirmed_cells(lesson_board),.next_color(lesson_side),.terminal(1'b0),
  .obs_valid(obs_valid&&lesson_running),.obs_ready(guard_ready),.obs_context(obs_context),
  .obs_safety_epoch(obs_safety_epoch),.obs_frame_id(obs_frame),.obs_capture_us(obs_capture_us),
  .obs_board_size(size_o),.obs_cell_count({12'd0,size_o}*{12'd0,size_o}),.obs_quality_flags(obs_quality),
  .obs_frame_complete(obs_complete),.obs_board_observable(obs_board_observable),.obs_cells(obs_cells),
  .obs_observable(obs_observable),.obs_confidence(obs_confidence),.proposal_valid(proposal),.proposal_ready(1'b1),
  .proposal_commit_allowed(allowed),.proposal_row(row),.proposal_col(col),.proposal_color(color));
 assign obs_ready=matching?match_ready:(mode_o==3&&running)?game_ready:lesson_running?guard_ready:1'b0;
 assign event_valid=mode_o==3?game_event:answer_valid;
 assign event_is_ai=mode_o==3&&game_ai_event;
 assign event_index=mode_o==3?game_index:lesson_event_index;
 assign event_color=mode_o==3?game_color:lesson_side;
 // A tactics certificate describes exactly the pre-move board; the game is
 // still the sole rule committer. Only certified missed wins/single blocks retry.
 wire tb_busy,tb_done,tb_valid,tb_error,to,tt;
 wire [31:0] tb_version;wire [168:0] own,opp;wire [7:0] own_n,opp_n,own_first,opp_first;
 reg scanned;reg [31:0] scan_version,scan_cal;reg [63:0] scan_session;reg [337:0] scan_snapshot;
 reg [7:0] scan_anchor;
 wire [337:0] scan_board=stage_o==SETUP?lesson_expected:board_o;
 wire scan_start=(stage_o==ACTIVE||stage_o==SETUP)&&pending_mode_o==0&&!tb_busy&&
  (!scanned||scan_version!=version||scan_session!=session||scan_snapshot!=scan_board||
   scan_cal!=calibration_version||scan_anchor!=anchor_seed_index);
 qy_coach_tactics tactics(.clk(clk),.rst_n(rst_n),.start(scan_start),.cancel(interrupted||stage_o==PAUSED||pending_mode_o!=0),
  .board_i(scan_board),.board_size_i(size_o),.side_i(side_o),.version_i(version),
  .busy(tb_busy),.done(tb_done),.valid(tb_valid),.error(tb_error),.result_version(tb_version),
  .own_wins(own),.opp_wins(opp),.own_count(own_n),.opp_count(opp_n),.own_first(own_first),.opp_first(opp_first),
  .terminal_own(to),.terminal_opp(tt));
 reg cert_valid;reg [337:0] cert_board;reg [31:0] cert_version;reg [63:0] cert_session;
 reg [168:0] cert_answers;reg cert_defence;reg [3:0] cert_size;reg [1:0] cert_side;
 reg [31:0] cert_cal;reg [7:0] cert_anchor;
 wire cert_current=cert_valid&&cert_board==board_o&&cert_version==version&&cert_session==session&&
  cert_cal==calibration_version&&(!ORIGIN_OPENING||cert_anchor==anchor_seed_index);
 assign hint_targets_o=hint_safe&&hint_level_o==2?(mode_o==3?(cert_current?cert_answers:169'd0):lesson_answers):169'd0;
 integer k;reg [7:0] first_hint;
 always @* begin first_hint=255;for(k=168;k>=0;k=k-1)if(hint_targets_o[k])first_hint=k;end
 assign hint_target_o=first_hint;
 function [337:0] with_move(input [337:0] b,input [7:0] i,input [1:0] c);
  begin with_move=b;if(i<169)with_move[i*2+:2]=c;end
 endfunction
 task speak(input [7:0] id);begin phrase_valid<=1;phrase_id<=id;last_phrase<=id;end endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   mode_o<=0;pending_mode_o<=0;stage_o<=IDLE;resume_stage<=IDLE;lesson_size<=5;lesson_cal<=0;
   lesson_version<=0;session<=1;lesson_board<=0;lesson_expected<=0;lesson_side<=1;lesson_answers<=0;
   lesson_anchor<=255;lesson_count<=0;retry_count<=0;retry_anchor<=255;retry_cal<=0;
   retry_valid<=0;retry_board<=0;retry_size<=5;retry_side<=1;retry_answers<=0;retry_defence<=0;
   lesson_defence<=0;vertical<=0;hint_level_o<=0;phrase_valid<=0;phrase_id<=0;last_phrase<=0;
   answer_valid<=0;answer_correct<=0;lesson_event_index<=255;game_new<=0;
   scanned<=0;scan_version<=0;scan_session<=0;scan_snapshot<=0;cert_valid<=0;cert_board<=0;cert_version<=0;
   scan_cal<=0;scan_anchor<=255;cert_cal<=0;cert_anchor<=255;
   cert_session<=0;cert_answers<=0;cert_defence<=0;cert_size<=0;cert_side<=0;
  end else begin
   phrase_valid<=0;answer_valid<=0;game_new<=0;
   if(scan_start)begin scanned<=1;scan_version<=version;scan_session<=session;scan_snapshot<=scan_board;
    scan_cal<=calibration_version;scan_anchor<=anchor_seed_index;end
   if(tb_done&&tb_valid&&!tb_error&&!to&&!tt&&tb_version==version&&
     scan_cal==calibration_version&&(!ORIGIN_OPENING||scan_anchor==anchor_seed_index))begin
    cert_valid<=1;cert_board<=scan_board;cert_version<=version;cert_session<=session;
    cert_answers<=own_n!=0?own:opp_n==1?opp:169'd0;cert_defence<=own_n==0&&opp_n==1;
    cert_size<=size_o;cert_side<=side_o;
    cert_cal<=calibration_version;cert_anchor<=anchor_seed_index;
    if(mode_o!=3&&stage_o==SETUP&&mode_o!=4)lesson_answers<=mode_o==1?own:(own_n==0&&opp_n==1?opp:169'd0);
   end
   if(mode_o==3&&game_event&&!game_ai_event&&!retry_valid&&cert_valid&&cert_answers!=0&&
    cert_session==session&&game_version==cert_version+1&&game_color==cert_side&&
    cert_cal==calibration_version&&(!ORIGIN_OPENING||cert_anchor==anchor_seed_index)&&
    game_index<169&&cert_board[game_index*2+:2]==0&&game_board==with_move(cert_board,game_index,game_color)&&
    !cert_answers[game_index])begin
    retry_valid<=1;retry_board<=cert_board;retry_size<=cert_size;retry_side<=cert_side;
    retry_answers<=cert_answers;retry_defence<=cert_defence;speak(cert_defence?8'd22:8'd21);
    retry_cal<=cert_cal;retry_anchor<=cert_anchor;retry_count<=game_count-1'b1;
   end
   // Pause wins over a simultaneous card; all controls precede observations.
   if(cmd_valid&&cmd==4)begin
    if(stage_o!=PAUSED)begin resume_stage<=stage_o;stage_o<=PAUSED;session<=session+1'b1;end
    hint_level_o<=0;speak(8'd13);
   end else if(card_valid&&card_mode>=1&&card_mode<=4)begin
    pending_mode_o<=card_mode;session<=session+1'b1;hint_level_o<=0;cert_valid<=0;speak(8'd10);
   end else if(cmd_valid&&cmd==1&&pending_mode_o!=0)begin
    if(!permission)begin speak(8'd24);end
    else if(pending_mode_o==4&&(!retry_valid||retry_size!=board_size_i||retry_cal!=calibration_version||
     ORIGIN_OPENING&&(retry_anchor!=anchor_seed_index||retry_board[anchor_seed_index*2+:2]!=1)))begin speak(8'd17);end
    else begin
     mode_o<=pending_mode_o;pending_mode_o<=0;session<=session+1'b1;hint_level_o<=0;
     lesson_size<=board_size_i;lesson_cal<=calibration_version;lesson_version<=lesson_version+1'b1;
     lesson_anchor<=anchor_seed_index;
     cert_valid<=0;scanned<=0;vertical<=0;
     if(pending_mode_o==3)begin stage_o<=ACTIVE;game_new<=1;retry_valid<=0;speak(8'd18);end
     else begin
      stage_o<=SETUP;lesson_answers<=pending_mode_o==4?retry_answers:169'd0;
      lesson_side<=pending_mode_o==4?retry_side:2'd1;lesson_defence<=pending_mode_o==4?retry_defence:pending_mode_o==2;
      // Load the ROM on the next cycle once mode/vertical have changed.
      lesson_expected<=pending_mode_o==4?retry_board:338'd0;speak(8'd11);
     end
    end
   end else if(cmd_valid&&cmd==5)begin
    pending_mode_o<=0;session<=session+1'b1;hint_level_o<=0;cert_valid<=0;
    if(stage_o==PAUSED)begin
     if(resume_stage==ACTIVE||resume_stage==ANSWER)begin stage_o<=RECHECK;end
     else stage_o<=resume_stage;
    end else if(stage_o==ACTIVE||stage_o==ANSWER)begin resume_stage<=stage_o;stage_o<=RECHECK;end
    speak(8'd14);
   end else if(cmd_valid&&cmd==6&&pending_mode_o==0&&stage_o==ANSWER&&mode_o!=3)begin
    session<=session+1'b1;lesson_version<=lesson_version+1'b1;stage_o<=SETUP;hint_level_o<=0;scanned<=0;
    if(mode_o==4)lesson_expected<=retry_board;
    else begin vertical<=!vertical;lesson_expected<=0;lesson_answers<=0;end
    speak(8'd11);
   end else if(cmd_valid&&cmd==2&&running)begin
    if(!hint_safe||mode_o==3&&(!cert_current||cert_answers==0))begin hint_level_o<=0;speak(8'd23);end
    else begin
     hint_level_o<=hint_level_o==2?0:hint_level_o+1'b1;
     speak(hint_level_o==0?8'd15:hint_level_o==1?8'd16:8'd12);
    end
   end else if(cmd_valid&&cmd==3)begin
    if((last_phrase==15||last_phrase==16)&&!hint_safe)speak(8'd23);
    else if(last_phrase!=0)begin phrase_valid<=1;phrase_id<=last_phrase;end
   end else if(pending_mode_o==0&&!interrupted)begin
    if(stage_o==SETUP&&mode_o!=4&&lesson_expected==0&&rom_valid)begin lesson_expected<=rom_board;scanned<=0;end
    if(matched&&matching)begin
     if(stage_o==RECHECK)begin stage_o<=resume_stage;speak(8'd12);end
     else if(lesson_answers!=0)begin
      lesson_board<=lesson_expected;lesson_version<=lesson_version+1'b1;stage_o<=ACTIVE;session<=session+1'b1;
      lesson_count<=mode_o==4?retry_count:8'd8;
      speak(8'd12);
     end
    end
    if(proposal&&allowed&&lesson_running&&answer_index<169)begin
     lesson_board<=with_move(lesson_board,answer_index,color);lesson_version<=lesson_version+1'b1;
     lesson_count<=lesson_count+1'b1;
     stage_o<=ANSWER;answer_valid<=1;answer_correct<=lesson_answers[answer_index];lesson_event_index<=answer_index;
     hint_level_o<=0;session<=session+1'b1;
     if(lesson_answers[answer_index])speak(8'd19);
     else begin
      speak(8'd20);
      if(!retry_valid)begin
       retry_valid<=1;retry_board<=lesson_board;retry_size<=lesson_size;retry_side<=lesson_side;
       retry_answers<=lesson_answers;retry_defence<=lesson_defence;
       retry_cal<=lesson_cal;retry_anchor<=lesson_anchor;retry_count<=lesson_count;
      end
     end
    end
   end
   if(mode_o!=0&&(!lesson_identity)&&stage_o!=IDLE&&pending_mode_o==0&&!interrupted)begin
    stage_o<=ERROR;hint_level_o<=0;
   end
   if(session==64'hfffffffffffffffe||lesson_version==32'hfffffffe)begin stage_o<=ERROR;end
  end
 end
endmodule
`default_nettype wire
