`timescale 1ns/1ps
`default_nettype none
// Frozen model input: 1920x1080 XRGB8888 -> 640x360 at (3*x+1,3*y+1),
// 140 rows of RGB114 padding at each end, U8 quantization, NCHW 640x640.
// Camera DDR byte order is B,G,R,X, as in qy_capture_memory current_pixel.
// The caller owns a completed, immutable camera frame until completion.
// Three 32-byte output lines and a two-line source cache only; no frame RAM.
// Output is unpublished until successful completion. On errors discard it.
module qy_camera_preprocess #(parameter INPUT_FILE="yolo_input.hex") (
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] cmd_frame_base,input wire [31:0] cmd_output_base,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,
    output reg [7:0] done_error,
    output wire preview_valid,output wire [9:0] preview_x,preview_y,output wire [15:0] preview_rgb565,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strb,
    input wire b_valid,output wire b_ready,input wire b_error
);
    localparam [4:0] IDLE=0,CHECK=1,PAD_LUT=2,PAD_GET=3,BLOCK=4,
        READ=5,WAIT_READ=6,LUT_R=7,GET_R=8,LUT_G=9,GET_G=10,LUT_B=11,GET_B=12,
        WRITE=13,WAIT_WRITE=14,NEXT_BLOCK=15,ABORT=16,DONE=17;
    reg [4:0] state;
    reg [31:0] frame_base,output_base,source_row,source_addr,destination;
    reg [9:0] row;
    reg [4:0] block_index,pixel;
    reg [1:0] channel;
    reg [23:0] rgb;
    reg [255:0] line_r,line_g,line_b;
    reg [7:0] quant_q,pad;
    reg [7:0] quant[0:255];initial $readmemh(INPUT_FILE,quant);
    reg [7:0] fault;
    reg write_pending;
    wire [32:0] frame_end={1'b0,frame_base}+33'd8294400;
    wire [32:0] output_end={1'b0,output_base}+33'd1228800;
    wire overlaps=({1'b0,frame_base}<output_end)&&({1'b0,output_base}<frame_end);
    wire cache_ready,cache_valid,cache_busy;
    wire [31:0] cache_tag,cache_data;
    wire [2:0] cache_error;
    qy_read_cache256 reader(
        .clk(clk),.rst(rst||state==IDLE),.cancel(cancel),
        .cmd_valid(!rst&&!cancel&&state==READ),.cmd_ready(cache_ready),
        .cmd_tag(done_tag),.cmd_addr(source_addr),.cmd_word(1'b1),
        .out_valid(cache_valid),.out_ready(state==WAIT_READ||state==ABORT),
        .out_tag(cache_tag),.out_data(cache_data),.out_error(cache_error),
        .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_addr(rd_addr),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),.busy(cache_busy));
    always @(posedge clk) begin
        if(state==PAD_LUT) quant_q<=quant[114];
        if(state==LUT_R) quant_q<=quant[rgb[23:16]];
        if(state==LUT_G) quant_q<=quant[rgb[15:8]];
        if(state==LUT_B) quant_q<=quant[rgb[7:0]];
    end
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign preview_valid=!rst&&!cancel&&state==GET_B;
    assign preview_x={block_index,pixel};assign preview_y=row-10'd140;
    assign preview_rgb565={rgb[23:19],rgb[15:10],rgb[7:3]};
    assign done_valid=!rst&&!cancel&&state==DONE;
    assign wr_valid=!rst&&!cancel&&state==WRITE;
    assign wr_addr=destination+(channel==0?32'd0:channel==1?32'd409600:32'd819200);
    assign wr_data=channel==0?line_r:channel==1?line_g:line_b;
    assign wr_strb=32'hffffffff;
    assign b_ready=!rst&&(state==WAIT_WRITE||state==ABORT);
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;frame_base<=0;output_base<=0;source_row<=0;source_addr<=0;destination<=0;
            row<=0;block_index<=0;pixel<=0;channel<=0;rgb<=0;line_r<=0;line_g<=0;line_b<=0;
            pad<=0;fault<=0;write_pending<=0;done_tag<=0;done_error<=0;
        end else begin
            if(wr_valid&&wr_ready) write_pending<=1;
            if(b_valid&&b_ready) write_pending<=0;
            if(cancel&&state!=IDLE) begin fault<=8'h80;state<=ABORT;end
            else case(state)
                IDLE:if(cmd_valid&&cmd_ready) begin
                    frame_base<=cmd_frame_base;output_base<=cmd_output_base;
                    source_row<=cmd_frame_base+32'd7684;source_addr<=cmd_frame_base+32'd7684;
                    destination<=cmd_output_base;row<=0;block_index<=0;pixel<=0;channel<=0;
                    done_tag<=cmd_tag;done_error<=0;fault<=0;state<=CHECK;
                end
                CHECK:if(frame_base[4:0]!=0||output_base[4:0]!=0||frame_end>33'h100000000||output_end>33'h100000000||overlaps) begin fault<=1;state<=ABORT;end
                    else state<=PAD_LUT;
                PAD_LUT:state<=PAD_GET;
                PAD_GET:begin pad<=quant_q;state<=BLOCK;end
                BLOCK:begin
                    pixel<=0;channel<=0;
                    if(row<140||row>=500) begin line_r<={32{pad}};line_g<={32{pad}};line_b<={32{pad}};state<=WRITE;end
                    else state<=READ;
                end
                READ:if(cache_ready) state<=WAIT_READ;
                WAIT_READ:if(cache_valid) begin
                    if(cache_error!=0||cache_tag!=done_tag) begin fault<=2;state<=ABORT;end
                    else begin rgb<=cache_data[23:0];state<=LUT_R;end
                end
                LUT_R:state<=GET_R;
                GET_R:begin line_r[pixel*8+:8]<=quant_q;state<=LUT_G;end
                LUT_G:state<=GET_G;
                GET_G:begin line_g[pixel*8+:8]<=quant_q;state<=LUT_B;end
                LUT_B:state<=GET_B;
                GET_B:begin
                    line_b[pixel*8+:8]<=quant_q;source_addr<=source_addr+12;
                    if(pixel==31) state<=WRITE;
                    else begin pixel<=pixel+1'b1;state<=READ;end
                end
                WRITE:if(wr_ready) state<=WAIT_WRITE;
                WAIT_WRITE:if(b_valid) begin
                    if(b_error) begin fault<=4;state<=ABORT;end
                    else if(channel==2) state<=NEXT_BLOCK;
                    else begin channel<=channel+1'b1;state<=WRITE;end
                end
                NEXT_BLOCK:if(row==639&&block_index==19) begin done_error<=0;state<=DONE;end
                    else begin
                        destination<=destination+32;
                        if(block_index==19) begin
                            block_index<=0;row<=row+1'b1;
                            if(row>=140&&row<499) begin source_row<=source_row+23040;source_addr<=source_row+23040;end
                        end else block_index<=block_index+1'b1;
                        state<=BLOCK;
                    end
                ABORT:if(!cache_busy&&!write_pending) begin done_error<=fault;state<=DONE;end
                DONE:if(done_ready) state<=IDLE;
                default:begin fault<=8'h40;state<=ABORT;end
            endcase
        end
    end
endmodule
`default_nettype wire
