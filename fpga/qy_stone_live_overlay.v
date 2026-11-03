`timescale 1ns/1ps
`default_nettype none
// Frame-atomic, two-pixel cyan/amber boxes in the existing 640x360 color
// preview. The grayscale panel, board, recommendations and all other pixels
// pass through with exactly two clocks of latency.
module qy_stone_live_overlay #(
    parameter VIEW_X=1200,VIEW_Y=192,MAX_AGE_FRAMES=30
)(
    input wire clk,rst_n,camera_ready,
    input wire result_valid,input wire [1023:0] boxes,
    input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
    output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
    reg [1023:0] pending,front;
    reg pending_valid;
    reg [5:0] age;
    reg [11:0] x,y;
    reg de_d,vs_d,hs_d;
    reg [23:0] rgb_q;
    wire frame_edge=vs_i&&!vs_d;
    wire in_view=de_i&&x>=VIEW_X&&x<VIEW_X+640&&y>=VIEW_Y&&y<VIEW_Y+360;
    reg [31:0] black_hits,white_hits;
    genvar i;
    generate for(i=0;i<32;i=i+1)begin:paint
        wire [31:0] b=front[i*32+:32];
        wire [11:0] center_x=VIEW_X+{2'd0,b[8:0],1'b0};
        wire [11:0] center_y=VIEW_Y+{3'd0,b[16:9],1'b0};
        wire [11:0] radius={7'd0,b[20:17],1'b0}+12'd2;
        wire [11:0] left_x=center_x-radius,right_x=center_x+radius;
        wire [11:0] top_y=center_y-radius,bottom_y=center_y+radius;
        wire edge_pixel=in_view&&b[23]&&camera_ready&&age<MAX_AGE_FRAMES&&
            x>=left_x&&x<=right_x&&y>=top_y&&y<=bottom_y&&
            (x<left_x+2||x>right_x-2||y<top_y+2||y>bottom_y-2);
        always @(posedge clk)begin
            if(!rst_n)begin black_hits[i]<=0;white_hits[i]<=0;end
            else begin black_hits[i]<=edge_pixel&&b[22:21]==1;white_hits[i]<=edge_pixel&&b[22:21]==2;end
        end
    end endgenerate
    always @(posedge clk)begin
        if(!rst_n)begin
            pending<=0;front<=0;pending_valid<=0;age<=MAX_AGE_FRAMES;
            x<=0;y<=0;de_d<=0;vs_d<=0;hs_d<=0;rgb_q<=0;
            rgb_o<=0;de_o<=0;hs_o<=0;vs_o<=0;
        end else begin
            de_d<=de_i;hs_d<=hs_i;vs_d<=vs_i;rgb_q<=rgb_i;
            de_o<=de_d;hs_o<=hs_d;vs_o<=vs_d;
            rgb_o<=!de_d?24'd0:|white_hits?24'h43e9ff:|black_hits?24'hffcf40:rgb_q;
            if(result_valid)begin pending<=boxes;pending_valid<=1;end
            if(frame_edge)begin
                x<=0;y<=0;
                if(result_valid)begin front<=boxes;pending_valid<=0;age<=0;end
                else if(pending_valid)begin front<=pending;pending_valid<=0;age<=0;end
                else if(age<MAX_AGE_FRAMES)age<=age+1'b1;
            end else if(de_i)begin if(x<4095)x<=x+1'b1;end
            else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
            if(!camera_ready)begin front<=0;pending<=0;pending_valid<=0;age<=MAX_AGE_FRAMES;end
        end
    end
endmodule
`default_nettype wire
