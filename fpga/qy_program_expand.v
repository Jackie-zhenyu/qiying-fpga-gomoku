`timescale 1ns/1ps
`default_nettype none
// QYAP v1 byte-stream decoder. Literal words or modulo-2^256 arithmetic runs.
// Both compressed and expanded CRC32 must pass before code is executable.
// Acknowledged writes remain private until done_error==0; never execute a
// partial program. The caller cancels/restarts its source stream on error.
// The 256-bit increment is eight registered 32-bit additions, not a wide
// combinational carry chain. No instruction/whole-file on-chip RAM.
module qy_program_expand #(parameter integer INPUT_TIMEOUT=1000000) (
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] cmd_base,input wire [31:0] cmd_encoded_bytes,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,input wire s_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strb,
    input wire b_valid,output wire b_ready,input wire b_error,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,output reg [31:0] done_words,
    output reg [7:0] done_error
);
    localparam [3:0] IDLE=0,COMMAND=1,HEADER=2,CHECK_HEADER=3,RECORD=4,CHECK_RECORD=5,
        VALUE=6,DELTA=7,CRC_WORD=8,WRITE=9,WAIT_WRITE=10,ADD=11,FINISH=12,ABORT=13,DONE=14;
    reg [3:0] state;
    reg [31:0] base,encoded_bytes,consumed,expected_words,expected_crc,payload_bytes,payload_crc;
    reg [31:0] input_crc,output_crc,address,wait_count;
    reg [191:0] header;
    reg [23:0] record_header;
    reg [5:0] index;
    reg [15:0] remaining;
    reg arithmetic;
    reg [255:0] value,delta;
    reg [2:0] add_index;
    reg carry,write_pending;
    reg [7:0] fault;
    wire [32:0] add_result={1'b0,value[add_index*32+:32]}+{1'b0,delta[add_index*32+:32]}+carry;
    wire [37:0] destination_end={6'd0,base}+{1'b0,header[95:64],5'b0};
    wire [32:0] record_end={1'b0,done_words}+{17'd0,record_header[23:8]};
    wire receiving=state==HEADER||state==RECORD||state==VALUE||state==DELTA;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign s_ready=!rst&&!cancel&&receiving&&consumed<encoded_bytes;
    assign wr_valid=!rst&&!cancel&&state==WRITE;
    assign wr_addr=address;assign wr_data=value;assign wr_strb=32'hffffffff;
    assign b_ready=!rst&&(state==WAIT_WRITE||state==ABORT);
    assign done_valid=!rst&&!cancel&&state==DONE;
    function [31:0] crc_byte(input [31:0] old,input [7:0] data);
        integer i;reg [31:0] c;
        begin c=old^{24'd0,data};for(i=0;i<8;i=i+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;base<=0;encoded_bytes<=0;consumed<=0;expected_words<=0;expected_crc<=0;payload_bytes<=0;payload_crc<=0;
            input_crc<=32'hffffffff;output_crc<=32'hffffffff;address<=0;wait_count<=0;header<=0;record_header<=0;
            index<=0;remaining<=0;arithmetic<=0;value<=0;delta<=0;add_index<=0;carry<=0;write_pending<=0;fault<=0;
            done_tag<=0;done_words<=0;done_error<=0;
        end else begin
            if(wr_valid&&wr_ready) write_pending<=1;
            if(b_valid&&b_ready) write_pending<=0;
            if(receiving&&!(s_valid&&s_ready)) wait_count<=wait_count+1'b1;else wait_count<=0;
            if(s_valid&&s_ready) begin consumed<=consumed+1'b1;if(state!=HEADER) input_crc<=crc_byte(input_crc,s_data);end
            if(cancel&&state!=IDLE) begin fault<=8'h80;state<=ABORT;end
            else if(s_valid&&s_ready&&(s_error||(s_last!=(consumed==encoded_bytes-1'b1)))) begin fault<=s_error?8'h02:8'h04;state<=ABORT;end
            else if(receiving&&(consumed==encoded_bytes||wait_count>=INPUT_TIMEOUT)) begin fault<=8'h08;state<=ABORT;end
            else case(state)
                IDLE:if(cmd_valid&&cmd_ready) begin
                    base<=cmd_base;address<=cmd_base;encoded_bytes<=cmd_encoded_bytes;consumed<=0;
                    done_tag<=cmd_tag;done_words<=0;done_error<=0;fault<=0;index<=0;
                    input_crc<=32'hffffffff;output_crc<=32'hffffffff;header<=0;wait_count<=0;state<=COMMAND;
                end
                COMMAND:if(base[4:0]!=0||encoded_bytes<24||encoded_bytes>67108864) begin fault<=1;state<=ABORT;end else state<=HEADER;
                HEADER:if(s_valid&&s_ready) begin
                    header[index*8+:8]<=s_data;
                    if(index==23) begin index<=0;state<=CHECK_HEADER;end else index<=index+1'b1;
                end
                CHECK_HEADER:begin
                    expected_words<=header[95:64];expected_crc<=header[127:96];payload_bytes<=header[159:128];payload_crc<=header[191:160];
                    if(header[31:0]!=32'h50415951||header[63:32]!=1||header[95:64]==0||header[95:64]>1048576||
                       {1'b0,header[159:128]}+33'd24!={1'b0,encoded_bytes}||destination_end>38'h100000000) begin fault<=1;state<=ABORT;end
                    else begin record_header<=0;index<=0;state<=RECORD;end
                end
                RECORD:if(s_valid&&s_ready) begin
                    record_header[index*8+:8]<=s_data;
                    if(index==2) begin index<=0;state<=CHECK_RECORD;end else index<=index+1'b1;
                end
                CHECK_RECORD:begin
                    arithmetic<=record_header[7:0]==1;remaining<=record_header[23:8];index<=0;value<=0;delta<=0;
                    if(record_header[7:0]>1||record_header[23:8]==0||record_end>{1'b0,expected_words}||
                       (record_header[7:0]==1&&record_header[23:8]<3)) begin fault<=8'h10;state<=ABORT;end
                    else state<=VALUE;
                end
                VALUE:if(s_valid&&s_ready) begin
                    value[index*8+:8]<=s_data;
                    if(index==31) begin index<=0;state<=arithmetic?DELTA:CRC_WORD;end else index<=index+1'b1;
                end
                DELTA:if(s_valid&&s_ready) begin
                    delta[index*8+:8]<=s_data;
                    if(index==31) begin index<=0;state<=CRC_WORD;end else index<=index+1'b1;
                end
                CRC_WORD:begin
                    output_crc<=crc_byte(output_crc,value[index*8+:8]);
                    if(index==31) begin index<=0;state<=WRITE;end else index<=index+1'b1;
                end
                WRITE:if(wr_ready) state<=WAIT_WRITE;
                WAIT_WRITE:if(b_valid) begin
                    if(b_error) begin fault<=8'h20;state<=ABORT;end
                    else begin
                        done_words<=done_words+1'b1;address<=address+32;remaining<=remaining-1'b1;
                        if(remaining==1) begin
                            if(done_words+1'b1==expected_words) state<=FINISH;
                            else begin index<=0;record_header<=0;state<=RECORD;end
                        end else if(arithmetic) begin add_index<=0;carry<=0;state<=ADD;end
                        else begin index<=0;state<=VALUE;end
                    end
                end
                ADD:begin
                    value[add_index*32+:32]<=add_result[31:0];carry<=add_result[32];
                    if(add_index==7) begin index<=0;state<=CRC_WORD;end else add_index<=add_index+1'b1;
                end
                FINISH:if(consumed!=encoded_bytes||(~input_crc)!=payload_crc||(~output_crc)!=expected_crc) begin fault<=8'h40;state<=ABORT;end
                    else begin done_error<=0;state<=DONE;end
                ABORT:if(!write_pending) begin done_error<=fault;state<=DONE;end
                DONE:if(done_ready) state<=IDLE;
                default:begin fault<=8'h40;state<=ABORT;end
            endcase
        end
    end
endmodule
`default_nettype wire
