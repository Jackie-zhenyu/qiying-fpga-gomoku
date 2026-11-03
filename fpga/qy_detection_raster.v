`timescale 1ns/1ps
`default_nettype none
// Rasterize an actual decoded YOLO box onto a 256x144 frozen-image mask.
// Model640 coordinates include the top/bottom140 letterbox. Coordinates are
// clamped, near edges floor and far edges ceil to whole model pixels, then
// scaled by2/5. This deliberately expands a box by at most one preview pixel.
// This block draws no simulated stones and never writes a game board.
module qy_detection_raster(
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [191:0] cmd_box,
    output wire pixel_valid,input wire pixel_ready,output wire [15:0] pixel_address,
    output wire [1:0] pixel_class,output wire [31:0] pixel_tag,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,
    output reg [2:0] done_error,output reg drawn
);
    localparam [3:0] IDLE=0,CHECK=1,TOP=2,BOTTOM=3,LEFT=4,RIGHT=5,DONE=6,CONVERT=7,SCALE=8,SETUP=9;
    reg [3:0] state;
    reg [191:0] box;
    reg [8:0] x0,x1,x;
    reg [7:0] y0,y1,y;
    reg [1:0] color;
    wire [31:0] fx0=box[31:0],fy0=box[63:32],fx1=box[95:64],fy1=box[127:96],score=box[159:128];
    wire finite=fx0[30:23]!=255&&fy0[30:23]!=255&&fx1[30:23]!=255&&fy1[30:23]!=255&&score[30:23]!=255;
    function less_float(input [31:0] a,input [31:0] b);
        begin
            if(a[30:0]==0&&b[30:0]==0) less_float=0;
            else if(a[31]!=b[31]) less_float=a[31];
            else less_float=a[31]?(a[30:0]>b[30:0]):(a[30:0]<b[30:0]);
        end
    endfunction
    function [10:0] floor640(input [31:0] f);
        reg [23:0] mant;reg [7:0] exponent;
        begin
            mant={1'b1,f[22:0]};exponent=f[30:23];
            if(f[31]||exponent<127) floor640=0;
            else if(exponent>=137||f>=32'h44200000) floor640=640;
            else floor640=mant>>(150-exponent);
        end
    endfunction
    function [10:0] ceil640(input [31:0] f);
        reg [23:0] mant,mask;reg [7:0] exponent;reg [10:0] low;
        begin
            exponent=f[30:23];mant={1'b1,f[22:0]};low=floor640(f);
            if(f[31]||f[30:0]==0) ceil640=0;
            else if(exponent<127) ceil640=1;
            else if(f>=32'h44200000) ceil640=640;
            else begin mask=(24'd1<<(150-exponent))-1;ceil640=low+((mant&mask)!=0);end
        end
    endfunction
    reg [10:0] left_model,right_model,top_model,bottom_model;
    wire [10:0] top_clip=top_model<140?0:top_model>=500?360:top_model-140;
    wire [10:0] bottom_clip=bottom_model<140?0:bottom_model>=500?360:bottom_model-140;
    reg [11:0] scaled_left,scaled_right,scaled_top,scaled_bottom;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign pixel_valid=!rst&&!cancel&&(state==TOP||state==BOTTOM||state==LEFT||state==RIGHT);
    assign pixel_address={y,8'd0}+x;
    assign pixel_class=color;assign pixel_tag=done_tag;
    assign done_valid=!rst&&state==DONE;
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;box<=0;x0<=0;x1<=0;x<=0;y0<=0;y1<=0;y<=0;color<=0;done_tag<=0;done_error<=0;drawn<=0;
            left_model<=0;right_model<=0;top_model<=0;bottom_model<=0;scaled_left<=0;scaled_right<=0;scaled_top<=0;scaled_bottom<=0;end
        else if(cancel&&state!=IDLE&&state!=DONE) begin state<=DONE;done_error<=4;drawn<=0;end
        else case(state)
            IDLE:if(cmd_valid&&cmd_ready) begin box<=cmd_box;done_tag<=cmd_tag;done_error<=0;drawn<=0;state<=CHECK;end
            CHECK:begin
                if(!finite||(box[191:160]!=0&&box[191:160]!=32'h3f800000)||score[31]||score>32'h3f800000) begin done_error<=1;state<=DONE;end
                else if(!less_float(fx0,fx1)||!less_float(fy0,fy1)) begin done_error<=2;state<=DONE;end
                else if(score<32'h3e800000) state<=DONE;
                else state<=CONVERT;
            end
            CONVERT:begin
                left_model<=floor640(fx0);right_model<=ceil640(fx1);top_model<=floor640(fy0);bottom_model<=ceil640(fy1);state<=SCALE;
            end
            SCALE:begin
                scaled_left<=({left_model,1'b0})/12'd5;
                scaled_right<=({right_model,1'b0}+12'd4)/12'd5;
                scaled_top<=({top_clip,1'b0})/12'd5;
                scaled_bottom<=({bottom_clip,1'b0}+12'd4)/12'd5;state<=SETUP;
            end
            SETUP:begin
                if(scaled_right<=scaled_left||scaled_bottom<=scaled_top||scaled_left>=256||scaled_top>=144) state<=DONE;
                else begin
                    x0<=scaled_left[8:0];x1<=scaled_right[8:0]-1'b1;x<=scaled_left[8:0];
                    y0<=scaled_top[7:0];y1<=scaled_bottom[7:0]-1'b1;y<=scaled_top[7:0];
                    color<=box[191:160]==32'h3f800000 ? 2'd2 : 2'd1;state<=TOP;drawn<=1;
                end
            end
            TOP:if(pixel_valid&&pixel_ready) begin
                if(x<x1) x<=x+1'b1;
                else if(y0==y1) state<=DONE;
                else begin x<=x0;y<=y1;state<=BOTTOM;end
            end
            BOTTOM:if(pixel_valid&&pixel_ready) begin
                if(x<x1) x<=x+1'b1;
                else if(y1<=y0+1) state<=DONE;
                else begin x<=x0;y<=y0+1'b1;state<=LEFT;end
            end
            LEFT:if(pixel_valid&&pixel_ready) begin
                if(y<y1-1'b1) y<=y+1'b1;
                else if(x0==x1) state<=DONE;
                else begin x<=x1;y<=y0+1'b1;state<=RIGHT;end
            end
            RIGHT:if(pixel_valid&&pixel_ready) begin if(y<y1-1'b1)y<=y+1'b1;else state<=DONE;end
            DONE:if(done_ready) state<=IDLE;
            default:begin done_error<=2;state<=DONE;end
        endcase
    end
endmodule
`default_nettype wire
