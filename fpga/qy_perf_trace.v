`timescale 1ns/1ps
`default_nettype none
// Passive NN-clock accounting. No signal from this module gates inference.
// 100 MHz local 64-bit timestamps, saturating 32-bit job residency counters.
// Four immutable pages per job. A busy output drops a whole snapshot and counts
// it, never backpressures the datapath. DDR counters overlap residency counters.
module qy_perf_trace #(parameter ENABLE=1, parameter [31:0] CLOCK_HZ=100000000)(
 input wire clk,rst,
 input wire [3:0] phase,engine_phase,program_phase,opcode,
 input wire [1:0] mode,
 input wire model_ready,lease_request,lease_response,
 input wire [31:0] capture_start_count,capture_end_count,capture_ready_count,
 input wire job_start,job_done,job_success,display_ack,
 input wire [31:0] job_tag,job_frame,
 input wire [15:0] last_error,
 input wire preview_ready,
 input wire rd_valid,rd_ready,rsp_valid,rsp_ready,
 input wire wr_valid,wr_ready,ack_valid,ack_ready,
 input wire result_valid,result_ready,result_last,
 output wire trace_valid,input wire trace_ready,output reg [639:0] trace_data
);
 reg [63:0] ticks,request_tick,lease_tick,start_tick,pre_tick,nn_start_tick,nn_end_tick,post_tick,boot_tick;
 reg [31:0] counts[0:29];
 reg [31:0] snapshot[0:59];
 reg [31:0] published_tag,published_frame,published_flags,overruns;
 reg [31:0] prior_frame,cap_start,cap_end,cap_ready;
 reg [1:0] page; reg pending,active,await_display,overflow,rd_pending,wr_pending;
 reg [31:0] display_wait;
 reg [3:0] old_engine;
 reg old_model,error_capture_pending;
 integer i,j;
 wire [29:0] increment={
   (active&&wr_valid&&wr_ready),
   (active&&rd_valid&&rd_ready),
   (active&&engine_phase==5&&program_phase==6&&opcode==12),
   (active&&engine_phase==5&&program_phase==6&&opcode==11),
   (active&&engine_phase==5&&program_phase==6&&opcode==10),
   (active&&engine_phase==5&&program_phase==6&&opcode==9),
   (active&&engine_phase==5&&program_phase==6&&opcode==8),
   (active&&engine_phase==5&&program_phase==6&&opcode==7),
   (active&&engine_phase==5&&program_phase==6&&opcode==6),
   (active&&engine_phase==5&&program_phase==6&&opcode==5),
   (active&&engine_phase==5&&program_phase==6&&opcode==4),
   (active&&engine_phase==5&&program_phase==6&&opcode==3),
   (active&&engine_phase==5&&program_phase==6&&opcode==2),
   (active&&engine_phase==5&&program_phase==6&&opcode==1),
   (active&&engine_phase==5&&program_phase==6&&(opcode==1||opcode==2||opcode==5)),
   (active&&engine_phase==5&&program_phase==6&&(opcode==4||opcode==8||opcode==9||opcode==11||opcode==12)),
   (active&&engine_phase==5&&(program_phase==3||program_phase==4)),
   (active&&result_valid&&!result_ready),
   (active&&wr_pending),
   (active&&wr_valid&&!wr_ready),
   (active&&rd_pending),
   (active&&rd_valid&&!rd_ready),
   (phase==4&&!preview_ready&&mode!=1),
   (active&&engine_phase==3),
   (active&&engine_phase==7),
   (active&&engine_phase==5),
   (active&&engine_phase==2),
   (phase==3),
   (phase==2),
   active
 };
 assign trace_valid=ENABLE&&!rst&&pending&&!await_display;
 always @* begin
   trace_data=0;
   trace_data[31:0]=published_tag;
   trace_data[63:32]=published_frame;
   trace_data[95:64]={24'h000001,6'd0,page};
   trace_data[127:96]=published_flags;
   for(j=0;j<15;j=j+1) trace_data[(j+4)*32+:32]=snapshot[page*15+j];
   trace_data[639:608]=32'h51595054;
 end
 always @(posedge clk) begin
  if(rst||!ENABLE) begin
   ticks<=0;request_tick<=0;lease_tick<=0;start_tick<=0;pre_tick<=0;nn_start_tick<=0;nn_end_tick<=0;post_tick<=0;boot_tick<=0;
   published_tag<=0;published_frame<=0;published_flags<=0;overruns<=0;prior_frame<=0;cap_start<=0;cap_end<=0;cap_ready<=0;
   page<=0;pending<=0;active<=0;await_display<=0;overflow<=0;rd_pending<=0;wr_pending<=0;display_wait<=0;old_engine<=0;old_model<=0;error_capture_pending<=0;
   for(i=0;i<30;i=i+1) counts[i]<=0;
   for(i=0;i<60;i=i+1) snapshot[i]<=0;
  end else begin
   ticks<=ticks+1'b1;old_engine<=engine_phase;old_model<=model_ready;
   error_capture_pending<=0;
   if(error_capture_pending) snapshot[26]<={16'd0,last_error};
   if(model_ready&&!old_model) boot_tick<=ticks;
   if(lease_request) request_tick<=ticks;
   if(lease_response) begin lease_tick<=ticks;cap_start<=capture_start_count;cap_end<=capture_end_count;cap_ready<=capture_ready_count;end
   for(i=0;i<30;i=i+1) if(increment[i]) begin
    if(counts[i]==32'hffffffff) overflow<=1;
    else counts[i]<=counts[i]+1'b1;
   end
   if(rd_valid&&rd_ready) rd_pending<=1;
   if(rsp_valid&&rsp_ready) rd_pending<=0;
   if(wr_valid&&wr_ready) wr_pending<=1;
   if(ack_valid&&ack_ready) wr_pending<=0;
   if(job_start) begin
    active<=1;start_tick<=ticks;pre_tick<=0;nn_start_tick<=0;nn_end_tick<=0;post_tick<=0;overflow<=0;
    // Queue counters survive from the preceding job boundary. All service
    // counters begin here; there is at most one memory request per channel.
    for(i=0;i<30;i=i+1) if(i!=1&&i!=2&&i!=7) counts[i]<=0;
   end
   if(active&&old_engine==2&&engine_phase!=2) pre_tick<=ticks;
   if(active&&old_engine!=5&&engine_phase==5) nn_start_tick<=ticks;
   if(active&&old_engine==5&&engine_phase!=5) nn_end_tick<=ticks;
   if(active&&result_valid&&result_ready&&result_last) post_tick<=ticks;
   if(trace_valid&&trace_ready) begin
    if(page==3) begin pending<=0;page<=0;end else page<=page+1'b1;
   end
   if(await_display) begin
    if(display_ack) begin
     snapshot[19]<=ticks[31:0];snapshot[20]<=ticks[63:32];await_display<=0;published_flags[4]<=1;
    end else if(display_wait==CLOCK_HZ/10) begin await_display<=0;published_flags[5]<=1;end
    else display_wait<=display_wait+1'b1;
   end
   if(job_done) begin
    active<=0;
    if(pending) overruns <= overruns==32'hffffffff ? overruns : overruns+1'b1;
    else begin
     pending<=1;page<=0;await_display<=job_success&&mode!=1;display_wait<=0;error_capture_pending<=1;
     published_tag<=job_tag;published_frame<=job_frame;
     published_flags<={24'd0,overflow,1'b0,1'b0,1'b0,job_success,1'b0,mode};
     snapshot[0]<=request_tick[31:0];snapshot[1]<=request_tick[63:32];
     snapshot[2]<=lease_tick[31:0];snapshot[3]<=lease_tick[63:32];
     snapshot[4]<=start_tick[31:0];snapshot[5]<=start_tick[63:32];
     snapshot[6]<=pre_tick[31:0];snapshot[7]<=pre_tick[63:32];
     snapshot[8]<=nn_start_tick[31:0];snapshot[9]<=nn_start_tick[63:32];
     snapshot[10]<=nn_end_tick[31:0];snapshot[11]<=nn_end_tick[63:32];
     snapshot[12]<=post_tick[31:0];snapshot[13]<=post_tick[63:32];snapshot[14]<=CLOCK_HZ;
     snapshot[15]<=ticks[31:0];snapshot[16]<=ticks[63:32];
     snapshot[17]<=boot_tick[31:0];snapshot[18]<=boot_tick[63:32];snapshot[19]<=0;snapshot[20]<=0;
     snapshot[21]<=cap_start;snapshot[22]<=cap_end;snapshot[23]<=cap_ready;
     snapshot[24]<=job_frame-prior_frame;snapshot[25]<=overruns;
     snapshot[26]<={16'd0,last_error};snapshot[27]<=mode;snapshot[28]<=0;snapshot[29]<=0;
     for(i=0;i<30;i=i+1) snapshot[30+i]<=counts[i]+(increment[i]&&counts[i]!=32'hffffffff ? 1'b1 : 1'b0);
    end
    prior_frame<=job_frame;counts[1]<=0;counts[2]<=0;counts[7]<=0;
   end
  end
 end
endmodule
`default_nettype wire
