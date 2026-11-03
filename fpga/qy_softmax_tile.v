`timescale 1ns/1ps
`default_nettype none
// One attention row from the shared A cache, delivered atomically to the
// output cache. The row core is held until every result write is acknowledged.
module qy_softmax_tile #(parameter EXP_FILE="softmax_exp.hex") (
    input wire clk, input wire rst, input wire cancel, output wire memory_reset,
    input wire cmd_valid, output wire cmd_ready, input wire [31:0] cmd_tag,
    input wire [31:0] cmd_a_base, input wire [8:0] cmd_length, input wire cmd_bank,
    input wire [31:0] cmd_multiplier, input wire [5:0] cmd_shift, input wire [7:0] cmd_output_zero,
    output wire req_valid, input wire req_ready, output wire [31:0] req_a, output wire [31:0] req_b,
    input wire rsp_valid, output wire rsp_ready, input wire [7:0] rsp_a, input wire [7:0] rsp_b, input wire rsp_error,
    output wire wr_valid, input wire wr_ready, output wire [31:0] wr_addr, output wire [7:0] wr_data,
    input wire ack_valid, output wire ack_ready, input wire ack_error,
    output wire done_valid, input wire done_ready, output reg [31:0] done_tag,
    output reg [31:0] done_written, output reg [7:0] done_error
);
    localparam [3:0] IDLE=0,CHECK=1,START=2,REQUEST=3,REPLY=4,SEND=5,WAIT_RESULT=6,WRITE=7,ACK=8,ACCEPT=9,DONE=10;
    reg [3:0] state;
    reg [31:0] a_base,multiplier;
    reg [8:0] length,input_index,output_index;
    reg bank;
    reg [5:0] shift;
    reg [7:0] output_zero,input_byte,result_byte;
    wire core_ready,s_ready,m_valid,m_last;
    wire [31:0] m_tag;
    wire [8:0] m_index;
    wire [7:0] m_data;
    wire [2:0] m_error;
    wire [32:0] end_address={1'b0,a_base}+{24'd0,length};
    assign memory_reset=rst||cancel;
    assign cmd_ready=!memory_reset&&state==IDLE;
    assign req_valid=!memory_reset&&state==REQUEST;
    assign req_a=a_base+{23'd0,input_index};assign req_b=0;
    assign rsp_ready=!memory_reset&&state==REPLY;
    assign wr_valid=!memory_reset&&state==WRITE;assign wr_addr={23'd0,output_index};assign wr_data=result_byte;
    assign ack_ready=!memory_reset&&state==ACK;
    assign done_valid=!memory_reset&&state==DONE;
    qy_softmax_row #(.EXP_FILE(EXP_FILE)) core(
        .clk(clk),.rst(memory_reset||state==DONE),.cmd_valid(!memory_reset&&state==START),.cmd_ready(core_ready),
        .cmd_tag(done_tag),.cmd_length(length),.cmd_bank(bank),.cmd_multiplier(multiplier),.cmd_shift(shift),.cmd_output_zero(output_zero),
        .s_valid(!memory_reset&&state==SEND),.s_ready(s_ready),.s_data(input_byte),
        .m_valid(m_valid),.m_ready(!memory_reset&&state==ACCEPT),.m_tag(m_tag),.m_index(m_index),.m_data(m_data),.m_last(m_last),.m_error(m_error));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;a_base<=0;multiplier<=0;length<=0;input_index<=0;output_index<=0;bank<=0;shift<=0;output_zero<=0;
            input_byte<=0;result_byte<=0;done_tag<=0;done_written<=0;done_error<=0;
        end else if(cancel) begin
            if(state!=IDLE) begin state<=DONE;done_error<=8'h10;end
        end else case(state)
            IDLE:if(cmd_valid) begin
                a_base<=cmd_a_base;multiplier<=cmd_multiplier;length<=cmd_length;bank<=cmd_bank;shift<=cmd_shift;output_zero<=cmd_output_zero;
                done_tag<=cmd_tag;done_written<=0;done_error<=0;input_index<=0;output_index<=0;state<=CHECK;
            end
            CHECK:if(length==0||length>400||end_address>65536||multiplier==0||multiplier[31]||shift>31) begin done_error<=1;state<=DONE;end
                else state<=START;
            START:if(core_ready) state<=REQUEST;
            REQUEST:if(req_ready) state<=REPLY;
            REPLY:if(rsp_valid) begin
                if(rsp_error) begin done_error<=2;state<=DONE;end
                else begin input_byte<=rsp_a;state<=SEND;end
            end
            SEND:if(s_ready) begin
                if(input_index==length-1'b1) state<=WAIT_RESULT;
                else begin input_index<=input_index+1'b1;state<=REQUEST;end
            end
            WAIT_RESULT:if(m_valid) begin
                if(m_error!=0) begin done_error<=4;state<=DONE;end
                else if(m_tag!=done_tag||m_index!=output_index||m_last!=(output_index==length-1'b1)) begin done_error<=8'h20;state<=DONE;end
                else begin result_byte<=m_data;state<=WRITE;end
            end
            WRITE:if(wr_ready) state<=ACK;
            ACK:if(ack_valid) begin
                if(ack_error) begin done_error<=8;state<=DONE;end
                else begin done_written<=done_written+1'b1;state<=ACCEPT;end
            end
            ACCEPT:if(m_valid) begin
                if(output_index==length-1'b1) state<=DONE;
                else begin output_index<=output_index+1'b1;state<=WAIT_RESULT;end
            end
            DONE:if(done_ready) state<=IDLE;
            default:begin done_error<=8'h80;state<=DONE;end
        endcase
    end
endmodule
`default_nettype wire
