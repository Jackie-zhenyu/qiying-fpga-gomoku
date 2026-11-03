`timescale 1ns/1ps
`default_nettype none
// Lossless storage scheduling for the existing1/3 RGB565 live thumbnail.
// Source row r is sampled at input line3*r+1. Display row r is read at
// VIEW_Y+r. For r >= ceil(VIEW_Y/2), the complete display read precedes
// every write of that row in this frame. Those later rows need only one
// bank; earlier rows retain the original two-bank publication protocol.
// Default: two96-row prefixes + one264-row suffix vs two360-row frames.
// Exact colors, resolution, frame latency and validity protocol are retained.
module qy_camera_thumbnail_compact #(
    parameter WIDTH=1920,HEIGHT=1080,VIEW_X=1200,VIEW_Y=192
)(
    input wire clk_i,rst_n_i,input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,camera_ready_i,
    output wire [23:0] rgb_o,output reg de_o,hs_o,vs_o,frame_valid_o
);
    localparam TW=WIDTH/3,TH=HEIGHT/3,PIXELS=TW*TH;
    localparam PREFIX_ROWS=((VIEW_Y+1)/2<TH)?(VIEW_Y+1)/2:TH;
    localparam PREFIX=PREFIX_ROWS*TW,SUFFIX=PIXELS-PREFIX;
    (* ram_style="bram" *) reg [15:0] early0[0:(PREFIX>0?PREFIX:1)-1];
    (* ram_style="bram" *) reg [15:0] early1[0:(PREFIX>0?PREFIX:1)-1];
    (* ram_style="bram" *) reg [15:0] late[0:(SUFFIX>0?SUFFIX:1)-1];
    reg [15:0] rd0,rd1,rd_late;
    // Exact address widths are required by TD's synchronous ERAM matcher.
    // A wider prefix address creates an out-of-range output mux and prevents
    // block-RAM inference, even with the keep attribute.
    (* keep="true" *) reg [(PREFIX>1?$clog2(PREFIX):1)-1:0] read_early_q;
    (* keep="true" *) reg [(SUFFIX>1?$clog2(SUFFIX):1)-1:0] read_late_q;
    (* keep="true" *) reg [(PREFIX>1?$clog2(PREFIX):1)-1:0] write_early_q;
    (* keep="true" *) reg [(SUFFIX>1?$clog2(SUFFIX):1)-1:0] write_late_q;
    reg write0_q,write1_q,write_late_en_q;reg [15:0] write_rgb_q;
    reg front_bank,read_bank,read_bank_q,read_is_late,read_late_d;
    reg read_visible,read_visible_q,frame_valid,hs_d;
    reg [11:0] x,y;reg [1:0] x_mod3,y_mod3;
    reg de_d,vs_d,armed,bad;reg [17:0] samples;
    wire frame_edge=vs_i&&!vs_d;
    wire inside_view=de_i&&x>=VIEW_X&&x<VIEW_X+TW&&y>=VIEW_Y&&y<VIEW_Y+TH;
    wire [17:0] read_addr=inside_view?(y-VIEW_Y)*TW+(x-VIEW_X):18'd0;
    // Stop on malformed lines immediately, so sequential write addresses
    // cannot drift from their physical source row in the shared suffix.
    wire sample_now=armed&&!bad&&!frame_edge&&de_i&&camera_ready_i&&x<WIDTH&&y<HEIGHT&&x_mod3==1&&y_mod3==1&&samples<PIXELS;
    wire [15:0] selected=read_late_d?rd_late:read_bank?rd1:rd0;
    assign rgb_o=read_visible?{selected[15:11],selected[15:13],selected[10:5],selected[10:9],selected[4:0],selected[4:2]}:24'd0;
    always @(posedge clk_i)begin
        if(write0_q)early0[write_early_q]<=write_rgb_q;
        if(write1_q)early1[write_early_q]<=write_rgb_q;
        if(write_late_en_q)late[write_late_q]<=write_rgb_q;
        rd0<=early0[read_early_q];rd1<=early1[read_early_q];rd_late<=late[read_late_q];
    end
    always @(posedge clk_i)begin
        if(!rst_n_i)begin
            front_bank<=0;read_bank<=0;read_bank_q<=0;read_is_late<=0;read_late_d<=0;
            read_visible<=0;read_visible_q<=0;frame_valid<=0;frame_valid_o<=0;hs_d<=0;
            read_early_q<=0;read_late_q<=0;write_early_q<=0;write_late_q<=0;
            write0_q<=0;write1_q<=0;write_late_en_q<=0;write_rgb_q<=0;
            x<=0;y<=0;x_mod3<=0;y_mod3<=0;de_d<=0;vs_d<=0;armed<=0;bad<=0;samples<=0;
            de_o<=0;hs_o<=0;vs_o<=0;
        end else begin
            de_o<=de_d;hs_o<=hs_d;vs_o<=vs_d;frame_valid_o<=frame_valid;
            read_early_q<=read_addr<PREFIX?read_addr:18'd0;
            read_late_q<=read_addr>=PREFIX?read_addr-PREFIX:18'd0;
            read_is_late<=read_addr>=PREFIX;read_late_d<=read_is_late;
            read_bank_q<=front_bank;read_bank<=read_bank_q;
            read_visible_q<=inside_view&&frame_valid;read_visible<=read_visible_q;
            write0_q<=sample_now&&samples<PREFIX&&front_bank;
            write1_q<=sample_now&&samples<PREFIX&&!front_bank;
            write_late_en_q<=sample_now&&samples>=PREFIX;
            write_early_q<=samples<PREFIX?samples:18'd0;
            write_late_q<=samples>=PREFIX?samples-PREFIX:18'd0;
            write_rgb_q<={rgb_i[23:19],rgb_i[15:10],rgb_i[7:3]};
            de_d<=de_i;hs_d<=hs_i;vs_d<=vs_i;
            if(frame_edge)begin
                if(armed&&!bad&&camera_ready_i&&!de_i&&y==HEIGHT&&samples==PIXELS)begin front_bank<=!front_bank;frame_valid<=1;end
                else frame_valid<=0;
                x<=0;y<=0;x_mod3<=0;y_mod3<=0;samples<=0;bad<=0;armed<=1;
            end else begin
                if(armed&&!camera_ready_i)bad<=1;
                if(de_i)begin
                    if(x<4095)x<=x+1'b1;
                    if(x>=WIDTH||y>=HEIGHT)bad<=1;
                    x_mod3<=x_mod3==2?0:x_mod3+1'b1;
                    if(sample_now)samples<=samples+1'b1;
                end else begin
                    x<=0;x_mod3<=0;
                    if(de_d)begin
                        if(x!=WIDTH)bad<=1;
                        if(y<4095)y<=y+1'b1;
                        y_mod3<=y_mod3==2?0:y_mod3+1'b1;
                    end
                end
            end
        end
    end
    // synthesis translate_off
    initial if(WIDTH<3||HEIGHT<3||WIDTH>1920||HEIGHT>1080||WIDTH%3||HEIGHT%3||VIEW_X<0||VIEW_Y<0||VIEW_X+TW>WIDTH||VIEW_Y+TH>HEIGHT)
        $fatal(1,"CONFIG_ERROR compact thumbnail geometry");
    // synthesis translate_on
endmodule
`default_nettype wire
