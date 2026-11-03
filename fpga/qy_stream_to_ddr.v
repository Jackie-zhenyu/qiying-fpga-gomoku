`timescale 1ns/1ps
`default_nettype none
// Bounded aligned asset copy. Bytes, last flag, CRC and all write responses
// must validate before publication. One 32-byte buffer, no whole asset RAM.
module qy_stream_to_ddr #(parameter integer INPUT_TIMEOUT=1000000)(
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] cmd_base,input wire [31:0] cmd_length,input wire [31:0] cmd_crc,
    input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strb,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,output reg [7:0] done_error
);
    localparam [2:0] IDLE=0,CHECK=1,RECEIVE=2,WRITE=3,ACK=4,FINISH=5,ABORT=6,DONE=7;
    reg [2:0] state;reg [31:0] address,length,received,expected_crc,crc,wait_count;
    reg [255:0] buffer;reg [4:0] index;reg pending;reg [7:0] fault;
    wire [32:0] end_address={1'b0,address}+{1'b0,length};
    assign cmd_ready=!rst&&!cancel&&state==IDLE;assign s_ready=!rst&&!cancel&&state==RECEIVE;
    assign wr_valid=!rst&&!cancel&&state==WRITE;assign wr_addr=address;assign wr_data=buffer;assign wr_strb=32'hffffffff;
    assign ack_ready=!rst&&(state==ACK||state==ABORT);assign done_valid=!rst&&!cancel&&state==DONE;
    function [31:0] crc_byte(input [31:0] old,input [7:0] data);
        integer i;reg [31:0] c;begin c=old^{24'd0,data};for(i=0;i<8;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;address<=0;length<=0;received<=0;expected_crc<=0;crc<=0;wait_count<=0;buffer<=0;index<=0;pending<=0;fault<=0;done_tag<=0;done_error<=0;end
        else begin
            if(wr_valid&&wr_ready) pending<=1;
            if(ack_valid&&ack_ready) pending<=0;
            if(state==RECEIVE&&!(s_valid&&s_ready)) wait_count<=wait_count+1'b1;else wait_count<=0;
            if(cancel&&state!=IDLE&&state!=ABORT&&state!=DONE) begin fault<=8'h80;state<=ABORT;end
            else case(state)
                IDLE:if(cmd_valid&&cmd_ready) begin address<=cmd_base;length<=cmd_length;received<=0;expected_crc<=cmd_crc;crc<=32'hffffffff;index<=0;wait_count<=0;fault<=0;done_tag<=cmd_tag;done_error<=0;state<=CHECK;end
                CHECK:if(address[4:0]!=0||length==0||length[4:0]!=0||end_address>33'h100000000) begin fault<=1;state<=ABORT;end else state<=RECEIVE;
                RECEIVE:if(wait_count>=INPUT_TIMEOUT) begin fault<=8;state<=ABORT;end
                    else if(s_valid&&s_ready) begin
                        if(s_last!=(received==length-1'b1)) begin fault<=4;state<=ABORT;end
                        else begin
                            buffer[index*8+:8]<=s_data;crc<=crc_byte(crc,s_data);received<=received+1'b1;
                            if(index==31) begin index<=0;state<=WRITE;end else index<=index+1'b1;
                        end
                    end
                WRITE:if(wr_ready) state<=ACK;
                ACK:if(ack_valid) begin
                    if(ack_error) begin fault<=16;state<=ABORT;end
                    else if(received==length) state<=FINISH;
                    else begin address<=address+32;state<=RECEIVE;end
                end
                FINISH:if((~crc)!=expected_crc) begin fault<=32;state<=ABORT;end else begin done_error<=0;state<=DONE;end
                ABORT:if(!pending) begin done_error<=fault;state<=DONE;end
                DONE:if(done_ready) state<=IDLE;
                default:begin fault<=64;state<=ABORT;end
            endcase
        end
    end
endmodule
`default_nettype wire
