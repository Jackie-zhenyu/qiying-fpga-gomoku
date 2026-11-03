`timescale 1ns/1ps
`default_nettype none
// One outstanding aligned 32-byte read; little-endian bytes are packed into
// the bounded input/weight cache. The owner must exclude compute during load.
// Local reset requires the paired bus adapter to flush/epoch pending responses.
// Cancel instead drains an accepted bus request before completion/new work.
module qy_tile_read_strided #(parameter integer CAPACITY=65536)(
    input wire clk,rst,cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] cmd_source,cmd_row_stride,cmd_cache_base,
    // Zero cache stride means tightly packed rows (legacy semantics).
    // A nonzero stride must be >=row_bytes; gaps remain untouched.
    input wire [16:0] cmd_cache_stride,
    input wire [16:0] cmd_row_bytes,input wire [15:0] cmd_rows,
    input wire cmd_fill,input wire [7:0] cmd_fill_byte,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire load_valid,input wire load_ready,output wire [31:0] load_addr,
    output wire [7:0] load_data,input wire load_error,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,done_written,
    output reg [3:0] done_error
);
    localparam [3:0] IDLE=0,SIZE=1,CHECK=2,REQUEST=3,WAIT_READ=4,
        EMIT=5,NEXT_ROW=6,FINAL_ACK=7,DONE=8,DRAIN=9,EXTENT=10,BOUNDS=11;
    reg [3:0] state;
    reg [31:0] source,row_stride,cache_base,cursor;
    reg [16:0] cache_stride,row_bytes,row_left;
    reg [31:0] cache_cursor,cache_row_base;reg [32:0] cache_last_offset;reg [15:0] rows_left,rows;
    reg fill;reg [7:0] fill_byte;reg [4:0] lane;
    reg [255:0] word;
    reg [32:0] byte_count;
    reg [47:0] last_row_offset; // exact maximum: u32 stride * u16 row index
    reg [48:0] end_source;reg [33:0] end_cache;reg invalid_extent;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign rd_valid=!rst&&!cancel&&!load_error&&state==REQUEST;
    assign rd_addr={cursor[31:5],5'd0};
    assign rsp_ready=!rst&&(state==WAIT_READ||state==DRAIN);
    assign load_valid=!rst&&!cancel&&!load_error&&state==EMIT;
    assign load_addr=cache_cursor;
    assign load_data=fill?fill_byte:word[lane*8+:8];
    assign done_valid=!rst&&!cancel&&state==DONE;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;cache_stride<=0;cache_cursor<=0;cache_row_base<=0;cache_last_offset<=0;end_source<=0;end_cache<=0;invalid_extent<=0;source<=0;row_stride<=0;cache_base<=0;cursor<=0;
            row_bytes<=0;row_left<=0;rows_left<=0;rows<=0;fill<=0;fill_byte<=0;lane<=0;word<=0;
            byte_count<=0;last_row_offset<=0;done_tag<=0;done_written<=0;done_error<=0;
        end else if(cancel&&state!=IDLE&&state!=DONE&&state!=DRAIN) begin
            done_error<=4'h4;
            state<=(state==WAIT_READ&&!rsp_valid)?DRAIN:DONE;
        end else if(load_error&&state!=IDLE&&state!=DONE&&state!=DRAIN) begin
            done_error<=4'h8;
            state<=(state==WAIT_READ&&!rsp_valid)?DRAIN:DONE;
        end else case(state)
            IDLE: if(cmd_valid&&cmd_ready) begin
                source<=cmd_source;cursor<=cmd_source;row_stride<=cmd_row_stride;cache_base<=cmd_cache_base;
                cache_stride<=cmd_cache_stride==0?cmd_row_bytes:cmd_cache_stride;
                cache_cursor<=cmd_cache_base;cache_row_base<=cmd_cache_base;
                row_bytes<=cmd_row_bytes;row_left<=cmd_row_bytes;rows<=cmd_rows;rows_left<=cmd_rows;
                fill<=cmd_fill;fill_byte<=cmd_fill_byte;done_tag<=cmd_tag;done_written<=0;done_error<=0;state<=SIZE;
            end
            SIZE: begin byte_count<=row_bytes*rows;last_row_offset<=row_stride*(rows-16'd1);cache_last_offset<=cache_stride*(rows-16'd1);state<=EXTENT;end
            EXTENT: begin
                end_source<={17'd0,source}+{1'b0,last_row_offset}+{32'd0,row_bytes};
                end_cache<={2'd0,cache_base}+{1'b0,cache_last_offset}+{17'd0,row_bytes};state<=BOUNDS;
            end
            BOUNDS: begin invalid_extent<=row_bytes==0||rows==0||cache_stride<row_bytes||end_cache>CAPACITY||byte_count==0||(!fill&&(row_stride<row_bytes||end_source>49'h100000000));state<=CHECK;end
            CHECK: begin
                if(invalid_extent) begin done_error<=4'h1;state<=DONE;end
                else state<=fill?EMIT:REQUEST;
            end
            REQUEST: if(rd_ready) state<=WAIT_READ;
            WAIT_READ: if(rsp_valid) begin
                if(rsp_error) begin done_error<=4'h2;state<=DONE;end
                else begin word<=rsp_data;lane<=cursor[4:0];state<=EMIT;end
            end
            EMIT: if(load_ready) begin
                done_written<=done_written+32'd1;cursor<=cursor+32'd1;cache_cursor<=cache_cursor+32'd1;row_left<=row_left-17'd1;
                if(row_left==1) state<=(rows_left==1)?FINAL_ACK:NEXT_ROW;
                else if(!fill) begin lane<=lane+5'd1;if(lane==31) state<=REQUEST;end
            end
            NEXT_ROW: begin
                cache_row_base<=cache_row_base+cache_stride;cache_cursor<=cache_row_base+cache_stride;
                source<=source+row_stride;cursor<=source+row_stride;row_left<=row_bytes;rows_left<=rows_left-16'd1;
                state<=fill?EMIT:REQUEST;
            end
            // Cache reports a write error on the cycle after its write handshake.
            FINAL_ACK: state<=DONE;
            DRAIN: if(rsp_valid) state<=DONE;
            DONE: if(done_ready&&!cancel) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
