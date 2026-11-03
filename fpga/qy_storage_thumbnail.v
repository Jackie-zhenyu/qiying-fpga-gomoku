`timescale 1ns/1ps
`default_nettype none
// Lossless storage scheduling for the existing1/3 RGB565 live thumbnail.
// Source row r is sampled at input line3*r+1. Display row r is read at
// VIEW_Y+r. For r >= ceil(VIEW_Y/2), the complete display read precedes
// every write of that row in this frame. Those later rows need only one
// bank; earlier rows retain the original two-bank publication protocol.
// Default: two96-row prefixes + one264-row suffix vs two360-row frames.
// Exact colors, resolution, frame latency and validity protocol are retained.
module qy_storage_thumbnail #(
    parameter WIDTH=1920,HEIGHT=1080,VIEW_X=1200,VIEW_Y=192
)(
    input wire clk_i,rst_n_i,input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,camera_ready_i,
    output wire [23:0] rgb_o,output reg de_o,hs_o,vs_o,frame_valid_o,
    input wire freeze_request,output reg frozen,output reg [31:0] frozen_frame,
    input wire dump_start,output wire dump_valid,input wire dump_ready,output wire [7:0] dump_data,
    input wire load_begin,input wire load_valid,output wire load_ready,input wire [7:0] load_data,
    input wire load_commit,load_abort
);
    localparam TW=WIDTH/3,TH=HEIGHT/3,PIXELS=TW*TH;
    localparam PREFIX_ROWS=((VIEW_Y+1)/2<TH)?(VIEW_Y+1)/2:TH;
    localparam PREFIX=PREFIX_ROWS*TW,SUFFIX=PIXELS-PREFIX;
    wire [15:0] rd0,rd1,rd_late;
    // Exact address widths are required by TD's synchronous ERAM matcher.
    // A wider prefix address creates an out-of-range output mux and prevents
    // block-RAM inference, even with the keep attribute.
    (* keep="true" *) reg [(PREFIX>1?$clog2(PREFIX):1)-1:0] write_early_q;
    (* keep="true" *) reg [(SUFFIX>1?$clog2(SUFFIX):1)-1:0] write_late_q;
    reg write0_q,write1_q,write_late_en_q;reg [15:0] write_rgb_q;
    reg front_bank,read_bank,read_bank_q,read_is_late,read_late_d;
    reg read_visible,read_visible_q,frame_valid,hs_d;
    reg [11:0] x,y;reg [1:0] x_mod3,y_mod3;
    reg de_d,vs_d,armed,bad;reg [17:0] samples;
    reg [31:0] frame_number;
    reg loading,load_half;reg [7:0] load_low;reg [17:0] load_count;
    reg [2:0] dump_state;reg [17:0] dump_address;reg [15:0] dump_pixel;
    wire frame_edge=vs_i&&!vs_d;
    wire inside_view=de_i&&x>=VIEW_X&&x<VIEW_X+TW&&y>=VIEW_Y&&y<VIEW_Y+TH;
    wire dump_fetch=dump_state==1&&!inside_view;
    wire [17:0] read_addr=dump_fetch?dump_address:inside_view?(y-VIEW_Y)*TW+(x-VIEW_X):18'd0;
    // Stop on malformed lines immediately, so sequential write addresses
    // cannot drift from their physical source row in the shared suffix.
    wire sample_now=armed&&!bad&&!frozen&&!load_begin&&!frame_edge&&de_i&&camera_ready_i&&x<WIDTH&&y<HEIGHT&&x_mod3==1&&y_mod3==1&&samples<PIXELS;
    assign dump_valid=dump_state==5||dump_state==6;
    assign dump_data=dump_state==5?dump_pixel[7:0]:dump_pixel[15:8];
    assign load_ready=loading&&load_count<PIXELS;
    wire [15:0] selected=read_late_d?rd_late:read_bank?rd1:rd0;
    assign rgb_o=read_visible?{selected[15:11],selected[15:13],selected[10:5],selected[10:9],selected[4:0],selected[4:2]}:24'd0;
    wire [17:0] early_address=read_addr<PREFIX?read_addr:18'd0;
    wire [17:0] late_address=read_addr>=PREFIX?read_addr-PREFIX:18'd0;
    qy_photo_ram #(.WORDS(PREFIX>0?PREFIX:1)) early0(.clk(clk_i),.read_address(early_address),
        .write_enable(write0_q),.write_address({18'd0}|write_early_q),.write_data(write_rgb_q),.read_data(rd0));
    qy_photo_ram #(.WORDS(PREFIX>0?PREFIX:1)) early1(.clk(clk_i),.read_address(early_address),
        .write_enable(write1_q),.write_address({18'd0}|write_early_q),.write_data(write_rgb_q),.read_data(rd1));
    qy_photo_ram #(.WORDS(SUFFIX>0?SUFFIX:1)) late(.clk(clk_i),.read_address(late_address),
        .write_enable(write_late_en_q),.write_address({18'd0}|write_late_q),.write_data(write_rgb_q),.read_data(rd_late));
    always @(posedge clk_i)begin
        if(!rst_n_i)begin
            front_bank<=0;read_bank<=0;read_bank_q<=0;read_is_late<=0;read_late_d<=0;
            read_visible<=0;read_visible_q<=0;frame_valid<=0;frame_valid_o<=0;hs_d<=0;
            write_early_q<=0;write_late_q<=0;
            write0_q<=0;write1_q<=0;write_late_en_q<=0;write_rgb_q<=0;
            x<=0;y<=0;x_mod3<=0;y_mod3<=0;de_d<=0;vs_d<=0;armed<=0;bad<=0;samples<=0;
            de_o<=0;hs_o<=0;vs_o<=0;
            frozen<=0;frozen_frame<=0;frame_number<=0;loading<=0;load_half<=0;load_low<=0;load_count<=0;
        end else begin
            de_o<=de_d;hs_o<=hs_d;vs_o<=vs_d;frame_valid_o<=frame_valid;
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
                frame_number<=frame_number+1'b1;
                if(!frozen)begin
                    if(armed&&!bad&&camera_ready_i&&!de_i&&y==HEIGHT&&samples==PIXELS)begin
                        front_bank<=!front_bank;frame_valid<=1;
                        if(freeze_request)begin frozen<=1;frozen_frame<=frame_number;end
                    end else frame_valid<=0;
                end
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
            // A loaded image and a frozen live frame use the same RAM and display port.
            // Stream requests only borrow display reads outside the visible thumbnail.
            if(frozen&&!freeze_request)begin
                frozen<=0;frame_valid<=0;armed<=0;loading<=0;
            end
            if(load_begin)begin
                frozen<=1;frame_valid<=0;front_bank<=0;loading<=1;load_half<=0;load_count<=0;
                write0_q<=0;write1_q<=0;write_late_en_q<=0;
            end else if(load_valid&&load_ready)begin
                if(!load_half)begin load_low<=load_data;load_half<=1;end
                else begin
                    load_half<=0;load_count<=load_count+1'b1;
                    write_rgb_q<={load_data,load_low};
                    write0_q<=load_count<PREFIX;write1_q<=0;write_late_en_q<=load_count>=PREFIX;
                    write_early_q<=load_count<PREFIX?load_count:18'd0;
                    write_late_q<=load_count>=PREFIX?load_count-PREFIX:18'd0;
                end
            end
            if(load_commit)begin frame_valid<=loading&&load_count==PIXELS&&!load_half;loading<=0;end
            if(load_abort)begin frame_valid<=0;loading<=0;end
        end
    end
    always @(posedge clk_i)begin
        if(!rst_n_i)begin dump_state<=0;dump_address<=0;dump_pixel<=0;end
        else if(!frozen||load_begin||load_abort)dump_state<=0;
        else case(dump_state)
            0:if(dump_start&&frame_valid)begin dump_address<=0;dump_state<=1;end
            1:if(dump_fetch)dump_state<=2;
            2:dump_state<=3;
            3:begin dump_pixel<=dump_address>=PREFIX?rd_late:front_bank?rd1:rd0;dump_state<=5;end
            5:if(dump_ready)dump_state<=6;
            6:if(dump_ready)begin
                if(dump_address==PIXELS-1)dump_state<=0;
                else begin dump_address<=dump_address+1'b1;dump_state<=1;end
            end
            default:dump_state<=0;
        endcase
    end
    // synthesis translate_off
    initial if(WIDTH<3||HEIGHT<3||WIDTH>1920||HEIGHT>1080||WIDTH%3||HEIGHT%3||VIEW_X<0||VIEW_Y<0||VIEW_X+TW>WIDTH||VIEW_Y+TH>HEIGHT)
        $fatal(1,"CONFIG_ERROR compact thumbnail geometry");
    // synthesis translate_on
endmodule
`default_nettype wire
