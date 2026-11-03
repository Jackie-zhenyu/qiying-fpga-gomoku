`timescale 1ns / 1ps
`default_nettype none
// Same-clock snapshot inputs. Feed a coherent shadow record; use a mailbox
// before this module if the source is in another clock domain.
module qy_ui_renderer #(
    parameter FONT_FILE="assets/ui_font.hex", TILE_FILE="assets/ui_tiles.hex"
)(
    input wire clk_i, input wire rst_n_i,
    input wire [11:0] x_i,y_i,
    input wire de_i,hs_i,vs_i,frame_commit_i,
    input wire [1:0] page_i,selected_i,
    input wire [161:0] board_i, // First P0 view: 9x9, index=row*9+col.
    input wire [6:0] last_index_i,black_index_i,white_index_i,
    input wire last_valid_i,black_valid_i,white_valid_i,
    input wire [1:0] next_color_i,
    input wire camera_ready_i,calibrated_i,ai_ready_i,paused_i,demo_i,
    // Already scaled and aligned to x_i/y_i in this pixel clock domain.
    // Viewport = [1200,1840) x [192,552), exactly 640x360, 16:9.
    input wire [23:0] camera_rgb_i,
    input wire camera_pixel_valid_i,
    output reg [23:0] rgb_o,
    output reg de_o,hs_o,vs_o,
    output reg [11:0] x_o,y_o
);
    `include "qy_ui_assets.vh"
    reg [31:0] font_rom[0:8191];
    reg [15:0] tile_rom[0:8191];
    initial begin $readmemh(FONT_FILE,font_rom); $readmemh(TILE_FILE,tile_rom); end
    reg [1:0] page,selected,next_color;
    reg [161:0] board;
    reg [6:0] last_index,black_index,white_index;
    reg last_valid,black_valid,white_valid,camera_ready,calibrated,ai_ready,paused,demo;
    // PH1A ERAM address/control registers require synchronous reset.
    // Keep ROM address inputs stable between clock edges, including reset.
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            page<=0; selected<=0; next_color<=0; board<=0;
            last_index<=0; black_index<=0; white_index<=0;
            last_valid<=0; black_valid<=0; white_valid<=0;
            camera_ready<=0; calibrated<=0; ai_ready<=0; paused<=0; demo<=1;
        end else if(frame_commit_i && !de_i) begin
            page<=page_i; selected<=selected_i; next_color<=next_color_i; board<=board_i;
            last_index<=last_index_i; black_index<=black_index_i; white_index<=white_index_i;
            last_valid<=last_valid_i && last_index_i<81;
            black_valid<=black_valid_i && ai_ready_i && black_index_i<81;
            white_valid<=white_valid_i && ai_ready_i && white_index_i<81;
            camera_ready<=camera_ready_i; calibrated<=calibrated_i;
            ai_ready<=ai_ready_i; paused<=paused_i; demo<=demo_i;
        end
    end
    function [23:0] palette;
        input [3:0] color;
        begin case(color)
            1: palette=24'he6edf2; 2: palette=24'h68d5ba;
            3: palette=24'h9dafbd; 4: palette=24'hf4b65d;
            5: palette=24'h64ccec; 6: palette=24'h5b4931;
            default: palette=24'he6edf2;
        endcase end
    endfunction
    reg [3:0] col,row;
    reg in_col,in_row;
    reg [5:0] dx,dy;
    reg [3:0] col_pre,row_pre;
    reg in_col_pre,in_row_pre;
    reg [5:0] dx_pre,dy_pre;
    reg [11:0] x_s,y_s;
    reg de_s,hs_s,vs_s,camera_valid_s;
    reg [23:0] camera_rgb_s;
    reg [6:0] index;
    reg [1:0] stone;
    reg [23:0] base;
    reg override_glyph;
    reg [7:0] glyph;
    reg [3:0] ink;
    reg [4:0] gx,gy;
    reg [6:0] coord_index;
    reg coord_valid;
    integer k;
    wire [5:0] tile_x=x_s[10:5];
    wire [5:0] tile_y=y_s[10:5];
    wire [12:0] tile_addr=(x_s<1920 && y_s<1080)?page*2040+tile_y*60+tile_x:13'd0;
    always @* begin
        col_pre=0; row_pre=0; dx_pre=63; dy_pre=63; in_col_pre=0; in_row_pre=0;
        for(k=0;k<9;k=k+1) begin
            if(x_i>=200+k*80 && x_i<280+k*80) begin
                col_pre=k; in_col_pre=1; dx_pre=(x_i>=240+k*80)?x_i-(240+k*80):(240+k*80)-x_i;
            end
            if(y_i>=208+k*80 && y_i<288+k*80) begin
                row_pre=k; in_row_pre=1; dy_pre=(y_i>=248+k*80)?y_i-(248+k*80):(248+k*80)-y_i;
            end
        end
    end
    // Register cell coordinates before circle/stone/color composition.
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            col<=0; row<=0; dx<=63; dy<=63; in_col<=0; in_row<=0;
            x_s<=0; y_s<=0; de_s<=0; hs_s<=0; vs_s<=0; camera_valid_s<=0; camera_rgb_s<=0;
        end else begin
            col<=col_pre; row<=row_pre; dx<=dx_pre; dy<=dy_pre; in_col<=in_col_pre; in_row<=in_row_pre;
            x_s<=x_i; y_s<=y_i; de_s<=de_i; hs_s<=hs_i; vs_s<=vs_i;
            camera_valid_s<=camera_pixel_valid_i; camera_rgb_s<=camera_rgb_i;
        end
    end
    always @* begin
        index=row*9+col; stone=board[index*2+:2];
        base=24'h0c1822;
        if(y_s>=128 && y_s<130) base=24'h263c4b;
        if(y_s>=952) base=24'h142632;
        if(page==0) begin
            if(x_s>=64 && x_s<1120 && y_s>=208 && y_s<936) base=24'head4aa;
            if(x_s>=1184 && x_s<1856 && y_s>=592 && y_s<936) base=24'h142632;
            if(x_s>=1200 && x_s<1840 && y_s>=192 && y_s<552) begin
                base=(x_s[5]^y_s[5])?24'h192d3b:24'h162936;
                if(camera_ready && camera_valid_s) base=camera_rgb_s;
            end
            if((in_col && dx<=1 && y_s>=248 && y_s<=888) ||
               (in_row && dy<=1 && x_s>=240 && x_s<=880)) base=24'h796342;
            if(in_col && in_row) begin
                if(((col==2 || col==6)&&(row==2 || row==6) || (col==4 && row==4)) && dx+dy<=5) base=24'h796342;
                if(black_valid && index==black_index && dx<=30 && dy<=ui_circle_30(dx) &&
                   !(dx<=28 && dy<=ui_circle_28(dx))) base=24'he29128;
                if(white_valid && index==white_index && dx<=26 && dy<=ui_circle_26(dx) &&
                   !(dx<=24 && dy<=ui_circle_24(dx))) base=24'h198ba9;
                if(stone!=0 && dx<=24 && dy<=ui_circle_24(dx)) begin
                    base=(stone==1)?24'h101a23:24'haeb8bb;
                    if(dx<=22 && dy<=ui_circle_22(dx)) base=(stone==1)?24'h25343f:24'hfaf8ef;
                    if(stone==3) base=24'hd98d27; // Invalid formal-cell input is visibly diagnostic.
                    if(last_valid && index==last_index && dx<=3 && dy<=3) base=24'he4695d;
                end
            end
            // Legend marks occupy the unused margin beside the 9x9 board.
            if(x_s>=1016 && x_s<1032) begin
                if(y_s>=680 && y_s<696) base=24'h25343f;
                if(y_s>=744 && y_s<760) base=24'he4695d;
                if(y_s>=808 && y_s<824 && (x_s<1018||x_s>=1030||y_s<810||y_s>=822)) base=24'he29128;
                if(y_s>=872 && y_s<888 && (x_s<1018||x_s>=1030||y_s<874||y_s>=886)) base=24'h198ba9;
            end
        end else if(page==1) begin
            if(x_s>=192 && x_s<1100 && y_s>=272 && y_s<832) base=24'h142632;
            if(x_s>=224 && x_s<1056 && y_s>=304+selected*96 && y_s<368+selected*96) base=24'h235a54;
        end else if(page==2) begin
            if(x_s>=480 && x_s<1440 && y_s>=208 && y_s<864) base=24'h142632;
            if(x_s>=512 && x_s<800 && y_s>=592 && y_s<672) base=24'h2e414f;
            if(x_s>=1056 && x_s<1376 && y_s>=592 && y_s<672) base=24'h235a54;
        end
        override_glyph=0; glyph=0; ink=1; gx=x_s[4:0]; gy=y_s[4:0];
        coord_index=0; coord_valid=0;
        if(tile_y==1 && tile_x>=48 && tile_x<54) begin
            override_glyph=1; glyph=ui_label(demo?12:13,tile_x-48); ink=demo?4:2;
        end
        if(tile_y==3 && tile_x>=2 && tile_x<10) begin
            override_glyph=1; glyph=ui_label(camera_ready?1:0,tile_x-2); ink=camera_ready?2:3;
        end
        if(tile_y==3 && tile_x>=13 && tile_x<21) begin
            override_glyph=1; glyph=ui_label(calibrated?3:2,tile_x-13); ink=calibrated?2:3;
        end
        if(page==0) begin
            if(camera_ready && camera_valid_s && x_s>=1200 && x_s<1840 && y_s>=192 && y_s<552) begin
                override_glyph=1; glyph=0; // Never stamp placeholder text onto real video.
            end
            if(y_s>=208 && y_s<240 && in_col && dx<16) begin
                override_glyph=1; glyph=ui_digit(col+1'b1); gx=x_s-(240+col*80)+16; gy=y_s-208; ink=6;
            end
            if(x_s>=160 && x_s<192 && in_row && dy<16) begin
                override_glyph=1; glyph=ui_digit(row+1'b1); gx=x_s-160; gy=y_s-(248+row*80)+16; ink=6;
            end
            if(tile_x>=43 && tile_x<48 && tile_y==21) begin
                override_glyph=1; glyph=ui_label(next_color==1?5:next_color==2?6:4,tile_x-43);
            end
            if(tile_x>=52 && tile_x<58 && tile_y==21) begin
                override_glyph=1; glyph=ui_label(paused?11:(next_color==0 || next_color==3)?4:10,tile_x-52);
            end
            if(tile_x>=43 && tile_x<56 && tile_y==27) begin
                override_glyph=1; glyph=ui_label(!ai_ready?7:(black_valid||white_valid)?9:8,tile_x-43); ink=3;
            end
            if((tile_y==23 || tile_y==25) && tile_x>=43 && tile_x<49) begin
                override_glyph=1; ink=(tile_y==23)?4:5;
                coord_index=(tile_y==23)?black_index:white_index;
                coord_valid=(tile_y==23)?black_valid:white_valid;
                if(!coord_valid) glyph=(tile_x==43)?UI_DASH:8'd0;
                else case(tile_x-43)
                    0:glyph=UI_LP; 1:glyph=ui_digit(coord_index/9+1);
                    2:glyph=UI_COMMA; 3:glyph=ui_digit(coord_index%9+1);
                    4:glyph=UI_RP; default:glyph=0;
                endcase
            end
        end
    end
    // After coordinate stage: tile + geometry, synchronous glyph ROM, output.
    reg [15:0] tile0;
    reg over0;
    reg [7:0] glyph0;
    reg [3:0] ink0;
    reg [4:0] gx0,gy0,gx1;
    reg [23:0] base0,base1,ink1;
    reg [31:0] font1;
    reg [2:0] sync0,sync1;
    reg [23:0] xy0,xy1;
    always @(posedge clk_i) begin
        tile0<=tile_rom[tile_addr];
        font1<=font_rom[{(over0?glyph0:tile0[7:0]),gy0}];
    end
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            over0<=0; glyph0<=0; ink0<=0; gx0<=0; gy0<=0; gx1<=0;
            base0<=0; base1<=0; ink1<=0; sync0<=0; sync1<=0; xy0<=0; xy1<=0;
            rgb_o<=0; de_o<=0; hs_o<=0; vs_o<=0; x_o<=0; y_o<=0;
        end else begin
            over0<=override_glyph; glyph0<=glyph; ink0<=ink; gx0<=gx; gy0<=gy;
            base0<=base; sync0<={vs_s,hs_s,de_s}; xy0<={y_s,x_s};
            base1<=base0; ink1<=palette(over0?ink0:tile0[11:8]); gx1<=gx0; sync1<=sync0; xy1<=xy0;
            rgb_o<=sync1[0]?(font1[31-gx1]?ink1:base1):24'd0;
            {vs_o,hs_o,de_o}<=sync1; {y_o,x_o}<=xy1;
        end
    end
endmodule
`default_nettype wire
