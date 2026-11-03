`timescale 1ns/1ps
`default_nettype none
// GAM2 keeps its original wire layout. Optional GAC1 transaction snapshots
// share this packet register, CDC mailbox and UART without stalling play.
module qy_game_telemetry #(
 parameter ENABLE_GAC1=0,
 parameter integer CLK_HZ=137500000,GAC_HZ=10,
 parameter [31:0] GAC_BUILD_ID=32'h06410004
)(
 input wire video_clk,bus_clk,common_reset_n,result_valid,
 input wire [337:0] board,input wire [95:0] meta,input wire [31:0] origin_status,
 input wire [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
 input wire [191:0] cal_diag_data,input wire [7:0] cal_diag_events,
 output wire diag_valid,input wire diag_ready,output wire [639:0] diag_data
);
 wire video_reset_n,bus_reset_n;
 qy_reset_sync vr(.clk_i(video_clk),.arst_n_i(common_reset_n),.rst_n_o(video_reset_n));
 qy_reset_sync br(.clk_i(bus_clk),.arst_n_i(common_reset_n),.rst_n_o(bus_reset_n));
 reg [1:0] state;reg [639:0] packet;reg [13:0] dropped;
 wire gac_grant;wire [639:0] gac_packet;
 wire request_ready,response_valid,response_unused,m_response_ready;
 qy_cdc_request_response #(.REQUEST_BITS(640),.RESPONSE_BITS(1),.REQUEST_BANK_BITS(32)) mailbox(
  .s_clk(video_clk),.s_rst(!video_reset_n),.s_valid(state==1),.s_ready(request_ready),.s_data(packet),
  .s_response_valid(response_valid),.s_response_ready(1'b1),.s_response_data(response_unused),
  .m_clk(bus_clk),.m_rst(!bus_reset_n),.m_valid(diag_valid),.m_ready(diag_ready),.m_data(diag_data),
  .m_response_valid(1'b1),.m_response_ready(m_response_ready),.m_response_data(1'b0));
 generate if(ENABLE_GAC1)begin:gac1
  // Round up so a non-divisible test/board clock cannot exceed GAC_HZ.
  localparam integer DIVIDED_PERIOD=GAC_HZ>0?(CLK_HZ+GAC_HZ-1)/GAC_HZ:1;
  localparam integer PERIOD_CYCLES=DIVIDED_PERIOD>0?DIVIDED_PERIOD:1;
  localparam integer PERIOD_BITS=PERIOD_CYCLES>1?$clog2(PERIOD_CYCLES):1;
  reg [PERIOD_BITS-1:0] cooldown;
  reg [1:0] settle;
  reg [3:0] nonquiet_wait;
  reg [7:0] pending_events;
  reg [15:0] coalesced;
  reg [31:0] packet_sequence;
  reg prefer_game;
  wire [7:0] source_events={1'b0,cal_diag_events[6:0]};
  wire event_now=|source_events;
  wire settled=settle==0&&!event_now;
  wire due=cooldown==0;
  // A chattering diagnostic source must not silence its own heartbeat.
  // Bit0 in transport_flags marks a sample taken without a quiet interval.
  wire force_sample=nonquiet_wait==4'hf;
  wire [7:0] transport_flags={5'd0,
   cal_diag_data[191:160]!=source_frame,cal_diag_data[95],!settled};
  assign gac_grant=state==0&&due&&(settled||force_sample)&&
   (!prefer_game||!result_valid);
  assign gac_packet={32'd0,coalesced,2'd0,dropped,origin_status,meta,
   total_cycles,compute_cycles,source_frame,result_sequence,cal_diag_data,
   GAC_BUILD_ID,packet_sequence+32'd1,transport_flags,pending_events|source_events,
   8'd80,8'd1,32'h31434147};
  always @(posedge video_clk)begin
   if(!video_reset_n)begin
    cooldown<=0;settle<=3;nonquiet_wait<=0;pending_events<=8'h80;
    coalesced<=0;packet_sequence<=0;prefer_game<=0;
   end else begin
    if(cooldown!=0)cooldown<=cooldown-1'b1;
    if(event_now)begin
     settle<=3;
     pending_events<=pending_events|source_events;
     if(pending_events!=0&&coalesced!=16'hffff)coalesced<=coalesced+1'b1;
    end else if(settle!=0)settle<=settle-1'b1;
    if(due&&!settled)begin
     if(nonquiet_wait!=4'hf)nonquiet_wait<=nonquiet_wait+1'b1;
    end else nonquiet_wait<=0;
    if(gac_grant)begin
     cooldown<=PERIOD_CYCLES-1;packet_sequence<=packet_sequence+1'b1;
     pending_events<=0;nonquiet_wait<=0;prefer_game<=1;
    end else if(state==0&&result_valid)prefer_game<=0;
   end
  end
 end else begin:legacy_gam2
  assign gac_grant=1'b0;
  assign gac_packet=640'd0;
 end endgenerate
 always @(posedge video_clk)begin
  if(!video_reset_n)begin state<=0;packet<=0;dropped<=0;end
  else begin
   if(result_valid&&(state!=0||gac_grant)&&dropped!=14'h3fff)dropped<=dropped+1'b1;
   case(state)
    0:if(gac_grant)begin
     packet<=gac_packet;state<=1;
    end else if(result_valid)begin
     packet<={origin_status,dropped,board,meta,total_cycles,compute_cycles,source_frame,result_sequence,32'h324d4147};state<=1;
    end
    1:if(request_ready)state<=2;
    2:if(response_valid)state<=0;
    default:state<=0;
   endcase
  end
 end
endmodule
`default_nettype wire
