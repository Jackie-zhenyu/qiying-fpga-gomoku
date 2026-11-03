`timescale 1ns/1ps
`default_nettype none
// Replaces the old right-hand text card with a real binary camera image.
// The original color camera and 13x13 board/recommendation rings pass through.
module qy_vision_panel #(
    parameter HEADER_FILE="assets/vision13/panel_header.hex"
)(
    input wire clk_i,rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,image_valid_i,ink_i,
    output wire [17:0] read_addr_o,
    output wire [23:0] rgb_o,
    output reg de_o,hs_o,vs_o
);
    reg [11:0] x,y;
    reg de_d,vs_d;
    reg [17:0] row_base;
    wire frame_edge=vs_i&&!vs_d;
    wire panel=de_i&&x>=1184&&x<1856&&y>=560&&y<952;
    wire view=de_i&&x>=1200&&x<1840&&y>=592&&y<952;
    wire interior=view&&x>1200&&x<1839&&y>592&&y<951;
    wire heading=de_i&&x>=1200&&x<1840&&y>=560&&y<592;
    assign read_addr_o=interior ? row_base+(x-12'd1200) : 18'd0;
    // Two 640x32 one-bit headings packed as 20 words per raster line.
    reg [31:0] header[0:1279];
    initial $readmemh(HEADER_FILE,header);
    (* keep="true" *) reg [10:0] header_addr_q;
    reg [31:0] header_word;
    reg [4:0] header_bit_q,header_bit_d;
    reg [23:0] rgb_q,rgb_d;
    reg panel_q,panel_d,view_q,view_d,inside_q,inside_d;
    reg heading_q,heading_d,valid_q,valid_d,hs_q,vs_q;
    wire glyph=heading_d&&header_word[header_bit_d];
    assign rgb_o=!de_o?24'd0:
        glyph?(valid_d?24'h68d5ba:24'hf4b65d):
        view_d?(valid_d?((inside_d&&ink_i)?24'h101820:24'hf8faf8):24'h172a36):
        panel_d?24'h0c1822:rgb_d;
    always @(posedge clk_i)header_word<=header[header_addr_q];
    always @(posedge clk_i)begin
        if(!rst_n_i)begin
            x<=0;y<=0;row_base<=0;de_d<=0;vs_d<=0;
            header_addr_q<=0;header_bit_q<=0;header_bit_d<=0;
            rgb_q<=0;rgb_d<=0;panel_q<=0;panel_d<=0;view_q<=0;view_d<=0;
            inside_q<=0;inside_d<=0;heading_q<=0;heading_d<=0;valid_q<=0;valid_d<=0;
            hs_q<=0;vs_q<=0;de_o<=0;hs_o<=0;vs_o<=0;
        end else begin
            de_d<=de_i;vs_d<=vs_i;
            rgb_q<=rgb_i;rgb_d<=rgb_q;
            panel_q<=panel;panel_d<=panel_q;view_q<=view;view_d<=view_q;
            inside_q<=interior;inside_d<=inside_q;
            heading_q<=heading;heading_d<=heading_q;
            valid_q<=image_valid_i;valid_d<=valid_q;
            hs_q<=hs_i;vs_q<=vs_i;de_o<=de_d;hs_o<=hs_q;vs_o<=vs_q;
            header_addr_q<=heading?((image_valid_i?11'd0:11'd640)+(y-12'd560)*20+((x-12'd1200)>>5)):11'd0;
            header_bit_q<=31-((x-12'd1200)&31);header_bit_d<=header_bit_q;
            if(frame_edge)begin x<=0;y<=0;row_base<=0;end
            else if(de_i)begin if(x<4095)x<=x+1'b1;end
            else begin
                x<=0;
                if(de_d)begin
                    if(y<4095)y<=y+1'b1;
                    if(y>=592&&y<952)row_base<=row_base+18'd640;
                end
            end
        end
    end
endmodule
`default_nettype wire
