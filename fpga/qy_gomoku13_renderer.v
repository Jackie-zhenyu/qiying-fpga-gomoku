`timescale 1ns / 1ps
`default_nettype none
// Same-clock snapshot inputs. Feed a coherent shadow record; use a mailbox
// before this module if the source is in another clock domain.
module qy_gomoku13_renderer #(
    parameter DYNAMIC_SIZE=0, parameter ORIGIN_OPENING=0,
    parameter FONT_FILE="assets/gomoku13/ui_font.hex", TILE_FILE="assets/gomoku13/ui_tiles.hex"
)(
    input wire clk_i, input wire rst_n_i,
    input wire [11:0] x_i,y_i,
    input wire de_i,hs_i,vs_i,frame_commit_i,
    input wire [1:0] page_i,selected_i,
    input wire [3:0] board_size_i,
    input wire [337:0] board_i, // 13x13 compact display view, index=row*13+col.
    input wire [7:0] last_index_i,black_index_i,white_index_i,
    input wire last_valid_i,black_valid_i,white_valid_i,
    input wire origin_valid_i,input wire [7:0] origin_index_i,
    input wire [1:0] next_color_i,
    input wire camera_ready_i,calibrated_i,ai_ready_i,paused_i,demo_i,
    input wire [2:0] phase_i,
    input wire [1:0] winner_i,black_reason_i,white_reason_i,
    input wire draw_i,
    input wire [7:0] move_count_i,
    // Already scaled and aligned to x_i/y_i in this pixel clock domain.
    // Viewport = [1200,1840) x [192,552), exactly 640x360, 16:9.
    input wire [23:0] camera_rgb_i,
    input wire camera_pixel_valid_i,
    output reg [23:0] rgb_o,
    output reg de_o,hs_o,vs_o,
    output reg [11:0] x_o,y_o
);
    `include "qy_gomoku13_assets.vh"
    reg [31:0] font_rom[0:8191];
    reg [15:0] tile_rom[0:8191];
    initial begin $readmemh(FONT_FILE,font_rom); $readmemh(TILE_FILE,tile_rom); end
    reg [1:0] page,selected,next_color;
    reg [3:0] board_size;
    wire [11:0] grid_right=240+(board_size-1'b1)*52;
    wire [11:0] grid_bottom=264+(board_size-1'b1)*52;
    reg [2:0] phase;
    reg [1:0] winner,black_reason,white_reason;
    reg draw;
    reg [7:0] move_count;
    reg [337:0] board;
    reg [7:0] last_index,black_index,white_index;
    reg last_valid,black_valid,white_valid,camera_ready,calibrated,ai_ready,paused,demo;
    reg origin_valid;reg [7:0] origin_index;reg [3:0] origin_col,origin_row;
    reg signed [5:0] black_dx,black_dy,white_dx,white_dy;
    wire [3:0] incoming_size=DYNAMIC_SIZE&&board_size_i>=5&&board_size_i<=13?board_size_i:4'd13;
    wire incoming_origin_valid=ORIGIN_OPENING&&origin_valid_i&&origin_index_i<169&&
        origin_index_i/13<incoming_size&&origin_index_i%13<incoming_size;
    function signed [5:0] relative_x;
        input [7:0] at,anchor;integer a,b;
        begin a=at%13;b=anchor%13;relative_x=a-b;end
    endfunction
    function signed [5:0] relative_y;
        input [7:0] at,anchor;integer a,b;
        begin a=at/13;b=anchor/13;relative_y=a-b;end
    endfunction
    function [1:0] relative_length;
        input signed [5:0] value;reg [5:0] magnitude;
        begin magnitude=value<0?-value:value;
            relative_length=value==0?1:magnitude<10?2:3;
        end
    endfunction
    // 255 is a procedural plus sign, leaving the original font/IDs untouched.
    function [7:0] relative_glyph;
        input signed [5:0] value;input [3:0] position;reg [5:0] magnitude;
        begin magnitude=value<0?-value:value;relative_glyph=0;
            if(value==0)begin if(position==0)relative_glyph=ui_digit(0);end
            else if(position==0)relative_glyph=value<0?UI_DASH:8'd255;
            else if(magnitude<10)begin if(position==1)relative_glyph=ui_digit(magnitude[3:0]);end
            else if(position==1)relative_glyph=ui_digit(1);
            else if(position==2)relative_glyph=ui_digit(magnitude-10);
        end
    endfunction
    // PH1A ERAM address/control registers require synchronous reset.
    // Keep ROM address inputs stable between clock edges, including reset.
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            page<=0; selected<=0; next_color<=0; board<=0;board_size<=13;
            phase<=0;winner<=0;black_reason<=0;white_reason<=0;draw<=0;move_count<=0;
            last_index<=0; black_index<=0; white_index<=0;
            last_valid<=0; black_valid<=0; white_valid<=0;
            camera_ready<=0; calibrated<=0; ai_ready<=0; paused<=0; demo<=1;
            origin_valid<=0;origin_index<=0;origin_col<=0;origin_row<=0;
            black_dx<=0;black_dy<=0;white_dx<=0;white_dy<=0;
        end else if(frame_commit_i && !de_i) begin
            board_size<=DYNAMIC_SIZE&&board_size_i>=5&&board_size_i<=13?board_size_i:4'd13;
            page<=page_i; selected<=selected_i; next_color<=next_color_i; board<=board_i;
            phase<=phase_i;winner<=winner_i;black_reason<=black_reason_i;white_reason<=white_reason_i;
            draw<=draw_i;move_count<=move_count_i;
            last_index<=last_index_i; black_index<=black_index_i; white_index<=white_index_i;
            last_valid<=last_valid_i && last_index_i<169;
            black_valid<=black_valid_i && ai_ready_i && black_index_i<169;
            white_valid<=white_valid_i && ai_ready_i && white_index_i<169;
            camera_ready<=camera_ready_i; calibrated<=calibrated_i;
            ai_ready<=ai_ready_i; paused<=paused_i; demo<=demo_i;
            origin_valid<=incoming_origin_valid;origin_index<=incoming_origin_valid?origin_index_i:8'd0;
            origin_col<=incoming_origin_valid?origin_index_i%13:0;
            origin_row<=incoming_origin_valid?origin_index_i/13:0;
            black_dx<=incoming_origin_valid?relative_x(black_index_i,origin_index_i):6'sd0;
            black_dy<=incoming_origin_valid?relative_y(black_index_i,origin_index_i):6'sd0;
            white_dx<=incoming_origin_valid?relative_x(white_index_i,origin_index_i):6'sd0;
            white_dy<=incoming_origin_valid?relative_y(white_index_i,origin_index_i):6'sd0;
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
    reg [7:0] index;
    reg [1:0] stone;
    reg [23:0] base;
    reg override_glyph;
    reg [7:0] glyph;
    reg [3:0] ink;
    reg [4:0] gx,gy;
    reg [7:0] coord_index;
    reg coord_valid;
    reg signed [5:0] relative_axis,coord_x,coord_y;
    reg [5:0] axis_magnitude;reg [1:0] coord_x_length,coord_y_length;
    reg [3:0] coord_length,coord_position;reg [11:0] coord_start;
    reg [5:0] axis_local;
    integer k;
    wire [5:0] tile_x=x_s[10:5];
    wire [5:0] tile_y=y_s[10:5];
    wire [12:0] tile_addr=(x_s<1920 && y_s<1080)?page*2040+tile_y*60+tile_x:13'd0;
    always @* begin
        col_pre=0; row_pre=0; dx_pre=63; dy_pre=63; in_col_pre=0; in_row_pre=0;
        for(k=0;k<13;k=k+1) begin
            if(k<board_size && x_i>=214+k*52 && x_i<266+k*52) begin
                col_pre=k; in_col_pre=1; dx_pre=(x_i>=240+k*52)?x_i-(240+k*52):(240+k*52)-x_i;
            end
            if(k<board_size && y_i>=238+k*52 && y_i<290+k*52) begin
                row_pre=k; in_row_pre=1; dy_pre=(y_i>=264+k*52)?y_i-(264+k*52):(264+k*52)-y_i;
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
        index=row*13+col; stone=board[index*2+:2];
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
            if((in_col && dx<=1 && y_s>=264 && y_s<=grid_bottom) ||
               (in_row && dy<=1 && x_s>=240 && x_s<=grid_right)) base=24'h796342;
            if(in_col && in_row) begin
                if(board_size==13&&((col==3 || col==9)&&(row==3 || row==9) || (col==6 && row==6)) && dx+dy<=5) base=24'h796342;
                if(black_valid && index==black_index && dx<=23 && dy<=ui_circle_23(dx) &&
                   !(dx<=21 && dy<=ui_circle_21(dx))) base=24'he29128;
                if(white_valid && index==white_index && dx<=20 && dy<=ui_circle_20(dx) &&
                   !(dx<=18 && dy<=ui_circle_18(dx))) base=24'h198ba9;
                if(stone!=0 && dx<=18 && dy<=ui_circle_18(dx)) begin
                    base=(stone==1)?24'h101a23:24'haeb8bb;
                    if(dx<=16 && dy<=ui_circle_16(dx)) base=(stone==1)?24'h25343f:24'hfaf8ef;
                    if(stone==3) base=24'hd98d27; // Invalid formal-cell input is visibly diagnostic.
                    if(last_valid && index==last_index && dx<=3 && dy<=3) base=24'he4695d;
                end
                // Fixed logical origin: corner brackets survive every last-move change.
                if(ORIGIN_OPENING&&origin_valid&&index==origin_index&&
                   ((dx>=20&&dx<=23&&dy>=14&&dy<=23)||
                    (dy>=20&&dy<=23&&dx>=14&&dx<=23)))base=24'h68d5ba;
            end
            // Legend marks occupy the unused margin beside the 13x13 board.
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
        relative_axis=0;axis_magnitude=0;axis_local=0;coord_x=0;coord_y=0;
        coord_x_length=0;coord_y_length=0;coord_length=0;coord_position=0;coord_start=0;
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
            if(y_s>=208 && y_s<240 && in_col && x_s>=224+col*52 && x_s<256+col*52) begin
                override_glyph=1; gx=x_s-(240+col*52)+16; gy=y_s-208; ink=6;
                if(ORIGIN_OPENING&&origin_valid)begin
                    relative_axis=$signed({2'b0,col})-$signed({2'b0,origin_col});
                    axis_magnitude=relative_axis<0?-relative_axis:relative_axis;axis_local=gx;
                    if(relative_axis==0)glyph=ui_digit(0);
                    else if(axis_magnitude<10)begin
                        glyph=relative_glyph(relative_axis,axis_local<16?0:1);gx={axis_local[3:0],1'b0};
                    end else if(axis_local<30)begin
                        glyph=relative_glyph(relative_axis,axis_local/10);gx=(axis_local%10)*3;
                    end else glyph=0;
                end else if(col<9) glyph=ui_digit(col+1'b1);
                else begin
                    glyph=(gx<16)?ui_digit(1):ui_digit(col-9);
                    gx={gx[3:0],1'b0};
                end
            end
            if(x_s>=160 && x_s<192 && in_row && y_s>=248+row*52 && y_s<280+row*52) begin
                override_glyph=1; gx=x_s-160; gy=y_s-(264+row*52)+16; ink=6;
                if(ORIGIN_OPENING&&origin_valid)begin
                    relative_axis=$signed({2'b0,row})-$signed({2'b0,origin_row});
                    axis_magnitude=relative_axis<0?-relative_axis:relative_axis;axis_local=gx;
                    if(relative_axis==0)glyph=ui_digit(0);
                    else if(axis_magnitude<10)begin
                        glyph=relative_glyph(relative_axis,axis_local<16?0:1);gx={axis_local[3:0],1'b0};
                    end else if(axis_local<30)begin
                        glyph=relative_glyph(relative_axis,axis_local/10);gx=(axis_local%10)*3;
                    end else glyph=0;
                end else if(row<9) glyph=ui_digit(row+1'b1);
                else begin
                    glyph=(gx<16)?ui_digit(1):ui_digit(row-9);
                    gx={gx[3:0],1'b0};
                end
            end
            if(tile_x>=43 && tile_x<48 && tile_y==21) begin
                override_glyph=1; glyph=ui_label(next_color==1?5:next_color==2?6:4,tile_x-43);
            end
            if(tile_x>=52 && tile_x<58 && tile_y==21) begin
                override_glyph=1; glyph=ui_label(phase==5?21:phase==4?20:phase==2?19:phase==1?18:17,tile_x-52);
            end
            if(tile_x>=43 && tile_x<49 && tile_y==27) begin
                override_glyph=1; glyph=ui_label(winner==1?14:winner==2?15:draw?16:phase==5?21:10,tile_x-43); ink=3;
            end
            if(tile_y==27 && tile_x>=55 && tile_x<=57) begin
                override_glyph=1;glyph=ui_digit(tile_x==55?move_count/100:tile_x==56?(move_count/10)%10:move_count%10);ink=1;
            end
            if((tile_y==23 || tile_y==25) && tile_x>=50 && tile_x<56) begin
                override_glyph=1;ink=(tile_y==23)?4:5;
                if(tile_y==23) glyph=black_valid?ui_label(black_reason==1?23:black_reason==2?24:22,tile_x-50):0;
                else glyph=white_valid?ui_label(white_reason==1?23:white_reason==2?24:22,tile_x-50):0;
            end
            if((tile_y==23 || tile_y==25) && tile_x>=43 && tile_x<50) begin
                override_glyph=1; ink=(tile_y==23)?4:5;
                coord_index=(tile_y==23)?black_index:white_index;
                coord_valid=(tile_y==23)?black_valid:white_valid;
                if(!coord_valid) glyph=(tile_x==43)?UI_DASH:8'd0;
                else if(ORIGIN_OPENING&&origin_valid)begin
                    coord_x=tile_y==23?black_dx:white_dx;coord_y=tile_y==23?black_dy:white_dy;
                    coord_x_length=relative_length(coord_x);coord_y_length=relative_length(coord_y);
                    coord_length=3+coord_x_length+coord_y_length;
                    coord_start=1376+(224-coord_length*24)/2;
                    glyph=0;
                    if(x_s>=coord_start&&x_s<coord_start+coord_length*24)begin
                        coord_position=(x_s-coord_start)/24;gx=(x_s-coord_start)%24+4;
                        if(coord_position==0)glyph=UI_LP;
                        else if(coord_position<=coord_x_length)glyph=relative_glyph(coord_x,coord_position-1'b1);
                        else if(coord_position==coord_x_length+1)glyph=UI_COMMA;
                        else if(coord_position<=coord_x_length+coord_y_length+1)
                            glyph=relative_glyph(coord_y,coord_position-coord_x_length-2);
                        else glyph=UI_RP;
                    end
                end else case(tile_x-43)
                    0:glyph=UI_LP;
                    1:glyph=(coord_index/13+1>=10)?ui_digit(1):0;
                    2:glyph=ui_digit((coord_index/13+1)%10);
                    3:glyph=UI_COMMA;
                    4:glyph=(coord_index%13+1>=10)?ui_digit(1):0;
                    5:glyph=ui_digit((coord_index%13+1)%10);
                    6:glyph=UI_RP; default:glyph=0;
                endcase
            end
        end
        if(ORIGIN_OPENING&&origin_valid&&glyph==255)begin
            glyph=0;
            if((gx>=14&&gx<=17&&gy>=8&&gy<=23)||
               (gy>=14&&gy<=17&&gx>=8&&gx<=23))base=palette(ink);
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
