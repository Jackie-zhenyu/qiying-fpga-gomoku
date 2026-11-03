`timescale 1ns/1ps
`default_nettype none
// Lower UI window: a completed real inference frame and its own detections.
// Until first success, preserve the existing real line-extraction view.
// The upper live preview and13x13 board pass through with2cycles latency.
module qy_nn_detection_panel #(parameter HEADER_FILE="yolo_panel_header.hex",parameter LINE_DEBUG=0)(
    input wire clk_i,rst_n_i,input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
    input wire [15:0] image_rgb565,input wire [1:0] image_mask,input wire image_valid,
    output wire [15:0] read_address,output wire video_blank,
    output wire [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
    reg [11:0] x,y;reg de_d,vs_d;reg [7:0] column,row;reg [2:0] xm,ym;
    wire view=de_i&&x>=1200&&x<1840&&y>=592&&y<952;
    wire heading=de_i&&x>=1200&&x<1840&&y>=560&&y<592;
    assign video_blank=vs_i&&!vs_d;
    assign read_address=view?{row,column}:16'd0;
    reg [31:0] header[0:1279];initial $readmemh(HEADER_FILE,header);
    (* keep="true" *) reg [10:0] header_address;
    reg [31:0] word;reg [4:0] bit_q,bit_d;
    reg [23:0] rgb_q,rgb_d;reg view_q,view_d,heading_q,heading_d,hs_q,vs_q;
    wire [23:0] photo={image_rgb565[15:11],image_rgb565[15:13],image_rgb565[10:5],image_rgb565[10:9],image_rgb565[4:0],image_rgb565[4:2]};
    wire [23:0] marked=image_mask==1?24'hffcf40:image_mask==2?24'h43e9ff:image_mask==3?24'hff64d8:photo;
    assign rgb_o=!de_o?24'd0:LINE_DEBUG?rgb_d:
        heading_d?(word[bit_d]?24'h68d5ba:24'h0c1822):
        view_d&&image_valid?marked:rgb_d;
    always @(posedge clk_i) word<=header[header_address];
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            x<=0;y<=0;de_d<=0;vs_d<=0;column<=0;row<=0;xm<=0;ym<=0;
            header_address<=0;bit_q<=0;bit_d<=0;rgb_q<=0;rgb_d<=0;view_q<=0;view_d<=0;heading_q<=0;heading_d<=0;
            hs_q<=0;vs_q<=0;de_o<=0;hs_o<=0;vs_o<=0;
        end else begin
            de_d<=de_i;vs_d<=vs_i;rgb_q<=rgb_i;rgb_d<=rgb_q;
            view_q<=view;view_d<=view_q;heading_q<=heading;heading_d<=heading_q;
            hs_q<=hs_i;vs_q<=vs_i;de_o<=de_d;hs_o<=hs_q;vs_o<=vs_q;
            header_address<=heading?((image_valid?11'd0:11'd640)+(y-12'd560)*20+((x-12'd1200)>>5)):11'd0;
            bit_q<=31-((x-12'd1200)&31);bit_d<=bit_q;
            if(video_blank)begin x<=0;y<=0;column<=0;row<=0;xm<=0;ym<=0;end
            else if(de_i)begin
                if(x<4095)x<=x+1'b1;
                if(view)begin if(xm==2||xm==4)column<=column+1'b1;xm<=xm==4?0:xm+1'b1;end
            end else begin
                x<=0;column<=0;xm<=0;
                if(de_d)begin
                    if(y<4095)y<=y+1'b1;
                    if(y>=592&&y<952)begin if(ym==2||ym==4)row<=row+1'b1;ym<=ym==4?0:ym+1'b1;end
                end
            end
        end
    end
endmodule
`default_nettype wire
