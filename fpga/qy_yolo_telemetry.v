`timescale 1ns/1ps
`default_nettype none
// Read-only progress and two leading detection excerpts; complete decoder
// still processes all 256 results. Excerpts publish atomically on success.
// No observation ever writes the official Gomoku board.
module qy_yolo_telemetry #(parameter integer HEARTBEAT_CYCLES=100000000)(
    input wire clk,input wire rst,input wire suppress_heartbeat,
    input wire [3:0] phase,boot_phase,engine_phase,input wire [1:0] boot_asset,input wire model_ready,
    input wire [15:0] last_error,input wire [31:0] completed_jobs,
    input wire job_start,job_done,job_success,input wire [31:0] job_frame,job_tag,
    input wire result_valid,output wire result_ready,input wire [31:0] result_tag,
    input wire [8:0] result_index,input wire [191:0] result_data,input wire result_last,
    output wire update_valid,input wire update_ready,output wire [639:0] update_data
);
    reg [31:0] timer,sequence_id,published_frame,published_tag;
    reg [191:0] pending0,pending1,published0,published1;
    reg [8:0] received,published_received;reg [15:0] count,published_count;
    reg protocol_error,published_success,update_pending,notify_pending;
    reg [639:0] snapshot;
    assign result_ready=!rst;
    assign update_valid=!rst&&update_pending;
    assign update_data=snapshot;
    wire [639:0] live_data={32'h594f3236,published_frame,published1,published0,sequence_id,
        7'd0,published_received,published_count,published_success,model_ready,boot_asset,engine_phase,boot_phase,phase,
        last_error,completed_jobs,published_frame,published_tag};
    always @(posedge clk) begin
        if(rst) begin timer<=0;sequence_id<=0;published_frame<=0;published_tag<=0;pending0<=0;pending1<=0;published0<=0;published1<=0;
            received<=0;published_received<=0;count<=0;published_count<=0;protocol_error<=0;published_success<=0;update_pending<=0;notify_pending<=0;snapshot<=0;end
        else begin
            if(timer==HEARTBEAT_CYCLES-1) begin timer<=0;if(!suppress_heartbeat) notify_pending<=1;end else timer<=timer+1'b1;
            if(update_valid&&update_ready) begin update_pending<=0;sequence_id<=sequence_id+1'b1;end
            if(notify_pending&&(!update_pending||update_ready)) begin snapshot<=live_data;update_pending<=1;notify_pending<=0;end
            if(job_start) begin pending0<=0;pending1<=0;received<=0;count<=0;protocol_error<=0;end
            if(result_valid&&result_ready) begin
                if(result_tag!=job_tag||result_index!=received||result_last!=(result_index==255)||received>=256) protocol_error<=1;
                received<=received+1'b1;
                if(result_index==0) pending0<=result_data;
                if(result_index==1) pending1<=result_data;
                // Positive finite FP32 confidence >=0.25. NaN/Inf rejected.
                if(!result_data[159]&&result_data[158:151]!=8'hff&&result_data[159:128]>=32'h3e800000) count<=count+1'b1;
            end
            if(job_done) begin
                published_success<=job_success&&!protocol_error&&received==256;
                if(job_success&&!protocol_error&&received==256) begin
                    published0<=pending0;published1<=pending1;published_frame<=job_frame;published_tag<=job_tag;
                    published_count<=count;published_received<=received;
                end
                notify_pending<=1;
            end
        end
    end
endmodule
`default_nettype wire
