`timescale 1ns/1ps
`default_nettype none
// Frozen YOLO SPPF: U8 5x5 max, stride1, pad2, NCHW. Channels are
// independent so complete channel planes can be tiled without halos.
// Reuses A and output caches; no additional feature RAM. Zero padding is
// the U8 minimum and cannot change a maximum over valid pixels.
module qy_maxpool_tile (
    input wire clk, input wire rst, input wire cancel, output wire memory_reset,
    input wire cmd_valid, output wire cmd_ready, input wire [31:0] cmd_tag,
    input wire [31:0] cmd_a_base, input wire [9:0] cmd_width, input wire [9:0] cmd_height, input wire [8:0] cmd_channels,
    output wire req_valid, input wire req_ready, output wire [31:0] req_a, output wire [31:0] req_b,
    input wire rsp_valid, output wire rsp_ready, input wire [7:0] rsp_a, input wire [7:0] rsp_b, input wire rsp_error,
    output wire wr_valid, input wire wr_ready, output wire [31:0] wr_addr, output wire [7:0] wr_data,
    input wire ack_valid, output wire ack_ready, input wire ack_error,
    output wire done_valid, input wire done_ready, output reg [31:0] done_tag,
    output reg [31:0] done_written, output reg [7:0] done_error
);
    localparam [3:0] IDLE=0,PLANE=1,SIZE=2,CHECK=3,START=4,TAP=5,REPLY=6,ADVANCE=7,WRITE=8,ACK=9,DONE=10;
    reg [3:0] state;
    reg [31:0] a_base;
    reg [9:0] width,height,x,y;
    reg [8:0] channels;
    reg [19:0] plane;
    reg [28:0] total;
    reg [16:0] index;
    reg [2:0] kx,ky;
    reg signed [11:0] ix,iy;
    reg signed [32:0] pointer,row_start;
    reg [7:0] maximum;
    wire [32:0] end_address={1'b0,a_base}+{4'd0,total};
    wire signed [32:0] window_start=$signed({1'b0,a_base})+$signed({16'd0,index})-$signed({22'd0,width,1'b0})-33'sd2;
    wire valid_tap=ix>=0&&iy>=0&&ix<$signed({2'b00,width})&&iy<$signed({2'b00,height});
    assign memory_reset=rst||cancel;
    assign cmd_ready=!memory_reset&&state==IDLE;
    assign req_valid=!memory_reset&&state==TAP&&valid_tap;
    assign req_a=pointer[31:0];assign req_b=0;
    assign rsp_ready=!memory_reset&&state==REPLY;
    assign wr_valid=!memory_reset&&state==WRITE;assign wr_addr={15'd0,index};assign wr_data=maximum;
    assign ack_ready=!memory_reset&&state==ACK;
    assign done_valid=!memory_reset&&state==DONE;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;a_base<=0;width<=0;height<=0;channels<=0;plane<=0;total<=0;index<=0;x<=0;y<=0;
            kx<=0;ky<=0;ix<=0;iy<=0;pointer<=0;row_start<=0;maximum<=0;done_tag<=0;done_written<=0;done_error<=0;
        end else if(cancel) begin
            if(state!=IDLE) begin state<=DONE;done_error<=8'h10;end
        end else case(state)
            IDLE:if(cmd_valid) begin
                a_base<=cmd_a_base;width<=cmd_width;height<=cmd_height;channels<=cmd_channels;
                done_tag<=cmd_tag;done_written<=0;done_error<=0;index<=0;x<=0;y<=0;state<=PLANE;
            end
            PLANE:begin plane<=width*height;state<=SIZE;end
            SIZE:begin total<=plane*channels;state<=CHECK;end
            CHECK:if(width==0||height==0||channels==0||width>640||height>640||channels>256||total>65536||end_address>65536) begin done_error<=1;state<=DONE;end
                else state<=START;
            START:begin
                maximum<=0;kx<=0;ky<=0;ix<=$signed({2'b00,x})-12'sd2;iy<=$signed({2'b00,y})-12'sd2;
                pointer<=window_start;row_start<=window_start;state<=TAP;
            end
            TAP:if(!valid_tap) state<=ADVANCE;else if(req_ready) state<=REPLY;
            REPLY:if(rsp_valid) begin
                if(rsp_error) begin done_error<=2;state<=DONE;end
                else begin if(rsp_a>maximum) maximum<=rsp_a;state<=ADVANCE;end
            end
            ADVANCE:if(kx==4) begin
                if(ky==4) state<=WRITE;
                else begin
                    kx<=0;ky<=ky+1'b1;ix<=$signed({2'b00,x})-12'sd2;iy<=iy+1'b1;
                    row_start<=row_start+$signed({23'd0,width});pointer<=row_start+$signed({23'd0,width});state<=TAP;
                end
            end else begin kx<=kx+1'b1;ix<=ix+1'b1;pointer<=pointer+1'b1;state<=TAP;end
            WRITE:if(wr_ready) state<=ACK;
            ACK:if(ack_valid) begin
                if(ack_error) begin done_error<=8;state<=DONE;end
                else begin
                    done_written<=done_written+1'b1;
                    if({12'd0,index}==total-1'b1) state<=DONE;
                    else begin
                        index<=index+1'b1;
                        if(x==width-1'b1) begin x<=0;if(y==height-1'b1) y<=0;else y<=y+1'b1;end
                        else x<=x+1'b1;
                        state<=START;
                    end
                end
            end
            DONE:if(done_ready) state<=IDLE;
            default:begin done_error<=8'h80;state<=DONE;end
        endcase
    end
endmodule
`default_nettype wire
