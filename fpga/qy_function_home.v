`timescale 1ns/1ps
`default_nettype none
// Full-HD home raster. Active-game pixels pass through except the return hint.
// All state is latched at VS; font ROM and sync use the same three-stage pipe.
module qy_function_home #(parameter FONT_FILE="menu_font.hex")(
 input wire clk,rst_n,game_active,camera_ready,
 input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 `include "menu_labels.vh"
 reg [31:0] font[0:4095];initial $readmemh(FONT_FILE,font);
 reg [11:0] x,y;reg de_d,vs_d,active,ready;
 wire frame_edge=vs_i&&!vs_d;
 always @(posedge clk)begin
  if(!rst_n)begin x<=0;y<=0;de_d<=0;vs_d<=0;active<=0;ready<=0;end
  else begin
   de_d<=de_i;vs_d<=vs_i;
   if(frame_edge)begin x<=0;y<=0;active<=game_active;ready<=camera_ready;end
   else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
  end
 end
 reg [23:0] base,ink;reg region;
 reg [4:0] label_id;reg [5:0] position;reg [6:0] glyph;reg [4:0] gx,gy;
 integer i;reg grid;reg [11:0] dx,dy;
 always @*begin
  base=rgb_i;ink=24'he8eef3;region=0;label_id=0;position=0;gx=0;gy=0;grid=0;dx=0;dy=0;
  if(!active)begin
   base=24'h0c1822;
   if(x>=112&&x<1808&&y>=192&&y<194)base=24'h29404d;
   if(x>=112&&x<1168&&y>=352&&y<800)begin
    base=24'h15313b;
    if(x<116||x>=1164||y<356||y>=796)base=24'h68d5ba;
    if(x<124)base=24'h68d5ba;
   end
   if(x>=1280&&x<1808&&y>=288&&y<816)begin
    base=24'h1b2a30;
    for(i=0;i<9;i=i+1)begin
     if((x>=1328+i*54&&x<1330+i*54&&y>=336&&y<770)||
        (y>=336+i*54&&y<338+i*54&&x>=1328&&x<1762))grid=1;
    end
    if(grid)base=24'h43534c;
    // Static Go-moku motif, independent of any formal/observed game state.
    dx=x>=1491?x-1491:1491-x;dy=y>=499?y-499:499-y;
    if(dx<=21&&dy<=21&&dx+dy<=32)base=24'h02080c;
    dx=x>=1545?x-1545:1545-x;dy=y>=553?y-553:553-y;
    if(dx<=21&&dy<=21&&dx+dy<=32)base=24'hf5f0de;
    dx=x>=1545?x-1545:1545-x;dy=y>=499?y-499:499-y;
    if(dx<=21&&dy<=21&&dx+dy<=32)base=24'h02080c;
    dx=x>=1599?x-1599:1599-x;dy=y>=553?y-553:553-y;
    if(dx<=21&&dy<=21&&dx+dy<=32)base=24'hf5f0de;
   end
   if(x>=112&&x<368&&y>=64&&y<128)begin region=1;label_id=M_BRAND;position=(x-112)>>6;gx=(x-112)>>1;gy=(y-64)>>1;ink=24'h68d5ba;end
   if(x>=112&&x<1136&&y>=240&&y<304)begin region=1;label_id=M_HOME;position=(x-112)>>6;gx=(x-112)>>1;gy=(y-240)>>1;end
   if(x>=384&&x<1152&&y>=96&&y<128)begin region=1;label_id=M_SUBTITLE;position=(x-384)>>5;gx=x-384;gy=y-96;ink=24'h9dafbd;end
   if(x>=1296&&x<1776&&y>=96&&y<128)begin region=1;label_id=ready?M_READY:M_CAMERA_WAIT;position=(x-1296)>>5;gx=x-1296;gy=y-96;ink=ready?24'h68d5ba:24'hf4b65d;end
   if(x>=176&&x<1008&&y>=416&&y<480)begin region=1;label_id=M_GAME;position=(x-176)>>6;gx=(x-176)>>1;gy=(y-416)>>1;end
   if(x>=176&&x<1104&&y>=528&&y<560)begin region=1;label_id=M_DESCRIPTION;position=(x-176)>>5;gx=x-176;gy=y-528;ink=24'hb4c7cf;end
   if(x>=176&&x<1104&&y>=592&&y<624)begin region=1;label_id=M_CONFIRM;position=(x-176)>>5;gx=x-176;gy=y-592;ink=24'h68d5ba;end
   if(x>=176&&x<1104&&y>=720&&y<752)begin region=1;label_id=M_SELECTED;position=(x-176)>>5;gx=x-176;gy=y-720;ink=24'h9dafbd;end
   if(x>=112&&x<1808&&y>=912&&y<914)base=24'h29404d;
   if(x>=112&&x<1808&&y>=944&&y<976)begin region=1;label_id=M_NAVIGATION;position=(x-112)>>5;gx=x-112;gy=y-944;end
   if(x>=112&&x<1808&&y>=1008&&y<1040)begin region=1;label_id=M_RETURN;position=(x-112)>>5;gx=x-112;gy=y-1008;ink=24'h9dafbd;end
  end else if(x>=1056&&x<1856&&y>=64&&y<96)begin
   base=24'h0c1822;region=1;label_id=M_RETURN_GAME;position=(x-1056)>>5;gx=x-1056;gy=y-64;ink=24'h9dafbd;
  end
  glyph=menu_label(label_id,position);
 end
 (* keep="true" *) reg [11:0] font_address;
 reg [31:0] font_word;reg [4:0] bit0,bit1;
 reg [23:0] base0,base1,ink0,ink1;reg region0,region1;reg [2:0] sync0,sync1;
 always @(posedge clk)font_word<=font[font_address];
 always @(posedge clk)begin
  if(!rst_n)begin
   font_address<=0;bit0<=0;bit1<=0;base0<=0;base1<=0;ink0<=0;ink1<=0;
   region0<=0;region1<=0;sync0<=0;sync1<=0;rgb_o<=0;de_o<=0;hs_o<=0;vs_o<=0;
  end else begin
   font_address<={glyph,gy};bit0<=31-gx;bit1<=bit0;
   base0<=base;base1<=base0;ink0<=ink;ink1<=ink0;region0<=region;region1<=region0;
   sync0<={vs_i,hs_i,de_i};sync1<=sync0;{vs_o,hs_o,de_o}<=sync1;
   rgb_o<=!sync1[0]?24'd0:region1&&font_word[bit1]?ink1:base1;
  end
 end
endmodule
`default_nettype wire
