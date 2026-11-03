`timescale 1ns/1ps
`default_nettype none
// Integrated FPGA application boundary: two UART wires + qualified observation
// records from the existing camera pipeline. Pin mapping and HDMI are not here.
module qy_teacher_preflight_top #(
 parameter CLK_HZ=137500000,BAUD=115200,NFC_ENABLE=0,VOICE_PROFILE_READY=0,
 parameter [47:0] VOICE_COMMAND_IDS=48'h060504030201,
 parameter [119:0] VOICE_PHRASE_IDS=120'h1817161514131211100f0e0d0c0b0a,
 parameter [3:0] CARD_ENABLE=0,
 parameter [319:0] CARD_UIDS=0,parameter [15:0] CARD_LENGTHS=0,
 parameter [63:0] NFC_STARTUP_US=100000,NFC_WAKE_US=10000,NFC_POLL_US=150000,NFC_TIMEOUT_US=1000000,
 parameter MIN_FRAMES=3,parameter [63:0] STABLE_US=250000,
 parameter SEARCH_DEPTH=3,SEARCH_NODES=20000,ORIGIN_OPENING=0
)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire nfc_rx,voice_rx,output wire nfc_tx,voice_tx,
 input wire key_cmd_valid,input wire [2:0] key_cmd,
 input wire manual_mode_valid,input wire [2:0] manual_mode,
 input wire calibrated,safety_clear,input wire [3:0] board_size_i,
 input wire anchor_seed_valid,input wire [7:0] anchor_seed_index,
 input wire [31:0] calibration_version,safety_epoch,
 input wire obs_valid,output wire obs_ready,
 input wire [191:0] obs_context,input wire [31:0] obs_safety_epoch,
 input wire [63:0] obs_frame,obs_capture_us,input wire obs_complete,obs_board_observable,
 input wire [15:0] obs_quality,input wire [337:0] obs_cells,
 input wire [168:0] obs_observable,input wire [1351:0] obs_confidence,
 output wire [191:0] context_o,output wire [337:0] board_o,setup_board_o,
 output wire [2:0] mode_o,pending_mode_o,output wire [3:0] stage_o,
 output wire [1:0] hint_level_o,output wire [168:0] hint_targets_o,output wire [7:0] hint_target_o,
 output wire [3:0] size_o,output wire [1:0] side_o,
 output wire ai_target_valid,output wire [7:0] ai_target_index,
 output wire [3:0] game_phase,output wire [7:0] move_count,output wire game_over,output wire [1:0] winner,
 output wire [1:0] next_color_o,output wire [7:0] last_index_o,output wire last_valid_o,
 output wire event_valid,event_is_ai,output wire [7:0] event_index,output wire [1:0] event_color,
 output wire retry_valid,answer_valid,answer_correct,fault,
 output wire phrase_valid,output wire [7:0] phrase_id,
 output wire nfc_ready,nfc_fault,unknown_card,output wire [31:0] nfc_errors,
 output wire uid_valid,output wire [79:0] uid,output wire [3:0] uid_length
);
 wire nr_valid,nr_error,nt_valid,nt_ready,vr_valid,vr_error,vt_valid,vt_ready;
 wire [7:0] nr_data,nt_data,vr_data,vt_data;
 // Unconfigured peripherals stay in reset: idle-high TX, no polling/faults,
 // and no interpretation of disconnected or stock-firmware RX traffic.
 wire nfc_rst_n=rst_n&&NFC_ENABLE;
 wire voice_rst_n=rst_n&&VOICE_PROFILE_READY;
 qy_teacher_uart #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) nfc_uart(
  .clk(clk),.rst_n(nfc_rst_n),.rx(nfc_rx),.tx(nfc_tx),.rx_valid(nr_valid),.rx_data(nr_data),.rx_error(nr_error),
  .tx_valid(nt_valid),.tx_data(nt_data),.tx_ready(nt_ready));
 qy_teacher_uart #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) voice_uart(
  .clk(clk),.rst_n(voice_rst_n),.rx(voice_rx),.tx(voice_tx),.rx_valid(vr_valid),.rx_data(vr_data),.rx_error(vr_error),
  .tx_valid(vt_valid),.tx_data(vt_data),.tx_ready(vt_ready));
 qy_pn532_host #(.STARTUP_US(NFC_STARTUP_US),.WAKE_US(NFC_WAKE_US),.POLL_US(NFC_POLL_US),.TIMEOUT_US(NFC_TIMEOUT_US)) nfc(
  .clk(clk),.rst_n(nfc_rst_n),.now_us(now_us),.rx_valid(nr_valid),.rx_error(nr_error),.rx_data(nr_data),
  .tx_valid(nt_valid),.tx_data(nt_data),.tx_ready(nt_ready),.uid_valid(uid_valid),.uid(uid),.uid_length(uid_length),
  .ready(nfc_ready),.fault(nfc_fault),.errors(nfc_errors));
 wire card_valid;wire [2:0] card_mode;
 qy_teacher_cards cards(.clk(clk),.rst_n(rst_n),.uid_valid(uid_valid),.uid(uid),.uid_length(uid_length),
  .enabled(NFC_ENABLE?CARD_ENABLE:4'd0),.uids(CARD_UIDS),.lengths(CARD_LENGTHS),.card_valid(card_valid),.card_mode(card_mode),.unknown(unknown_card));
 reg [191:0] previous_context;
 always @(posedge clk)if(!rst_n)previous_context<=0;else previous_context<=context_o;
 wire voice_cmd_valid,speech_cancel;wire [2:0] voice_cmd;
 qy_teacher_voice #(.PROFILE_READY(VOICE_PROFILE_READY),.COMMAND_IDS(VOICE_COMMAND_IDS),.PHRASE_IDS(VOICE_PHRASE_IDS)) voice(
  .clk(clk),.rst_n(rst_n),.now_us(now_us),.rx_valid(vr_valid),.rx_error(vr_error),.rx_data(vr_data),
  .cmd_valid(voice_cmd_valid),.cmd(voice_cmd),.phrase_valid(phrase_valid),.phrase_id(phrase_id),
  // The core publishes a new phrase with its new context on the same edge.
  // That fresh phrase replaces old pending speech; a silent context change flushes it.
  .invalidate((previous_context!=context_o||speech_cancel||!calibrated||!safety_clear)&&!phrase_valid),
  .tx_valid(vt_valid),.tx_data(vt_data),.tx_ready(vt_ready),.rejected());
 // Pause from either source wins; otherwise an explicit physical key wins.
 wire pause_cmd=(key_cmd_valid&&key_cmd==4)||(voice_cmd_valid&&voice_cmd==4);
 wire command_valid=key_cmd_valid||voice_cmd_valid;
 wire [2:0] command=pause_cmd?3'd4:key_cmd_valid?key_cmd:voice_cmd;
 qy_teacher_core #(.MIN_FRAMES(MIN_FRAMES),.STABLE_US(STABLE_US),.SEARCH_DEPTH(SEARCH_DEPTH),
  .SEARCH_NODES(SEARCH_NODES),.ORIGIN_OPENING(ORIGIN_OPENING)) app(
  .clk(clk),.rst_n(rst_n),.card_valid(card_valid||manual_mode_valid),
  .card_mode(manual_mode_valid?manual_mode:card_mode),.cmd_valid(command_valid),.cmd(command),
  .calibrated(calibrated),.safety_clear(safety_clear),.board_size_i(board_size_i),
  .anchor_seed_valid(anchor_seed_valid),.anchor_seed_index(anchor_seed_index),.calibration_version(calibration_version),
  .safety_epoch(safety_epoch),.now_us(now_us),.obs_valid(obs_valid),.obs_ready(obs_ready),
  .obs_context(obs_context),.obs_safety_epoch(obs_safety_epoch),.obs_frame(obs_frame),.obs_capture_us(obs_capture_us),
  .obs_complete(obs_complete),.obs_board_observable(obs_board_observable),.obs_quality(obs_quality),
  .obs_cells(obs_cells),.obs_observable(obs_observable),.obs_confidence(obs_confidence),
  .context_o(context_o),.board_o(board_o),.setup_board_o(setup_board_o),.mode_o(mode_o),.pending_mode_o(pending_mode_o),
  .stage_o(stage_o),.hint_level_o(hint_level_o),.hint_targets_o(hint_targets_o),.hint_target_o(hint_target_o),
  .size_o(size_o),.side_o(side_o),.ai_target_valid(ai_target_valid),.ai_target_index(ai_target_index),
  .game_phase(game_phase),.move_count(move_count),.game_over(game_over),.winner(winner),
  .next_color_o(next_color_o),.last_index_o(last_index_o),.last_valid_o(last_valid_o),
  .event_valid(event_valid),.event_is_ai(event_is_ai),.event_index(event_index),.event_color(event_color),
  .retry_valid(retry_valid),.phrase_valid(phrase_valid),.phrase_id(phrase_id),
  .speech_cancel(speech_cancel),
  .answer_valid(answer_valid),.answer_correct(answer_correct),.fault(fault));
endmodule
`default_nettype wire
