`timescale 1ns/1ps
`default_nettype none
module qy_storage_ui #(parameter FONT_FILE="storage_font.hex")(
 input wire clk,rst_n,game_active,replay_active,menu_selected,camera_ready,
 input wire [3:0] ui_state,slot_valid,input wire [1:0] slot,input wire [31:0] slot_moves,
 input wire [7:0] storage_error,init_error,input wire initialized,input wire [2:0] game_mode,
 input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 `include "storage_labels.vh"
 reg [31:0] font[0:8191];initial $readmemh(FONT_FILE,font);
 reg [11:0] x,y;reg de_d,vs_d,game,replay,selected,init;
 reg [3:0] page,valids;reg [1:0] chosen;reg [31:0] moves;reg [7:0] err,initerr;reg [2:0] mode;
 wire frame_edge=vs_i&&!vs_d;
 always @(posedge clk)begin
  if(!rst_n)begin x<=0;y<=0;de_d<=0;vs_d<=0;game<=0;replay<=0;selected<=0;page<=0;valids<=0;chosen<=0;moves<=0;err<=0;initerr<=0;init<=0;mode<=0;end
  else begin
   de_d<=de_i;vs_d<=vs_i;
   if(frame_edge)begin
    x<=0;y<=0;game<=game_active;replay<=replay_active;selected<=menu_selected;page<=ui_state;
    valids<=slot_valid;chosen<=slot;moves<=slot_moves;err<=storage_error;initerr<=init_error;init<=initialized;mode<=game_mode;
   end else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
  end
 end
 reg [23:0] base,ink;reg region;reg [5:0] label_id,position;reg [7:0] glyph;
 reg [4:0] gx,gy;integer i,left,top;reg [7:0] count;reg [3:0] digit;
 task text_line(input integer xx,yy,input [5:0] label);
  begin
   if(x>=xx&&x<1856&&y>=yy&&y<yy+32)begin region=1;label_id=label;position=(x-xx)>>5;gx=x-xx;gy=y-yy;end
  end
 endtask
 always @*begin
  base=rgb_i;ink=24'he8eef3;region=0;label_id=S_BLANK;position=0;gx=0;gy=0;count=0;digit=0;left=0;top=0;
  if(!game&&!replay)begin
   base=24'h0c1822;
   text_line(112,64,S_BRAND);text_line(112,160,S_HOME);
   for(i=0;i<2;i=i+1)begin
    left=112+i*880;
    if(x>=left&&x<left+816&&y>=304&&y<752)begin
     base=selected==i?24'h153b43:24'h14252f;
     if(selected==i&&(x<left+4||x>=left+812||y<308||y>=748))base=24'h68d5ba;
     text_line(left+48,368,i==0?S_GAME:S_REPLAY);
     text_line(left+48,464,i==0?S_GAME_DESC:S_REPLAY_DESC);
    end
   end
   text_line(112,864,S_NAV);text_line(112,944,S_RETURN);
  end else if(page==0&&!replay)begin
   if(x>=1056&&x<1856&&y>=64&&y<96)begin base=24'h0c1822;text_line(1056,64,S_RETURN);ink=24'h9dafbd;end
   if(mode==4&&y>=944&&y<1040)begin base=24'h0c1822;text_line(112,976,S_PAUSE);end
  end else if(replay&&page==10)begin
   if(y<160||y>=944||(x>=1184&&y>=576&&y<928))base=24'h0c1822;
   // The renderer already supplies the replay board background and legend.
   // Preserve both directly; repainting this margin also erases its glyphs.
   text_line(112,64,S_REPLAY);text_line(112,112,S_SLOT1+chosen);
   if(y>=160&&y<192)begin base=24'h0c1822;if(x<1184)text_line(112,160,S_BOARD);else text_line(1200,160,S_PHOTO);end
   if(x>=1184)begin text_line(1232,640,S_VIEW_NOTE);text_line(1232,720,S_VIEW_DETAIL);end
   text_line(112,944,S_VIEW_NAV);text_line(112,1008,S_RETURN);
  end else begin
   base=24'h0c1822;text_line(112,64,replay?S_REPLAY:S_SAVE_TITLE);
   if(page==1||page==7)begin
    text_line(112,192,replay?S_LOAD_TITLE:S_SAVE_TITLE);
    for(i=0;i<4;i=i+1)begin
     left=112+i*432;
     if(x>=left&&x<left+400&&y>=336&&y<672)begin
      base=chosen==i?24'h153b43:24'h14252f;
      if(chosen==i&&(x<left+4||x>=left+396||y<340||y>=668))base=24'h68d5ba;
      text_line(left+40,384,S_SLOT1+i);text_line(left+40,464,valids[i]?S_OCCUPIED:S_EMPTY);
      if(valids[i]&&x>=left+40&&x<left+168&&y>=544&&y<576)begin
       count=moves[i*8+:8];position=(x-left-40)>>5;region=1;gx=x-left-40;gy=y-544;
       if(position==3)begin label_id=S_MOVES;position=0;end
       else begin digit=position==0?count/100:position==1?(count/10)%10:count%10;label_id=S_HEX;position=digit;end
      end
     end
    end
    if(!init)text_line(112,752,initerr==0?S_INIT:S_ERROR);
    else if(!replay)text_line(112,752,valids[chosen]?S_OVERWRITE:S_NEW_SLOT);
    text_line(112,880,replay?S_LOAD_NAV:S_SAVE_NAV);text_line(112,976,S_RETURN);
   end else begin
    text_line(112,352,page==2?S_FROZEN:page==3||page==4?S_BUSY:page==5?S_SUCCESS:page==8||page==9?S_LOADING:S_FAILED);
    if(page==6)begin
     if(err==8'h30)text_line(112,448,S_INELIGIBLE);
     else if(err==8'h13)text_line(112,448,S_EMPTY);
     else if(x>=112&&x<176&&y>=448&&y<480)begin
      region=1;label_id=S_HEX;position=x<144?err[7:4]:err[3:0];gx=x-112;gy=y-448;ink=24'hf4b65d;
     end
    end
    if(page==5||page==6)text_line(112,640,S_ACK);
   end
  end
  glyph=storage_label(label_id,position);
 end
 (* keep="true" *) reg [12:0] font_address;
 reg [31:0] font_word;reg [4:0] bit0,bit1;reg [23:0] base0,base1,ink0,ink1;
 reg region0,region1;reg [2:0] sync0,sync1;
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
