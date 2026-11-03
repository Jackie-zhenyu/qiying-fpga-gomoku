`timescale 1ns/1ps
`default_nettype none
// Teaching-only overlay, replacing both legacy interaction/coach panels.
// Pixel-clock input state is already captured by the parent at the renderer's
// frame commit. This stage captures that matching state at its delayed VS.
// Camera viewport and board pixels pass through except documented markers.
// Latency is three registered stages, with one synchronous 8192x32 font ROM.
module qy_teacher_panel #(
 parameter FONT_FILE="teacher_font.hex"
)(
 input wire clk,rst_n,input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 input wire [2:0] mode_i,pending_mode_i,input wire [3:0] stage_i,
 input wire [1:0] hint_level_i,input wire [168:0] hint_targets_i,
 input wire [7:0] hint_target_i,input wire [3:0] size_i,input wire [1:0] side_i,
 input wire answer_correct_i,retry_valid_i,input wire [7:0] phrase_i,
 input wire camera_ready_i,calibrated_i,calibrating_i,setup_error_i,
 input wire origin_valid_i,input wire [7:0] origin_index_i,
 input wire [16:0] origin_point_i,target_point_i,input wire [67:0] corners_i,
 input wire target_valid_i,input wire [7:0] target_index_i,
 input wire [3:0] game_phase_i,input wire [7:0] move_count_i,input wire nfc_fault_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 `include "qy_teacher_labels.vh"
 localparam IDLE=0,SETUP=1,ACTIVE=2,PAUSED=3,RECHECK=4,ANSWER=5,ERROR=6;
 reg [31:0] font[0:8191];initial $readmemh(FONT_FILE,font);
 reg [11:0] x,y;reg de_d,vs_d;
 wire frame_edge=vs_i&&!vs_d;
 reg [2:0] mode,pending_mode;reg [3:0] stage,board_size,game_phase;
 reg [1:0] hint_level,side;reg [168:0] hint_targets;
 reg [7:0] hint_target,phrase,origin_index,target_index,move_count;
 reg answer_correct,retry_valid,camera_ready,calibrated,calibrating,setup_error;
 reg origin_valid,target_valid,nfc_fault;
 reg [16:0] origin_point,target_point;reg [67:0] corners;
 reg signed [5:0] target_dx,target_dy;
 wire [3:0] incoming_size=size_i>=5&&size_i<=13?size_i:4'd13;
 wire incoming_origin=origin_valid_i&&origin_index_i<169&&
  origin_index_i/13<incoming_size&&origin_index_i%13<incoming_size;
 function signed [5:0] relative_x;
  input [7:0] at,anchor;integer a,b;
  begin a=at%13;b=anchor%13;relative_x=a-b;end
 endfunction
 function signed [5:0] relative_y;
  input [7:0] at,anchor;integer a,b;
  begin a=at/13;b=anchor/13;relative_y=a-b;end
 endfunction
 function [6:0] mode_label;
  input [2:0] selected;
  begin case(selected)
   1:mode_label=T_MODE1;2:mode_label=T_MODE2;3:mode_label=T_MODE3;
   4:mode_label=T_MODE4;default:mode_label=T_PICK;
  endcase end
 endfunction
 always @(posedge clk)begin
  if(!rst_n)begin
   x<=0;y<=0;de_d<=0;vs_d<=0;mode<=0;pending_mode<=0;stage<=IDLE;
   board_size<=13;game_phase<=0;hint_level<=0;side<=1;hint_targets<=0;
   hint_target<=255;phrase<=0;origin_index<=255;target_index<=255;move_count<=0;
   answer_correct<=0;retry_valid<=0;camera_ready<=0;calibrated<=0;calibrating<=0;setup_error<=0;
   origin_valid<=0;target_valid<=0;nfc_fault<=0;origin_point<=0;target_point<=0;corners<=0;
   target_dx<=0;target_dy<=0;
  end else begin
   de_d<=de_i;vs_d<=vs_i;
   if(frame_edge)begin
    x<=0;y<=0;mode<=mode_i;pending_mode<=pending_mode_i;stage<=stage_i;
    board_size<=incoming_size;game_phase<=game_phase_i;hint_level<=hint_level_i;side<=side_i;
    hint_targets<=hint_targets_i;hint_target<=hint_target_i;phrase<=phrase_i;
    origin_index<=origin_index_i;target_index<=target_index_i;move_count<=move_count_i;
    answer_correct<=answer_correct_i;retry_valid<=retry_valid_i;
    camera_ready<=camera_ready_i;calibrated<=calibrated_i;calibrating<=calibrating_i;setup_error<=setup_error_i;
    origin_valid<=incoming_origin;target_valid<=target_valid_i;nfc_fault<=nfc_fault_i;
    origin_point<=origin_point_i;target_point<=target_point_i;corners<=corners_i;
    target_dx<=incoming_origin?relative_x(target_index_i,origin_index_i):6'sd0;
    target_dy<=incoming_origin?relative_y(target_index_i,origin_index_i):6'sd0;
   end else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
  end
 end
 wire active=stage==ACTIVE&&pending_mode==0&&calibrated&&camera_ready&&!calibrating&&!setup_error;
 wire specific=active&&hint_level==2;
 wire ai_place=mode==3&&game_phase==6;
 wire valid_target_index=target_index<169&&target_index/13<board_size&&target_index%13<board_size;
 wire show_target=active&&target_valid&&valid_target_index&&(ai_place||specific);
 wire in_view=de_i&&x>=1200&&x<1840&&y>=192&&y<552;
 wire [5:0] tx=x[10:5],ty=y[10:5];
 // Fixed geometry matches qy_gomoku13_renderer; no 169-way shape replication.
 reg [3:0] col,row;reg [5:0] dx,dy;reg in_col,in_row;
 integer k;
 always @*begin
  col=0;row=0;dx=63;dy=63;in_col=0;in_row=0;
  for(k=0;k<13;k=k+1)begin
   if(k<board_size&&x>=214+k*52&&x<266+k*52)begin
    col=k;in_col=1;dx=x>=240+k*52?x-(240+k*52):(240+k*52)-x;
   end
   if(k<board_size&&y>=238+k*52&&y<290+k*52)begin
    row=k;in_row=1;dy=y>=264+k*52?y-(264+k*52):(264+k*52)-y;
   end
  end
 end
 wire [7:0] cell_index=row*13+col;
 reg [6:0] status_label,message_label,key_label;
 always @*begin
  status_label=T_PICK;message_label=T_WAIT_SELECT;key_label=T_KEYS;
  case(stage)
   SETUP:begin status_label=T_SETUP;message_label=T_SETUP_FILL;end
   ACTIVE:begin
    status_label=side==2?T_YOUR_WHITE:T_YOUR_BLACK;message_label=T_ONE_MOVE;
    if(mode==3)begin
     if(game_phase==0||game_phase==11)begin status_label=T_ORIGIN_CHECK;message_label=T_ONE_BLACK;end
     else if(game_phase==4||game_phase==5)begin status_label=T_THINKING;message_label=T_KEEP_STILL;end
     else if(game_phase==6)begin status_label=T_AI_PLACE;message_label=T_AI_ACCEPT;end
     else if(game_phase==7||game_phase==8)begin status_label=T_VERIFY_MOVE;message_label=T_WAIT_MATCH;end
     else if(game_phase==9)begin status_label=T_GAME_OVER;message_label=T_PICK_KEY;end
     else if(game_phase==10)begin status_label=T_CONFIRM_AGAIN;message_label=T_PICK_KEY;end
    end
   end
   PAUSED:begin status_label=T_PAUSED;message_label=T_RESUME_KEY;key_label=T_KEYS_PAUSED;end
   RECHECK:begin status_label=T_RECHECK;message_label=T_RESTORE;key_label=T_KEYS_RECHECK;end
   ANSWER:begin status_label=answer_correct?T_CORRECT:T_WRONG;message_label=T_NEXT_KEY;key_label=T_KEYS_ANSWER;end
   ERROR:begin status_label=T_CONFIRM_AGAIN;message_label=T_PICK_KEY;end
   default:begin status_label=T_PICK;message_label=T_WAIT_SELECT;end
  endcase
  if(!calibrated)begin status_label=T_ORIGIN_FIRST;message_label=T_ONE_BLACK;key_label=T_KEYS_CAL;end
  if(setup_error)begin status_label=T_CAL_FAILED;message_label=T_CLEAR_HANDS;key_label=T_KEYS_CAL;end
  if(calibrating)begin status_label=T_CALIBRATING;message_label=T_KEEP_STILL;key_label=T_KEYS_CAL;end
  if(!camera_ready)begin status_label=T_CAMERA_WAIT;message_label=T_CAMERA_WAIT;end
  // Mode requests remain visible even when a calibration prerequisite is unmet.
  if(pending_mode!=0)begin
   status_label=T_PENDING;message_label=T_CONFIRM;key_label=T_KEYS_PENDING;
   if(!camera_ready)message_label=T_CAMERA_WAIT;
   else if(calibrating)message_label=T_CAL_AND_WAIT;
   else if(!calibrated||setup_error)message_label=T_CAL_PENDING;
   else if(pending_mode==4&&!retry_valid)message_label=T_NO_RETRY;
  end
 end
 reg region;reg [7:0] glyph;reg [23:0] base,ink;
 reg [6:0] label_id;reg [5:0] position;
 reg number_region;reg [9:0] number;reg [1:0] number_digit;
 reg [2:0] tab_mode;reg [5:0] tab_start;
 reg signed [5:0] relative_value;reg [5:0] magnitude;
 integer m;reg [11:0] mark_x,mark_y,mark_dx,mark_dy;
 always @*begin
  base=rgb_i;ink=24'he6edf2;region=0;glyph=0;label_id=T_BLANK;position=63;
  number_region=0;number=0;number_digit=0;tab_mode=0;tab_start=0;
  relative_value=0;magnitude=0;mark_x=0;mark_y=0;mark_dx=0;mark_dy=0;
  // Fully clear inherited title/status labels before drawing teaching semantics.
  if(x>=64&&x<1856&&y>=32&&y<128)begin
   region=1;base=24'h0c1822;
   if(ty==1)begin
    if(tx<31)begin label_id=T_TITLE;position=tx-2;ink=24'h68d5ba;end
    else begin label_id=status_label;position=tx-32;ink=24'hf4b65d;end
   end
   if(ty==3)begin
    if(tx<16)begin tab_mode=1;tab_start=2;end
    else if(tx<30)begin tab_mode=2;tab_start=16;end
    else if(tx<44)begin tab_mode=3;tab_start=30;end
    else begin tab_mode=4;tab_start=44;end
    label_id=mode_label(tab_mode);position=tx-tab_start-1;
    if(mode==tab_mode)begin base=24'h235a54;ink=24'he6edf2;end
    else ink=24'h9dafbd;
    if(pending_mode==tab_mode)begin base=24'h5b4026;ink=24'hffcf40;end
   end
  end
  if(x>=64&&x<1856&&y>=160&&y<192)begin
   region=1;base=24'h0c1822;
   if(tx<35)begin
    label_id=stage==SETUP?T_SETUP_BOARD:stage==RECHECK?T_RECHECK_BOARD:T_FORMAL_BOARD;
    position=tx-2;ink=stage==SETUP?24'hffcf40:24'he6edf2;
   end else if(tx>=37)begin label_id=T_CAMERA;position=tx-37;ink=24'h9dafbd;end
  end
  // The grid and axis labels end before x928; erase only unused legend space.
  if(x>=928&&x<1120&&y>=240&&y<936)begin
   region=1;base=24'head4aa;ink=24'h25343f;position=tx-29;
   case(ty)
    8:label_id=side==2?T_WHITE:T_BLACK;
    10:label_id=origin_valid?T_ORIGIN_FIXED:T_UNCALIBRATED;
    11:if(origin_valid)label_id=T_ZERO;
    13:label_id=T_SIZE;
    14:begin
     if(tx==29||tx==30||tx==32||tx==33)begin
      number_region=1;number=board_size;number_digit=tx==29||tx==32?1:0;
     end
     if(tx==31)begin label_id=T_TIMES;position=0;end
    end
    17:if(show_target)label_id=T_TARGET;
    19,21:if(show_target)begin
     if(origin_valid)begin
      relative_value=ty==19?target_dx:target_dy;
      magnitude=relative_value<0?-relative_value:relative_value;
      label_id=ty==19?T_X:T_Y;position=tx==29?0:63;
      if(tx==30&&relative_value!=0)begin label_id=relative_value<0?T_MINUS:T_PLUS;position=0;end
      if(tx==31&&magnitude>=10)begin number_region=1;number=magnitude;number_digit=1;end
      if(tx==32)begin number_region=1;number=magnitude;number_digit=0;end
      if(tx==33)begin label_id=T_CELL;position=0;end
     end
    end
    24:label_id=mode==3?T_COUNT:T_CHECK_BOARD;
    26:begin
     if(mode==3&&tx>=29&&tx<=31)begin number_region=1;number=move_count;number_digit=31-tx;end
     else if(mode!=3)label_id=T_SINGLE_ANSWER;
    end
    default:label_id=T_BLANK;
   endcase
  end
  // Leave y560..591 untouched: it contains the camera bring-up diagnostic.
  if(x>=1184&&x<1856&&y>=592&&y<952)begin
   region=1;base=24'h142632;ink=24'he6edf2;label_id=T_BLANK;position=tx-38;
   if(x>=1216&&x<1824)begin
    if(ty==19)begin label_id=status_label;ink=24'h68d5ba;end
    else if(pending_mode!=0)begin
     case(ty)
      20:begin label_id=mode_label(pending_mode);ink=24'hffcf40;end
      22:label_id=message_label;
      24:label_id=T_PENDING_HOLD;
      26:if(!calibrated)label_id=T_ONE_BLACK;
      27:if(!calibrated)label_id=T_AFTER_ORIGIN;
      default:label_id=T_BLANK;
     endcase
    end else if(!camera_ready)begin
     if(ty==21)label_id=T_CAMERA_WAIT;
    end else if(calibrating||!calibrated||setup_error)begin
     case(ty)
      21:label_id=T_ONE_BLACK;
      22:label_id=calibrating?T_KEEP_STILL:T_CAL_KEY;
      24:label_id=T_ORIGIN_ZERO;
      26:label_id=T_AFTER_ORIGIN;
      default:label_id=T_BLANK;
     endcase
    end else case(stage)
     SETUP:case(ty)
      21:label_id=T_KEEP_ORIGIN;22:label_id=T_SETUP_FILL;
      24:label_id=T_WAIT_MATCH;25:label_id=T_SETUP_READY;
      27:begin label_id=T_SETUP_NOTE;ink=24'hffcf40;end
      default:label_id=T_BLANK;
     endcase
     ACTIVE:case(ty)
      20:label_id=message_label;
      22:begin
       if(hint_level==0)label_id=T_HINT_OFF;
       else if(hint_level==1)label_id=mode==1?T_HINT_OWN:mode==2?T_HINT_OPP:T_HINT_GENERAL;
       else label_id=hint_targets!=0?T_HINT_DETAIL:T_NO_DETAIL;
      end
      23:if(hint_level==1)label_id=T_DIRECTION_NOTE;
      24:if(show_target&&origin_valid)label_id=T_AXIS_NOTE;
      25:if(ai_place)label_id=T_AI_ACCEPT;
      26:if(phrase==23)begin label_id=T_OBS_WAIT;ink=24'hf4b65d;end
      28:if(retry_valid)label_id=T_RETRY_SAVED;
      default:label_id=T_BLANK;
     endcase
     PAUSED:case(ty)
      21:label_id=T_RESUME_KEY;23:label_id=T_RECAL_KEY;
      25:label_id=T_CLEAR_HANDS;27:label_id=T_KEEP_ORIGIN;
      default:label_id=T_BLANK;
     endcase
     RECHECK:case(ty)
      21:label_id=T_RESTORE;22:label_id=T_KEEP_ORIGIN;
      24:label_id=T_RECHECK_READY;26:label_id=T_RECHECK_HOLD;
      default:label_id=T_BLANK;
     endcase
     ANSWER:case(ty)
      21:label_id=T_NEXT_KEY;23:if(!answer_correct&&retry_valid)label_id=T_SAVED_NOTE;
      25:label_id=T_PICK_KEY;default:label_id=T_BLANK;
     endcase
     default:case(ty)
      21:label_id=T_PICK_KEY;23:label_id=T_CONFIRM;
      default:label_id=T_BLANK;
     endcase
    endcase
   end
  end
  if(x>=64&&x<1856&&y>=960&&y<1056)begin
   region=1;base=24'h142632;position=tx-2;label_id=T_BLANK;ink=24'he6edf2;
   if(ty==30)begin label_id=message_label;ink=24'hf4b65d;end
   if(ty==31)begin
    label_id=nfc_fault?T_NFC_FAULT:origin_valid?T_AXIS_NOTE:T_AFTER_ORIGIN;
    ink=nfc_fault?24'hf4b65d:24'h9dafbd;
   end
   if(ty==32)begin label_id=key_label;ink=24'h9dafbd;end
  end
  if(region)begin
   glyph=teacher_label(label_id,position);
   if(number_region)glyph=teacher_digit(number_digit==2?number/100:number_digit==1?(number/10)%10:number%10);
  end
  // Exact hint squares never appear in setup, pending, pause or recheck.
  if(in_col&&in_row&&specific&&hint_targets[cell_index]&&dx<=24&&dy<=24&&(dx>=22||dy>=22))base=24'h68d5ba;
  if(in_view&&camera_ready&&calibrated)begin
   for(m=0;m<4;m=m+1)begin
    if(corners[m*17+:9]<320&&corners[m*17+9+:8]<180)begin
     mark_x=1200+{2'd0,corners[m*17+:9],1'b0};mark_y=192+{3'd0,corners[m*17+9+:8],1'b0};
     if((x+8>=mark_x&&x<=mark_x+8&&y+1>=mark_y&&y<=mark_y+1)||
        (y+8>=mark_y&&y<=mark_y+8&&x+1>=mark_x&&x<=mark_x+1))base=24'h68d5ba;
    end
   end
   if(show_target&&target_point[8:0]<320&&target_point[16:9]<180)begin
    mark_x=1200+{2'd0,target_point[8:0],1'b0};mark_y=192+{3'd0,target_point[16:9],1'b0};
    if((x+10>=mark_x&&x<=mark_x+10&&y+1>=mark_y&&y<=mark_y+1)||
       (y+10>=mark_y&&y<=mark_y+10&&x+1>=mark_x&&x<=mark_x+1))base=ai_place?24'h43e9ff:24'h68d5ba;
   end
   if(origin_valid&&origin_point[8:0]<320&&origin_point[16:9]<180)begin
    mark_x=1200+{2'd0,origin_point[8:0],1'b0};mark_y=192+{3'd0,origin_point[16:9],1'b0};
    mark_dx=x>=mark_x?x-mark_x:mark_x-x;mark_dy=y>=mark_y?y-mark_y:mark_y-y;
    if((mark_dx>=11&&mark_dx<=14&&mark_dy>=8&&mark_dy<=14)||
       (mark_dy>=11&&mark_dy<=14&&mark_dx>=8&&mark_dx<=14))base=24'h68d5ba;
   end
  end
 end
 (* keep="true" *) reg [12:0] font_address;
 reg [31:0] font_word;reg [4:0] bit0,bit1;
 reg [23:0] base0,base1,ink0,ink1;reg region0,region1;reg [2:0] sync0,sync1;
 always @(posedge clk)font_word<=font[font_address];
 always @(posedge clk)begin
  if(!rst_n)begin
   font_address<=0;bit0<=0;bit1<=0;base0<=0;base1<=0;ink0<=0;ink1<=0;
   region0<=0;region1<=0;sync0<=0;sync1<=0;rgb_o<=0;de_o<=0;hs_o<=0;vs_o<=0;
  end else begin
   font_address<={glyph,y[4:0]};bit0<=31-x[4:0];bit1<=bit0;
   base0<=base;base1<=base0;ink0<=ink;ink1<=ink0;region0<=region;region1<=region0;
   sync0<={vs_i,hs_i,de_i};sync1<=sync0;{vs_o,hs_o,de_o}<=sync1;
   rgb_o<=!sync1[0]?24'd0:region1&&font_word[bit1]?ink1:base1;
  end
 end
endmodule
`default_nettype wire
