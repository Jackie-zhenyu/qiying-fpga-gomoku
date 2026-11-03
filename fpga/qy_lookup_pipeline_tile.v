`timescale 1ns/1ps
`default_nettype none
// Reuse the existing A(64KiB) cache for a unary256/binary65536 byte LUT;
// W(16KiB) holds the one or two operand streams. No new feature-map RAM.
// Optional exact 2x repetition implements nearest-neighbour replication
// without rereading operands or the lookup table for the duplicate pixel.
// Cancellation flushes both public RAM response channels via memory_reset.
module qy_lookup_pipeline_tile (
    input wire clk, input wire rst, input wire cancel, output wire memory_reset,
    input wire cmd_valid, output wire cmd_ready, input wire [31:0] cmd_tag,
    input wire [31:0] cmd_table_base, input wire [31:0] cmd_a_base, input wire [31:0] cmd_b_base,
    input wire [16:0] cmd_count, input wire cmd_binary, input wire cmd_repeat2,
    output wire req_valid, input wire req_ready, output wire [31:0] req_a, output wire [31:0] req_b,
    input wire rsp_valid, output wire rsp_ready, input wire [7:0] rsp_a, input wire [7:0] rsp_b, input wire rsp_error,
    output wire wr_valid, input wire wr_ready, output wire [31:0] wr_addr, output wire [7:0] wr_data,
    input wire ack_valid, output wire ack_ready, input wire ack_error,
    output wire done_valid, input wire done_ready, output reg [31:0] done_tag,
    output reg [31:0] done_written, output reg [7:0] done_error
);
    localparam [3:0] IDLE=0,SIZE=1,CHECK=2,REQ_A=3,GET_A=4,REQ_B=5,GET_B=6,
        REQ_LUT=7,GET_LUT=8,WRITE=9,ACK=10,DONE=11;
    reg [3:0] state;
    // At most one pending result. Reads for the next result can proceed while
    // its predecessor is waiting for the public output-RAM write acknowledgement.
    reg output_valid,awaiting_ack;
    reg [31:0] output_address;
    reg [7:0] output_byte;
    wire active_reset=rst||cancel;
    wire slot_available=!output_valid||(ack_valid&&ack_ready&&!ack_error);
    reg [31:0] table_base,a_base,b_base;
    reg [16:0] count,input_count,index,source_index;
    reg binary,repeat2;
    reg [7:0] first,second,result_byte;
    wire [32:0] table_end={1'b0,table_base}+(binary?33'd65536:33'd256);
    wire [32:0] a_end={1'b0,a_base}+{16'd0,input_count};
    wire [32:0] b_end={1'b0,b_base}+{16'd0,input_count};
    assign memory_reset=active_reset||(state==DONE&&done_error!=0);
    assign cmd_ready=!memory_reset&&state==IDLE;
    assign req_valid=!memory_reset&&(state==REQ_A||state==REQ_B||state==REQ_LUT);
    assign req_a=table_base+((state==REQ_LUT)?(binary?{16'd0,first,second}:{24'd0,first}):32'd0);
    assign req_b=(state==REQ_A)?a_base+{15'd0,source_index}:(state==REQ_B)?b_base+{15'd0,source_index}:32'd0;
    assign rsp_ready=!memory_reset&&(state==GET_A||state==GET_B||(state==GET_LUT&&slot_available));
    assign wr_valid=!active_reset&&output_valid&&!awaiting_ack;assign wr_addr=output_address;assign wr_data=output_byte;
    assign ack_ready=!active_reset&&awaiting_ack;
    assign done_valid=!active_reset&&state==DONE;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;output_valid<=0;awaiting_ack<=0;output_address<=0;output_byte<=0;table_base<=0;a_base<=0;b_base<=0;count<=0;input_count<=0;index<=0;source_index<=0;
            binary<=0;repeat2<=0;first<=0;second<=0;result_byte<=0;done_tag<=0;done_written<=0;done_error<=0;
        end else if(cancel) begin
            output_valid<=0;awaiting_ack<=0;
            if(state!=IDLE) begin done_error<=8'h10;state<=DONE;end
        end else if(ack_valid&&ack_ready&&ack_error) begin
            // Owner invalidates the result transaction after this failed done.
            // Flush any speculative feature response before accepting a new job.
            output_valid<=0;awaiting_ack<=0;done_error<=8;state<=DONE;
        end else begin
            if(wr_valid&&wr_ready) awaiting_ack<=1;
            if(ack_valid&&ack_ready) begin
                output_valid<=0;awaiting_ack<=0;done_written<=done_written+1'b1;
            end
            case(state)
            IDLE:if(cmd_valid) begin
                done_tag<=cmd_tag;done_written<=0;done_error<=0;index<=0;source_index<=0;
                table_base<=cmd_table_base;a_base<=cmd_a_base;b_base<=cmd_b_base;
                count<=cmd_count;binary<=cmd_binary;repeat2<=cmd_repeat2;state<=SIZE;
            end
            SIZE:begin input_count<=count>>repeat2;state<=CHECK;end
            CHECK:if(count==0||count>65536||(repeat2&&count[0])||table_end>65536||a_end>16384||(binary&&b_end>16384)) begin done_error<=1;state<=DONE;end
                else state<=REQ_A;
            REQ_A:if(req_ready) state<=GET_A;
            GET_A:if(rsp_valid) begin
                if(rsp_error) begin output_valid<=0;awaiting_ack<=0;done_error<=2;state<=DONE;end
                else begin first<=rsp_b;state<=binary?REQ_B:REQ_LUT;end
            end
            REQ_B:if(req_ready) state<=GET_B;
            GET_B:if(rsp_valid) begin
                if(rsp_error) begin output_valid<=0;awaiting_ack<=0;done_error<=2;state<=DONE;end
                else begin second<=rsp_b;state<=REQ_LUT;end
            end
            REQ_LUT:if(req_ready) state<=GET_LUT;
            GET_LUT:if(rsp_valid&&rsp_ready) begin
                if(rsp_error) begin output_valid<=0;awaiting_ack<=0;done_error<=2;state<=DONE;end
                else begin
                    result_byte<=rsp_a;output_valid<=1;
                    output_address<={15'd0,index};output_byte<=rsp_a;
                    if(index==count-1) state<=ACK;
                    else begin
                        index<=index+1'b1;
                        if(repeat2&&!index[0]) state<=WRITE;
                        else begin source_index<=source_index+1'b1;state<=REQ_A;end
                    end
                end
            end
            WRITE:if(slot_available) begin
                output_valid<=1;output_address<={15'd0,index};output_byte<=result_byte;
                if(index==count-1) state<=ACK;
                else begin
                    index<=index+1'b1;
                    if(repeat2&&!index[0]) state<=WRITE;
                    else begin source_index<=source_index+1'b1;state<=REQ_A;end
                end
            end
            ACK:if(done_written==count&&!output_valid&&!awaiting_ack) state<=DONE;
            DONE:if(done_ready) state<=IDLE;
            default:begin done_error<=8'h80;state<=DONE;end
            endcase
        end
    end
endmodule
`default_nettype wire
