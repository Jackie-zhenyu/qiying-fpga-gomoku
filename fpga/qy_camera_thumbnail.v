`timescale 1ns/1ps
`default_nettype none
// Display-only 1/3 nearest-neighbor full-frame thumbnail. The DDR/vision
// source remains RGB888. Two RGB565 BRAM banks publish only complete frames.
module qy_camera_thumbnail #(
    parameter WIDTH=1920, HEIGHT=1080, VIEW_X=1200, VIEW_Y=192
)(
    input wire clk_i,rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,camera_ready_i,
    output wire [23:0] rgb_o,
    output reg de_o,hs_o,vs_o,
    output reg frame_valid_o
);
    localparam TW=WIDTH/3, TH=HEIGHT/3, PIXELS=TW*TH;
    // Vendor synthesis inference template: synchronous read and no RAM reset.
    (* ram_style = "bram" *) reg [15:0] bank0[0:PIXELS-1];
    (* ram_style = "bram" *) reg [15:0] bank1[0:PIXELS-1];
    reg [15:0] rd0,rd1;
    reg front_bank,read_bank,read_visible,frame_valid;
    // TD otherwise absorbs this stage into the RAM and exposes its synchronous
    // reset as an asynchronous combinational address mux. Native keep retains
    // all 18 physical address FFs (verified by the standalone gate-netlist test).
    (* keep = "true" *) reg [17:0] read_addr_q;
    reg [17:0] write_addr_q;
    reg [15:0] write_rgb_q;
    reg write_en_q,write_bank_q,read_bank_q,read_visible_q,hs_d;
    reg [11:0] x,y;
    reg [1:0] x_mod3,y_mod3;
    reg de_d,vs_d,armed,bad;
    reg [17:0] samples;
    wire frame_edge=vs_i&&!vs_d;
    wire inside_view=de_i&&x>=VIEW_X&&x<VIEW_X+TW&&y>=VIEW_Y&&y<VIEW_Y+TH;
    wire [17:0] read_addr=inside_view ? (y-VIEW_Y)*TW+(x-VIEW_X) : 18'd0;
    wire sample_now=armed&&!frame_edge&&de_i&&camera_ready_i&&
                    x<WIDTH&&y<HEIGHT&&x_mod3==1&&y_mod3==1&&samples<PIXELS;
    wire [15:0] packed_rgb={rgb_i[23:19],rgb_i[15:10],rgb_i[7:3]};
    wire [15:0] selected=read_bank ? rd1 : rd0;
    assign rgb_o=read_visible ? {selected[15:11],selected[15:13],
                                 selected[10:5],selected[10:9],
                                 selected[4:0],selected[4:2]} : 24'd0;

    always @(posedge clk_i) begin
        // Every physical RAM control is driven only by synchronous registers.
        // In particular camera_ready_i may come from an async-reset monitor.
        if(write_en_q&&write_bank_q) bank1[write_addr_q]<=write_rgb_q;
        if(write_en_q&&!write_bank_q) bank0[write_addr_q]<=write_rgb_q;
        rd0<=bank0[read_addr_q];
        rd1<=bank1[read_addr_q];
    end

    // PH1A ERAM addresses and write controls must stay synchronous, including
    // reset transitions. Visibility is cleared on the next pixel-clock edge.
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            front_bank<=0;read_bank<=0;read_visible<=0;frame_valid<=0;frame_valid_o<=0;
            read_addr_q<=0;write_addr_q<=0;write_rgb_q<=0;
            write_en_q<=0;write_bank_q<=0;read_bank_q<=0;read_visible_q<=0;hs_d<=0;
            x<=0;y<=0;x_mod3<=0;y_mod3<=0;de_d<=0;vs_d<=0;
            armed<=0;bad<=0;samples<=0;de_o<=0;hs_o<=0;vs_o<=0;
        end else begin
            de_o<=de_d;hs_o<=hs_d;vs_o<=vs_d;frame_valid_o<=frame_valid;
            read_addr_q<=read_addr;
            read_bank_q<=front_bank;read_visible_q<=inside_view&&frame_valid;
            read_bank<=read_bank_q;read_visible<=read_visible_q;
            write_en_q<=sample_now;write_addr_q<=samples;
            write_rgb_q<=packed_rgb;write_bank_q<=!front_bank;
            de_d<=de_i;hs_d<=hs_i;vs_d<=vs_i;
            if(frame_edge) begin
                // Do not swap on short/long frames, readiness gaps, partial
                // startup capture, or a VS edge illegally inside active video.
                if(armed&&!bad&&camera_ready_i&&!de_i&&y==HEIGHT&&samples==PIXELS) begin
                    front_bank<=!front_bank;
                    frame_valid<=1;
                end else frame_valid<=0;
                x<=0;y<=0;x_mod3<=0;y_mod3<=0;
                samples<=0;bad<=0;armed<=1;
            end else begin
                if(armed&&!camera_ready_i)bad<=1;
                if(de_i) begin
                    if(x<4095)x<=x+1'b1;
                    if(x>=WIDTH||y>=HEIGHT)bad<=1;
                    x_mod3<=x_mod3==2 ? 0 : x_mod3+1'b1;
                    if(sample_now)samples<=samples+1'b1;
                end else begin
                    x<=0;x_mod3<=0;
                    if(de_d) begin
                        if(x!=WIDTH)bad<=1;
                        if(y<4095)y<=y+1'b1;
                        y_mod3<=y_mod3==2 ? 0 : y_mod3+1'b1;
                    end
                end
            end
        end
    end
    // synthesis translate_off
    initial begin
        if(WIDTH<3||HEIGHT<3||WIDTH>1920||HEIGHT>1080||WIDTH%3!=0||HEIGHT%3!=0||
           VIEW_X<0||VIEW_Y<0||VIEW_X+TW>WIDTH||VIEW_Y+TH>HEIGHT)
            $fatal(1,"CONFIG_ERROR thumbnail dimensions/viewport");
    end
    // synthesis translate_on
endmodule
`default_nettype wire
