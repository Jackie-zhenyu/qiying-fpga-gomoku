`timescale 1ns/1ps
`default_nettype none
// Frame-stable runtime peripheral settings. Four registered pixel cycles:
// geometry -> glyph/ROM address -> synchronous font row -> output.
// The 16x16 ROM is scaled 2x, limiting the additional font to 65536 bits.
module qy_peripheral_settings_panel #(parameter FONT_FILE="peripheral_font.hex")(
 input wire clk,rst_n,
 input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 input wire enable_i,home_i,input wire [2:0] selection_i,
 input wire learning_i,voice_confirm_i,saving_i,dirty_i,voice_enabled_i,
 input wire [239:0] card_uids_i,input wire [11:0] card_lengths_i,
 input wire [2:0] card_enabled_i,input wire [4:0] notice_i,
 input wire nfc_ready_i,nfc_fault_i,card_present_i,config_initialized_i,
 input wire [7:0] config_error_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 `include "peripheral_labels.vh"
 localparam [23:0] BG=24'h0c1822,PANEL=24'h14252f,SELECTED=24'h153b43,
  TEXT=24'he8eef3,MUTED=24'h9dafbd,GREEN=24'h68d5ba,YELLOW=24'hffcf40,RED=24'he4695d;
 reg [15:0] font[0:4095];initial $readmemh(FONT_FILE,font);
 reg [11:0] x,y;reg de_d,vs_d;
 wire frame_edge=vs_i&&!vs_d;
 reg enable,home,learning,voice_confirm,saving,dirty,voice_enabled,nfc_ready,nfc_fault,card_present,initialized;
 reg [2:0] selection,card_enabled;reg [239:0] card_uids;reg [11:0] card_lengths;
 reg [4:0] notice;reg [7:0] config_error;
 always @(posedge clk)begin
  if(!rst_n)begin
   x<=0;y<=0;de_d<=0;vs_d<=0;enable<=0;home<=0;selection<=0;learning<=0;voice_confirm<=0;
   saving<=0;dirty<=0;voice_enabled<=0;card_uids<=0;card_lengths<=0;card_enabled<=0;
   notice<=0;nfc_ready<=0;nfc_fault<=0;card_present<=0;initialized<=0;config_error<=0;
  end else begin
   de_d<=de_i;vs_d<=vs_i;
   if(frame_edge)begin
    x<=0;y<=0;enable<=enable_i;home<=home_i;selection<=selection_i;learning<=learning_i;
    voice_confirm<=voice_confirm_i;saving<=saving_i;dirty<=dirty_i;voice_enabled<=voice_enabled_i;
    card_uids<=card_uids_i;card_lengths<=card_lengths_i;card_enabled<=card_enabled_i;
    notice<=notice_i;nfc_ready<=nfc_ready_i;nfc_fault<=nfc_fault_i;card_present<=card_present_i;
    initialized<=config_initialized_i;config_error<=config_error_i;
   end else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
  end
 end
 reg [5:0] notice_label;
 always @*begin
  case(notice)
   1:notice_label=P_TAP;2:notice_label=P_REMOVE;3:notice_label=P_ADDED;
   4:notice_label=P_DUPLICATE;5:notice_label=P_TIMEOUT;6:notice_label=P_UNKNOWN;
   7:notice_label=P_VOICE_ON;8:notice_label=P_VOICE_OFF;9:notice_label=P_SAVED;
   10:notice_label=P_SAVE_ERROR;11:notice_label=P_RETRYING;12:notice_label=P_WAIT_CONFIG;
   13:notice_label=P_BAD_CONFIG;14:notice_label=P_NEED_NFC;15:notice_label=P_BAD_UID;
   16:notice_label=P_NEW_CONFIRM;17:notice_label=P_HISTORY_CONFIRM;18:notice_label=P_TEACH_UNAVAILABLE;
   19:notice_label=P_STORAGE_BUSY;20:notice_label=P_NO_REPEAT;21:notice_label=P_HOME_APPLIED;
   default:notice_label=P_BLANK;
  endcase
 end
 reg [23:0] base,ink;reg region,raw_mode,raw_high;
 reg [5:0] label_id,position;reg [4:0] gx,gy;
 reg [79:0] raw_uid;reg [3:0] raw_index;
 integer i,j,top;
 task text_line(input integer xx,yy,input [5:0] label);
  begin if(x>=xx&&x<1856&&y>=yy&&y<yy+32)begin
   region=1;raw_mode=0;label_id=label;position=(x-xx)>>5;gx=x-xx;gy=y-yy;
  end end
 endtask
 always @*begin
  base=rgb_i;ink=TEXT;region=0;raw_mode=0;raw_high=0;label_id=P_BLANK;position=0;
  gx=0;gy=0;raw_uid=0;raw_index=0;top=0;
  if(enable)begin
   base=BG;
   text_line(112,48,P_TITLE);text_line(112,112,P_SUBTITLE);
   if(x>=1280&&y>=112&&y<144)begin
    text_line(1280,112,nfc_fault?P_NFC_FAULT:nfc_ready?P_NFC_READY:P_NFC_WAIT);
    ink=nfc_fault?RED:nfc_ready?GREEN:YELLOW;
   end
   for(i=0;i<6;i=i+1)begin
    top=184+i*112;
    if(x>=80&&x<1856&&y>=top&&y<top+104)begin
     base=selection==i?SELECTED:PANEL;
     if(selection==i&&(x<84||x>=1852||y<top+4||y>=top+100))base=GREEN;
    end
   end
   for(i=0;i<3;i=i+1)begin
    top=200+i*112;
    text_line(128,top,i==0?P_GAME:i==1?P_TEACH:P_HISTORY);
    if(x>=448&&y>=top&&y<top+32)begin text_line(448,top,card_enabled[i]?P_REGISTERED:P_EMPTY);ink=card_enabled[i]?GREEN:MUTED;end
    if(x>=832&&card_enabled[i]&&y>=top&&y<top+32)begin
     text_line(832,top,card_lengths[i*4+:4]==4?P_LEN4:card_lengths[i*4+:4]==7?P_LEN7:P_LEN10);ink=MUTED;
    end
    if(card_enabled[i])begin
     text_line(160,top+40,P_UID);
     for(j=0;j<10;j=j+1)begin
      if(j<card_lengths[i*4+:4]&&x>=288+j*96&&x<352+j*96&&y>=top+40&&y<top+72)begin
       region=1;raw_mode=1;raw_uid=card_uids[i*80+:80];raw_index=j;
       raw_high=x<320+j*96;gx=x-(288+j*96);gy=y-(top+40);ink=TEXT;
      end
     end
    end
   end
   text_line(128,536,P_VOICE);
   if(x>=448&&y>=536&&y<568)begin text_line(448,536,voice_enabled?P_ENABLED:P_DISABLED);ink=voice_enabled?GREEN:MUTED;end
   text_line(160,576,voice_confirm?P_VOICE_CONFIRM:P_VOICE_HELP);
   if(y>=576&&y<608)ink=voice_confirm?YELLOW:MUTED;
   text_line(128,648,P_RETRY);text_line(160,688,P_RETRY_HELP);
   if(y>=688&&y<720)ink=MUTED;
   text_line(128,760,P_SAVE);
   if(x>=768&&y>=760&&y<792)begin text_line(768,760,dirty?P_DIRTY:P_CLEAN);ink=dirty?YELLOW:MUTED;end
   text_line(160,800,P_SAVE_HELP);if(y>=800&&y<832)ink=MUTED;
   text_line(112,864,!initialized?P_WAIT_CONFIG:saving?P_SAVING:notice!=0?notice_label:learning?P_TAP:P_HELP);
   if(y>=864&&y<896)ink=!initialized||saving||learning?YELLOW:
      notice==4||notice==5||notice==6||notice==10||notice==13||notice==14||notice==15?RED:notice!=0?GREEN:MUTED;
   text_line(112,912,learning?P_LEARN_HELP:card_present?P_PRESENT:P_BLANK);
   if(y>=912&&y<944)ink=MUTED;
   text_line(112,992,P_NAV);
  end else if(notice==6||notice==13||notice==15||(notice>=16&&notice<=21))begin
   // Unknown cards have visible feedback without changing the active page.
   // This band is above the camera viewport and outside the game board.
   if(x>=944&&x<1856&&y>=96&&y<144)begin base=PANEL;
    text_line(960,104,notice_label);ink=YELLOW;
   end
  end else if(home)begin text_line(112,1008,P_HOME_SETTINGS);ink=MUTED;end
 end
 // Isolate the UID byte multiplexer and label lookup from geometry logic.
 reg [5:0] label0,position0;reg raw0,high0;reg [79:0] uid0;reg [3:0] index0;
 reg [4:0] gx0,gy0;reg [7:0] byte_value,glyph;
 always @*begin
  case(index0)
   0:byte_value=uid0[7:0];1:byte_value=uid0[15:8];2:byte_value=uid0[23:16];
   3:byte_value=uid0[31:24];4:byte_value=uid0[39:32];5:byte_value=uid0[47:40];
   6:byte_value=uid0[55:48];7:byte_value=uid0[63:56];8:byte_value=uid0[71:64];
   default:byte_value=uid0[79:72];
  endcase
  glyph=raw0?peripheral_label(P_HEX,{2'd0,high0?byte_value[7:4]:byte_value[3:0]}):peripheral_label(label0,position0);
 end
 (* keep="true" *) reg [11:0] font_address;
 reg [15:0] font_word;reg [3:0] bit1,bit2;
 reg [23:0] base0,base1,base2,ink0,ink1,ink2;
 reg region0,region1,region2;reg [2:0] sync0,sync1,sync2;
 always @(posedge clk)font_word<=font[font_address];
 always @(posedge clk)begin
  if(!rst_n)begin
   label0<=0;position0<=0;raw0<=0;high0<=0;uid0<=0;index0<=0;gx0<=0;gy0<=0;
   font_address<=0;bit1<=0;bit2<=0;base0<=0;base1<=0;base2<=0;ink0<=0;ink1<=0;ink2<=0;
   region0<=0;region1<=0;region2<=0;sync0<=0;sync1<=0;sync2<=0;rgb_o<=0;de_o<=0;hs_o<=0;vs_o<=0;
  end else begin
   label0<=label_id;position0<=position;raw0<=raw_mode;high0<=raw_high;uid0<=raw_uid;index0<=raw_index;gx0<=gx;gy0<=gy;
   font_address<={glyph,gy0[4:1]};bit1<=15-gx0[4:1];bit2<=bit1;
   base0<=base;base1<=base0;base2<=base1;ink0<=ink;ink1<=ink0;ink2<=ink1;
   region0<=region;region1<=region0;region2<=region1;
   sync0<={vs_i,hs_i,de_i};sync1<=sync0;sync2<=sync1;{vs_o,hs_o,de_o}<=sync2;
   rgb_o<=!sync2[0]?24'd0:region2&&font_word[bit2]?ink2:base2;
  end
 end
endmodule
`default_nettype wire


