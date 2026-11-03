`timescale 1ns/1ps
`default_nettype none
// Frame-coherent instructions and physical-placement markers. Board and both
// accepted camera windows remain in the underlying pixel stream.
module qy_interaction_panel #(
 parameter AUTO_SIZE=0, parameter ORIGIN_OPENING=0, parameter PRECOMPUTED_CAMERA_POINTS=0,
 parameter FONT_FILE="assets/interaction/interaction_font.hex"
)(
 input wire clk,rst_n,camera_ready,input wire [23:0] rgb_i,input wire de_i,hs_i,vs_i,
 input wire [3:0] board_size_i,
 input wire [2:0] mode_i,field_i,input wire [8:0] field_value_i,
 input wire [3:0] phase_i,input wire [7:0] reason_i,move_count_i,
 input wire [1:0] human_color_i,winner_i,input wire draw_i,fault_i,calibrated_i,setup_error_i,
 input wire target_valid_i,show_target_i,input wire [7:0] target_index_i,
 input wire origin_valid_i,origin_pending_i,input wire [7:0] origin_index_i,
 // Current followed camera points, already computed in this pixel clock domain.
 // {y[7:0],x[8:0]} in the 320x180 camera sample coordinate system.
 input wire [16:0] target_point_i,origin_point_i,
 input wire [67:0] corners_i,input wire [2872:0] points_i,
 output reg [23:0] rgb_o,output reg de_o,hs_o,vs_o
);
 `include "qy_interaction_labels.vh"
 reg [31:0] font[0:8191];initial $readmemh(FONT_FILE,font);
 reg [11:0] x,y;reg de_d,vs_d;
 wire frame_edge=vs_i&&!vs_d;
 reg [3:0] board_size;
 reg [2:0] mode,field;reg [8:0] field_value;reg [3:0] phase;
 reg [7:0] reason,move_count,target_index;reg [1:0] human_color,winner;
 reg draw,fault,calibrated,setup_error,target_valid,show_target,ready;
 reg origin_valid,origin_pending;reg [7:0] origin_index;
 reg signed [5:0] target_dx,target_dy;
 reg coordinate_update;
 wire [3:0] incoming_size=AUTO_SIZE?board_size_i:4'd13;
 wire incoming_origin_valid=ORIGIN_OPENING&&origin_valid_i&&origin_index_i<169&&
  origin_index_i/13<incoming_size&&origin_index_i%13<incoming_size;
 reg [67:0] corners;reg [16:0] target_point,origin_point;
 always @(posedge clk)begin
  if(!rst_n)begin
   x<=0;y<=0;de_d<=0;vs_d<=0;mode<=1;field<=0;field_value<=0;phase<=0;
   reason<=0;move_count<=0;target_index<=0;human_color<=1;winner<=0;
   draw<=0;fault<=0;calibrated<=0;setup_error<=0;target_valid<=0;show_target<=1;ready<=0;
   corners<=0;target_point<=0;origin_point<=0;board_size<=13;
    origin_valid<=0;origin_pending<=0;origin_index<=0;target_dx<=0;target_dy<=0;coordinate_update<=0;
  end else begin
   de_d<=de_i;vs_d<=vs_i;coordinate_update<=frame_edge;
   if(coordinate_update)begin
    target_dx<=origin_valid?relative_x(target_index,origin_index):6'sd0;
    target_dy<=origin_valid?relative_y(target_index,origin_index):6'sd0;
   end
   if(frame_edge)begin
    board_size<=AUTO_SIZE?board_size_i:4'd13;x<=0;y<=0;mode<=mode_i;field<=field_i;field_value<=field_value_i;phase<=phase_i;
    reason<=reason_i;move_count<=move_count_i;target_index<=target_index_i;human_color<=human_color_i;
    winner<=winner_i;draw<=draw_i;fault<=fault_i;calibrated<=calibrated_i;setup_error<=setup_error_i;
    target_valid<=target_valid_i&&target_index_i<169&&mode_i==0;show_target<=show_target_i;ready<=camera_ready;
    corners<=corners_i;
    target_point<=(PRECOMPUTED_CAMERA_POINTS||incoming_origin_valid)?target_point_i:
     target_index_i<169?points_i[target_index_i*17+:17]:17'd0;
    origin_point<=incoming_origin_valid?origin_point_i:17'd0;
     origin_valid<=incoming_origin_valid;origin_pending<=ORIGIN_OPENING&&origin_pending_i;
     origin_index<=incoming_origin_valid?origin_index_i:8'd0;
     // Integer temporaries are signed; unsigned index subtraction must not wrap.
   end else if(de_i)begin if(x<4095)x<=x+1'b1;end
   else begin x<=0;if(de_d&&y<4095)y<=y+1'b1;end
  end
 end
 function signed [5:0] relative_x;
  input [7:0] at,anchor;integer a,b;
  begin a=at%13;b=anchor%13;relative_x=a-b;end
 endfunction
 function signed [5:0] relative_y;
  input [7:0] at,anchor;integer a,b;
  begin a=at/13;b=anchor/13;relative_y=a-b;end
 endfunction
 reg [6:0] message_label,key_label,status_label,phase_label;
 reg [6:0] message_next,key_next,status_next,phase_next;
 always @* begin
  key_next=32;status_next=calibrated?57:59;
  phase_next=phase==0?6:phase==3?(human_color==1?7:8):phase==4||phase==5?9:
   phase==6?(human_color==1?10:11):phase==9?13:phase==10?14:12;
  message_next=phase==0?19:phase==3?(human_color==1?20:21):phase==4||phase==5?22:
   phase==6?(human_color==1?23:24):phase==9?30:phase==10?31:25;
  if((phase==3||phase==6)&&reason>=3&&reason<=9)message_next=26;
  if(phase==6&&reason==32)message_next=27;
  if(mode==1)begin message_next=AUTO_SIZE?61:15;key_next=AUTO_SIZE?62:33;status_next=56;end
  if(mode==2)begin message_next=16;key_next=34;status_next=56;end
  if(mode==3)begin message_next=29;key_next=36;status_next=58;end
  if(mode==4)begin message_next=28;key_next=35;status_next=58;end
  if(mode==5)begin message_next=AUTO_SIZE?63:17;key_next=0;status_next=56;end
   if(ORIGIN_OPENING&&human_color==1)begin
    if(mode==1)begin message_next=67;key_next=68;status_next=66;end
    if(mode==5||phase==11||origin_pending)begin
     message_next=69;phase_next=71;status_next=71;
     if(mode==5)key_next=0;
    end
   end
  if(setup_error)message_next=mode==0?60:(AUTO_SIZE?64:18);
   if(setup_error&&ORIGIN_OPENING&&human_color==1&&mode!=0)message_next=70;
  if(fault)message_next=31;
  if(!ready)message_next=55;
 end
 // Labels use only the captured frame state and settle in the blank first
 // line. This cuts phase decoding out of the pixel-to-font-address path while
 // preserving the three existing registered pixel stages and active pixels.
 always @(posedge clk)begin
  if(!rst_n)begin message_label<=55;key_label<=32;status_label<=59;phase_label<=6;end
  else begin message_label<=message_next;key_label<=key_next;status_label<=status_next;phase_label<=phase_next;end
 end
 wire in_view=de_i&&x>=1200&&x<1840&&y>=192&&y<552;
 wire [5:0] tx=x[10:5],ty=y[10:5];
 reg region;reg [7:0] glyph;reg [23:0] base,ink;
 reg [6:0] label_id;reg [5:0] position;reg [9:0] number;
 reg number_region;reg [1:0] number_digit;
 reg signed [5:0] relative_value;reg [4:0] relative_magnitude;
 integer k;reg [11:0] mark_x,mark_y,origin_marker_dx,origin_marker_dy;reg selected_mark;
 always @* begin
  region=0;glyph=0;base=rgb_i;ink=24'he6edf2;label_id=0;position=0;
  number=0;number_region=0;number_digit=0;mark_x=0;mark_y=0;selected_mark=0;
  origin_marker_dx=0;origin_marker_dy=0;
   relative_value=0;relative_magnitude=0;
  if(tx>=2&&tx<38&&ty==1)begin region=1;label_id=0;position=tx-2;ink=24'h68d5ba;base=24'h0c1822;end
  if(tx>=2&&tx<35&&ty==3)begin region=1;label_id=status_label;position=tx-2;ink=calibrated?24'h68d5ba:24'hf4b65d;base=24'h0c1822;end
  if(tx>=2&&tx<35&&ty==5)begin region=1;label_id=1;position=tx-2;base=24'h0c1822;end
  // Erase inherited recommendation legends in the board's unused right margin.
  if(tx>=29&&tx<35&&y>=240&&y<936)begin
   region=1;label_id=0;position=63;base=24'head4aa;ink=24'h25343f;
   if(ty==8)begin label_id=human_color==1?2:3;position=tx-29;end
   if(ty==10)begin label_id=human_color==1?4:5;position=tx-29;end
    if(ty==11&&ORIGIN_OPENING&&origin_valid)begin label_id=79;position=tx-29;ink=24'h68d5ba;end
   if(ty==15&&AUTO_SIZE&&calibrated)begin
    if(tx==29||tx==30||tx==32||tx==33)begin number_region=1;number=board_size;number_digit=(tx==29||tx==32)?1:0;end
    if(tx==31)begin glyph=0;label_id=65;position=0;end
   end
   if(ty==13)begin label_id=phase_label;position=tx-29;end
   if(ty==17&&target_valid)begin label_id=45;position=tx-29;ink=human_color==1?24'h198ba9:24'he29128;end
   if((ty==19||ty==21)&&target_valid)begin
     if(ORIGIN_OPENING&&origin_valid)begin
      // Horizontal x first, vertical y second. Zero has no direction/sign.
      relative_value=ty==19?target_dx:target_dy;
      relative_magnitude=relative_value<0?-relative_value:relative_value;
      label_id=ty==19?72:73;position=tx==29?0:63;
      if(tx==30&&relative_value!=0)begin label_id=relative_value<0?81:80;position=0;end
      if(tx==31&&relative_magnitude>=10)begin number_region=1;number=relative_magnitude;number_digit=1;end
      if(tx==32)begin number_region=1;number=relative_magnitude;number_digit=0;end
      if(tx==33)begin label_id=78;position=0;end
     end else begin
      label_id=tx==29?46:ty==19?47:48;position=0;
      if(tx==30||tx==31)begin number_region=1;number=ty==19?target_index/13+1:target_index%13+1;number_digit=tx==30?1:0;end
      if(tx>=33)position=63;
     end
   end
   if(ty==24)begin label_id=50;position=tx-29;end
   if(ty==26)begin
    label_id=tx==29?46:49;position=0;
    if(tx>=30&&tx<=32)begin number_region=1;number=move_count;number_digit=32-tx;end
    if(tx>=34)position=63;
   end
   if(ty==28)begin label_id=winner==1?52:winner==2?53:draw?54:51;position=tx-29;end
  end
  if(y>=960&&y<1056&&x>=64&&x<1856)begin
   region=1;base=24'h142632;position=tx-2;label_id=0;
   if(ty==30)begin label_id=message_label;ink=(message_label==18||message_label==26||message_label==27||message_label==31||message_label==55)?24'hf4b65d:24'he6edf2;end
   else if(ty==31)begin
    label_id=mode==2?37+{4'd0,field}:0;
    if(mode!=2)position=63;
    if(mode==2&&tx>=12&&tx<=14)begin number_region=1;number=field_value;number_digit=14-tx;end
   end else begin label_id=key_label;ink=24'h9dafbd;if(mode==5)position=63;end
  end
  if(region)begin
   glyph=interaction_label(label_id,position);
   if(number_region)glyph=interaction_digit(number_digit==2?number/100:number_digit==1?(number/10)%10:number%10);
  end
  // Proposal corners are always visible during setup; amber selects the field.
  if(in_view&&(AUTO_SIZE?calibrated:(mode==1||mode==2||mode==5)))begin
   for(k=0;k<4;k=k+1)begin
    mark_x=1200+{2'd0,corners[k*17+:9],1'b0};mark_y=192+{3'd0,corners[k*17+9+:8],1'b0};
    selected_mark=mode==2&&field[2:1]==k;
    if((x+8>=mark_x&&x<=mark_x+8&&y+1>=mark_y&&y<=mark_y+1)||
       (y+8>=mark_y&&y<=mark_y+8&&x+1>=mark_x&&x<=mark_x+1))base=selected_mark?24'hffcf40:24'h68d5ba;
   end
  end
  if(in_view&&target_valid&&show_target&&calibrated&&mode==0)begin
   mark_x=1200+{2'd0,target_point[8:0],1'b0};mark_y=192+{3'd0,target_point[16:9],1'b0};
   if((x+10>=mark_x&&x<=mark_x+10&&y+1>=mark_y&&y<=mark_y+1)||
      (y+10>=mark_y&&y<=mark_y+10&&x+1>=mark_x&&x<=mark_x+1))base=human_color==1?24'h43e9ff:24'hffcf40;
  end
  // Fixed origin identity, current followed camera location. The bracket is
  // independent of target visibility and does not move to the latest stone.
  if(in_view&&ORIGIN_OPENING&&origin_valid&&calibrated)begin
   mark_x=1200+{2'd0,origin_point[8:0],1'b0};mark_y=192+{3'd0,origin_point[16:9],1'b0};
   origin_marker_dx=x>=mark_x?x-mark_x:mark_x-x;
   origin_marker_dy=y>=mark_y?y-mark_y:mark_y-y;
   if((origin_marker_dx>=11&&origin_marker_dx<=14&&origin_marker_dy>=8&&origin_marker_dy<=14)||
      (origin_marker_dy>=11&&origin_marker_dy<=14&&origin_marker_dx>=8&&origin_marker_dx<=14))base=24'h68d5ba;
  end
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
   font_address<={glyph,y[4:0]};bit0<=31-x[4:0];bit1<=bit0;
   base0<=base;base1<=base0;ink0<=ink;ink1<=ink0;region0<=region;region1<=region0;
   sync0<={vs_i,hs_i,de_i};sync1<=sync0;{vs_o,hs_o,de_o}<=sync1;
   rgb_o<=!sync1[0]?24'd0:region1&&font_word[bit1]?ink1:base1;
  end
 end
endmodule
`default_nettype wire
