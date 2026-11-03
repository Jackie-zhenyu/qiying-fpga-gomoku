`timescale 1ns/1ps
`default_nettype none
// Both links and their application events stay in clk's existing pixel domain.
// Each UART owns the two-flop synchronizer on its asynchronous RX pin.
module qy_peripheral_transport #(
 parameter CLK_HZ=137500000,BAUD=115200,
 parameter [63:0] NFC_STARTUP_US=100000,NFC_WAKE_US=10000,
 parameter [63:0] NFC_POLL_US=150000,NFC_TIMEOUT_US=1000000
)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire nfc_rx,voice_rx,output wire nfc_tx,voice_tx,
 input wire nfc_restart,voice_enabled,
 output wire uid_valid,output wire [79:0] uid,output wire [3:0] uid_length,
 output wire card_present,nfc_ready,nfc_fault,
 output wire [31:0] nfc_errors,voice_errors,
 output wire voice_cmd_valid,output wire [3:0] voice_cmd,
 input wire phrase_valid,input wire [7:0] phrase_id,input wire speech_cancel,
 output wire speech_busy
);
 wire nfc_rst_n=rst_n&&!nfc_restart;
 wire nr_valid,nr_error,nt_valid,nt_ready;
 wire [7:0] nr_data,nt_data;
 qy_teacher_uart #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) nfc_uart(
  .clk(clk),.rst_n(nfc_rst_n),.rx(nfc_rx),.tx(nfc_tx),
  .rx_valid(nr_valid),.rx_data(nr_data),.rx_error(nr_error),
  .tx_valid(nt_valid),.tx_data(nt_data),.tx_ready(nt_ready));
 qy_pn532_host #(.STARTUP_US(NFC_STARTUP_US),.WAKE_US(NFC_WAKE_US),
  .POLL_US(NFC_POLL_US),.TIMEOUT_US(NFC_TIMEOUT_US)) nfc_host(
  .clk(clk),.rst_n(nfc_rst_n),.now_us(now_us),
  .rx_valid(nr_valid),.rx_error(nr_error),.rx_data(nr_data),
  .tx_valid(nt_valid),.tx_data(nt_data),.tx_ready(nt_ready),
  .uid_valid(uid_valid),.uid(uid),.uid_length(uid_length),.card_present(card_present),
  .ready(nfc_ready),.fault(nfc_fault),.errors(nfc_errors));

 // The leaf ignores unconfigured RX traffic and never starts new speech while
 // disabled. Keep the UART alive so disabling does not truncate an in-flight
 // byte or frame. NFC restart never resets this independent voice link.
 wire vr_valid,vr_error,vt_valid,vt_ready;
 wire [7:0] vr_data,vt_data;
 qy_teacher_uart #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) voice_uart(
  .clk(clk),.rst_n(rst_n),.rx(voice_rx),.tx(voice_tx),
  .rx_valid(vr_valid),.rx_data(vr_data),.rx_error(vr_error),
  .tx_valid(vt_valid),.tx_data(vt_data),.tx_ready(vt_ready));
 qy_peripheral_voice voice(
  .clk(clk),.rst_n(rst_n),.now_us(now_us),.enabled(voice_enabled),
  .rx_valid(vr_valid),.rx_error(vr_error),.rx_data(vr_data),
  .cmd_valid(voice_cmd_valid),.cmd(voice_cmd),
  .phrase_valid(phrase_valid),.phrase_id(phrase_id),.invalidate(speech_cancel),
  .tx_valid(vt_valid),.tx_data(vt_data),.tx_ready(vt_ready),
  .speech_busy(speech_busy),.rejected(voice_errors));
endmodule
`default_nettype wire
