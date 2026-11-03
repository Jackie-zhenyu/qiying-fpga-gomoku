`timescale 1ns/1ps
`default_nettype none
// Read-only overlay on the parent's confirmed physical-game image. State is
// sampled at the incoming VS rising edge. The existing three registered pixel
// stages and the camera viewport [1200,1840)x[192,552) are preserved.
module qy_coach_panel #(parameter FONT_FILE="coach_font.hex")(
 input wire clk,rst_n,
 input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 input wire enable_i,paused_i,review_i,uncertain_i,
 input wire [3:0] fact_i,feedback_i,input wire [1:0] level_i,
 input wire [7:0] own_count_i,opp_count_i,move_i,target_i,
 input wire origin_valid_i,input wire [7:0] origin_index_i,
 input wire [168:0] targets_i,line_i,
 input wire counterexample_valid_i,input wire [31:0] cycles_i,
 input wire [15:0] attempts_i,hints_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 `include "qy_coach_labels.vh"
 reg [31:0] font[0:8191];
 initial $readmemh(FONT_FILE,font);
 localparam [23:0] BG=24'h142632,TEXT=24'he6edf2,MUTED=24'h9dafbd,
  GREEN=24'h68d5ba,CYAN=24'h64ccec,YELLOW=24'hffcf40,RED=24'he4695d;
 reg [11:0] x,y;reg de_d,vs_d;
 wire frame_edge=vs_i&&!vs_d;
 reg enable,paused,review,uncertain,origin_valid,counterexample_valid;
 reg [3:0] fact,feedback;reg [1:0] level;
 reg [7:0] own_count,opp_count,move,target,origin_index;
 reg [168:0] targets,line_mask;
 reg [31:0] cycles;reg [15:0] attempts,hints;
 reg signed [5:0] target_dx,target_dy;
 reg coordinate_update;
 function signed [5:0] relative_x;
  input [7:0] at,anchor;reg signed [5:0] a,b;
  begin a=at%13;b=anchor%13;relative_x=a-b;end
 endfunction
 function signed [5:0] relative_y;
  input [7:0] at,anchor;reg signed [5:0] a,b;
  begin a=at/13;b=anchor/13;relative_y=a-b;end
 endfunction
 always @(posedge clk)begin
  if(!rst_n)begin
   x<=0;y<=0;de_d<=0;vs_d<=0;enable<=0;paused<=0;review<=0;uncertain<=0;
   fact<=0;feedback<=0;level<=0;own_count<=0;opp_count<=0;move<=255;target<=255;
   origin_valid<=0;origin_index<=0;targets<=0;line_mask<=0;target_dx<=0;target_dy<=0;
   counterexample_valid<=0;cycles<=0;attempts<=0;hints<=0;coordinate_update<=0;
  end else begin
   de_d<=de_i;vs_d<=vs_i;coordinate_update<=frame_edge;
   // Work from the captured frame identity, cutting the upstream certificate
   // comparison out of the coordinate arithmetic. Coordinates settle in the
   // blank first line, long before the coordinate labels at y>=592.
   if(coordinate_update)begin target_dx<=relative_x(target,origin_index);target_dy<=relative_y(target,origin_index);end
   if(frame_edge)begin
    x<=0;y<=0;enable<=enable_i;paused<=paused_i;review<=review_i;uncertain<=uncertain_i;
    fact<=fact_i;feedback<=feedback_i;level<=level_i;
    own_count<=own_count_i;opp_count<=opp_count_i;move<=move_i;target<=target_i;
    origin_valid<=origin_valid_i&&origin_index_i<169;origin_index<=origin_index_i;
    targets<=targets_i;line_mask<=line_i;
    counterexample_valid<=counterexample_valid_i;cycles<=cycles_i;attempts<=attempts_i;hints<=hints_i;
   end else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
  end
 end
 // enable_i is supplied only for the human's teaching-key context. A verified
 // previous move's feedback may remain visible during the AI turn. review_i
 // never selects a historical board or bypasses visual uncertainty here.
 wire available=!uncertain;
 wire feedback_valid=available&&feedback>=1&&feedback<=7;
 wire hint_visible=enable&&level!=0;
 wire panel_visible=hint_visible||feedback_valid;
 wire actionable=fact>=1&&fact<=3;
 wire hint_marks=hint_visible&&available&&actionable;
 wire target_verified=target<169&&targets[target];
 wire counter_active=panel_visible&&available&&counterexample_valid&&target_verified;
 wire specific=hint_marks&&level==3&&target_verified;
 wire show_target=counter_active||specific;
 wire coordinate_valid=show_target&&origin_valid;
 reg [3:0] col,row;reg [5:0] dx,dy;reg in_col,in_row;
 integer k;
 always @*begin
  col=0;row=0;dx=63;dy=63;in_col=0;in_row=0;
  for(k=0;k<13;k=k+1)begin
   if(x>=214+k*52&&x<266+k*52)begin
    col=k;in_col=1;dx=x>=240+k*52?x-(240+k*52):(240+k*52)-x;
   end
   if(y>=238+k*52&&y<290+k*52)begin
    row=k;in_row=1;dy=y>=264+k*52?y-(264+k*52):(264+k*52)-y;
   end
  end
 end
 wire [7:0] cell_index=row*13+col;
 wire [5:0] tx=x[10:5],ty=y[10:5];
 reg [23:0] base,ink;
 reg region;reg [7:0] glyph;
 reg [5:0] label_id,position;
 reg digit_region;reg [3:0] digit;
 reg signed [5:0] relative_value;reg [5:0] magnitude;
 reg [5:0] feedback_label;
 always @*begin
  case(feedback)
   1:feedback_label=L_FB1;2:feedback_label=L_FB2;3:feedback_label=L_FB3;
   4:feedback_label=L_FB4;5:feedback_label=L_FB5;6:feedback_label=L_FB6;
   default:feedback_label=L_FB7;
  endcase
 end
 always @*begin
  base=rgb_i;ink=TEXT;region=0;glyph=0;label_id=L_BLANK;position=0;
  digit_region=0;digit=0;relative_value=0;magnitude=0;
  if(panel_visible&&x>=1184&&x<1856&&y>=592&&y<936)begin
   base=BG;region=1;position=tx-38;
   if(x>=1216&&x<1824)begin
    case(ty)
     19:begin label_id=hint_visible?L_TITLE:L_FEEDBACK_TITLE;ink=GREEN;end
     20:begin
      if(uncertain)begin label_id=L_WAIT;ink=YELLOW;end
      else if(!hint_visible)label_id=L_REAL_MOVES;
      else label_id=level==1?L_LEVEL1:level==2?L_LEVEL2:L_LEVEL3;
     end
     21:begin
      if(uncertain)label_id=L_BLANK;
      else if(!hint_visible)begin label_id=feedback_label;ink=feedback<=2?GREEN:feedback<=5?RED:MUTED;end
      else case(fact)
       1:label_id=L_WIN;2:label_id=L_BLOCK;
       3:begin label_id=L_MULTI;ink=YELLOW;end
       4:label_id=L_NONE;5:label_id=L_TERMINAL;6:label_id=L_WAIT;
       7:label_id=L_CALCULATING;default:label_id=L_SCOPE;
      endcase
     end
     22:begin
      if(feedback_valid&&hint_visible)begin label_id=feedback_label;ink=feedback<=2?GREEN:feedback<=5?RED:MUTED;end
      else if(hint_visible&&available)begin
       if(level==1&&actionable)label_id=fact==1?L_HOW_WIN:fact==2?L_HOW_BLOCK:L_HOW_MULTI;
       else if(fact==4)label_id=L_NOT_GUARANTEE;
       else if(hint_marks&&level==2)begin label_id=L_LINE;ink=CYAN;end
       else label_id=L_SCOPE;
      end
     end
     23:if(show_target)begin label_id=counter_active?L_COUNTER:L_TARGET;ink=counter_active?RED:fact==1?GREEN:YELLOW;end
     24:if(show_target)begin
      ink=counter_active?RED:TEXT;
      if(!origin_valid)label_id=L_NO_ORIGIN;
      else begin
       label_id=L_ORIGIN;
       if(tx>=43)begin
        label_id=L_BLANK;position=0;
        relative_value=tx<48?target_dx:target_dy;
        magnitude=relative_value<0?-relative_value:relative_value;
        if(tx==43||tx==48)label_id=tx==43?L_X:L_Y;
        if(tx==44||tx==49)label_id=relative_value<0?L_MINUS:L_PLUS;
        if(tx==45||tx==46||tx==50||tx==51)begin
         digit_region=1;
         digit=(tx==45||tx==50)?(magnitude>=10?1:0):(magnitude>=10?magnitude-10:magnitude);
        end
       end
      end
     end
     25:begin
      if(coordinate_valid)begin label_id=L_DIRECTION;ink=MUTED;end
      else if(available)begin label_id=L_SCOPE;ink=MUTED;end
     end
     26:begin
      if(counter_active)begin label_id=L_COUNTER_LEGEND;ink=RED;end
      else if(hint_marks&&level>=2)begin
       label_id=!specific?L_LINE:fact==1?L_TARGET_WIN:fact==2?L_TARGET_BLOCK:L_TARGET_MULTI;
       ink=!specific?CYAN:fact==1?GREEN:YELLOW;
      end
     end
     27:begin
      ink=MUTED;label_id=tx<48?L_ATTEMPTS:L_HINTS;
      if(tx>=48)position=tx-48;
      if(tx>=43&&tx<=46)begin digit_region=1;digit=attempts>>((46-tx)*4);ink=TEXT;end
      if(tx>=53&&tx<=56)begin digit_region=1;digit=hints>>((56-tx)*4);ink=TEXT;end
     end
     28:begin
      label_id=L_CYCLES;ink=MUTED;
      if(tx>=43&&tx<=50)begin digit_region=1;digit=cycles>>((50-tx)*4);ink=TEXT;end
     end
     default:label_id=L_BLANK;
    endcase
   end else position=63;
  end
  // Only the parent's human-turn enable owns this footer. AI-placement mode
  // retains its original KEY4 target toggle and its original footer pixels.
  if(enable&&x>=64&&x<1856&&y>=1024&&y<1056)begin
   base=BG;ink=MUTED;region=1;position=tx-2;label_id=L_FOOTER;digit_region=0;
  end
  if(region)begin
   glyph=coach_label(label_id,position);
   if(digit_region)glyph=coach_digit(digit);
  end
  if(in_col&&in_row)begin
   // At level 2 no candidate empty intersection is ever outlined. The parent
   // supplies occupied support lines; target exclusions provide a second gate.
   if(hint_marks&&level>=2&&!counter_active&&line_mask[cell_index]&&
      !targets[cell_index]&&cell_index!=target&&dx<=21&&dy<=21&&(dx>=19||dy>=19))base=CYAN;
   // Level 3 adds one certified target, even when the input bitmap has several.
   if(specific&&!counter_active&&cell_index==target&&dx<=24&&dy<=24&&(dx>=22||dy>=22))base=fact==1?GREEN:YELLOW;
   if(counter_active)begin
    if(line_mask[cell_index]&&dx<=21&&dy<=21&&(dx>=19||dy>=19))base=RED;
    if(cell_index==target&&((dx<=24&&dy<=24&&(dx>=22||dy>=22))||(dx<=3&&dy<=3)))base=RED;
   end
  end
 end
 (* keep="true" *) reg [12:0] font_address;
 reg [31:0] font_word;
 reg [4:0] bit0,bit1;
 reg [23:0] base0,base1,ink0,ink1;
 reg region0,region1;reg [2:0] sync0,sync1;
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
