`timescale 1ns/1ps
`default_nettype none
// Drain a published tagged U8 cache to strided external rows. Byte strobes
// protect adjacent DDR bytes at unaligned boundaries. One transaction at a time.
// Write-ready means the bus adapter owns the complete address/data/strobe tuple;
// completion requires its later response. No board-specific AXI is implied.
module qy_tile_write_pipeline #(parameter integer CAPACITY=65536)(
    input wire clk,rst,cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] cmd_destination,cmd_row_stride,cmd_cache_base,
    input wire [16:0] cmd_row_bytes,input wire [15:0] cmd_rows,
    output wire cache_valid,input wire cache_ready,output wire [31:0] cache_tag,cache_addr,
    input wire cache_rsp_valid,output wire cache_rsp_ready,input wire [31:0] cache_rsp_tag,
    input wire [7:0] cache_rsp_data,input wire cache_rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strobe,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,done_written,
    output reg [3:0] done_error
);
    localparam [3:0] IDLE=0,SIZE=1,CHECK=2,START_WORD=3,CACHE_REQ=4,CACHE_RSP=5,
        WRITE=6,WAIT_ACK=7,NEXT_ROW=8,DONE=9,DRAIN_CACHE=10,DRAIN_BUS=11,EXTENT=12,BOUNDS=13;
    reg [3:0] state;reg [31:0] destination,row_stride,cache_base,cursor,fetched,word_addr;
    reg [16:0] row_bytes,row_left;reg [15:0] rows,rows_left;
    reg [32:0] byte_count;reg [47:0] last_row_offset;
    reg [255:0] word;reg [31:0] strobe;reg [4:0] lane;reg [5:0] word_bytes;
    reg [48:0] end_destination;reg [33:0] end_cache;reg invalid_extent;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign cache_valid=!rst&&!cancel&&state==CACHE_REQ;
    assign cache_tag=done_tag;assign cache_addr=cache_base+fetched;
    assign cache_rsp_ready=!rst&&(state==CACHE_RSP||state==DRAIN_CACHE);
    assign wr_valid=!rst&&!cancel&&state==WRITE;
    assign wr_addr=word_addr;assign wr_data=word;assign wr_strobe=strobe;
    assign ack_ready=!rst&&(state==WAIT_ACK||state==DRAIN_BUS);
    assign done_valid=!rst&&!cancel&&state==DONE;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;end_destination<=0;end_cache<=0;invalid_extent<=0;destination<=0;row_stride<=0;cache_base<=0;cursor<=0;fetched<=0;word_addr<=0;
            row_bytes<=0;row_left<=0;rows<=0;rows_left<=0;byte_count<=0;last_row_offset<=0;
            word<=0;strobe<=0;lane<=0;word_bytes<=0;done_tag<=0;done_written<=0;done_error<=0;
        end else if(cancel&&state!=IDLE&&state!=DONE&&state!=DRAIN_CACHE&&state!=DRAIN_BUS) begin
            done_error<=4'h4;
            if(state==CACHE_RSP&&!cache_rsp_valid) state<=DRAIN_CACHE;
            else if(state==WAIT_ACK&&!ack_valid) state<=DRAIN_BUS;
            else state<=DONE;
            // A simultaneously acknowledged write is durable even on cancellation.
            if(state==WAIT_ACK&&ack_valid&&!ack_error) done_written<=done_written+word_bytes;
        end else case(state)
            IDLE: if(cmd_valid&&cmd_ready) begin
                destination<=cmd_destination;cursor<=cmd_destination;row_stride<=cmd_row_stride;cache_base<=cmd_cache_base;
                row_bytes<=cmd_row_bytes;row_left<=cmd_row_bytes;rows<=cmd_rows;rows_left<=cmd_rows;
                fetched<=0;done_tag<=cmd_tag;done_written<=0;done_error<=0;state<=SIZE;
            end
            SIZE: begin byte_count<=row_bytes*rows;last_row_offset<=row_stride*(rows-16'd1);state<=EXTENT;end
            EXTENT: begin
                end_destination<={17'd0,destination}+{1'b0,last_row_offset}+{32'd0,row_bytes};
                end_cache<={2'd0,cache_base}+{1'b0,byte_count};state<=BOUNDS;
            end
            BOUNDS: begin invalid_extent<=row_bytes==0||rows==0||end_cache>CAPACITY||byte_count==0||row_stride<row_bytes||end_destination>49'h100000000;state<=CHECK;end
            CHECK: begin
                if(invalid_extent) begin done_error<=4'h1;state<=DONE;end
                else state<=START_WORD;
            end
            START_WORD: begin
                word<=0;strobe<=0;word_bytes<=0;word_addr<={cursor[31:5],5'd0};lane<=cursor[4:0];state<=CACHE_REQ;
            end
            CACHE_REQ: if(cache_ready) state<=CACHE_RSP;
            CACHE_RSP: if(cache_rsp_valid) begin
                if(cache_rsp_error||cache_rsp_tag!=done_tag) begin done_error<=4'h8;state<=DONE;end
                else begin
                    word[lane*8+:8]<=cache_rsp_data;strobe[lane]<=1'b1;word_bytes<=word_bytes+6'd1;
                    cursor<=cursor+32'd1;fetched<=fetched+32'd1;row_left<=row_left-17'd1;
                    if(row_left==1||lane==31) state<=WRITE;
                    else begin lane<=lane+5'd1;state<=CACHE_REQ;end
                end
            end
            WRITE: if(wr_ready) state<=WAIT_ACK;
            WAIT_ACK: if(ack_valid) begin
                if(ack_error) begin done_error<=4'h2;state<=DONE;end
                else begin
                    done_written<=done_written+word_bytes;
                    if(fetched==byte_count) state<=DONE;
                    else state<=(row_left==0)?NEXT_ROW:START_WORD;
                end
            end
            NEXT_ROW: begin
                destination<=destination+row_stride;cursor<=destination+row_stride;row_left<=row_bytes;rows_left<=rows_left-16'd1;state<=START_WORD;
            end
            DRAIN_CACHE: if(cache_rsp_valid) state<=DONE;
            DRAIN_BUS: if(ack_valid) begin if(!ack_error) done_written<=done_written+word_bytes;state<=DONE;end
            DONE: if(done_ready&&!cancel) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
