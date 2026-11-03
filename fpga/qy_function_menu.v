`timescale 1ns/1ps
`default_nettype none
// Physical keys are decoded once. Entry and exit commit at vertical blank.
module qy_function_menu #(
 parameter CLK_HZ=137500000, DEBOUNCE_MS=20, RETURN_MS=2000
)(
 input wire clk,rst_n,frame_tick,input wire [3:0] keys_n,input wire lock_exit,
 input wire navigate_valid,navigate_replay,home_request,
 output reg game_active,replay_active,output reg [0:0] selected,
 output reg [3:0] game_press,output wire [3:0] game_held,
 output reg settings_active,output reg [3:0] settings_press,output wire physical_key,
 output reg navigation_done,navigation_home
);
 wire [3:0] armed,held,press,release_key;
 qy_key_frontend #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(DEBOUNCE_MS)) keys(
  .clk_i(clk),.arst_n_i(rst_n),.key_i(keys_n),.armed_o(armed),
  .pressed_o(held),.press_pulse_o(press),.release_pulse_o(release_key));
 localparam [63:0] RETURN_CYCLES=(64'd1*CLK_HZ*RETURN_MS+999)/1000;
 localparam HOME=0,ENTER_RELEASE=1,PLAY=2,EXIT_RELEASE=3,SETTINGS_RELEASE=4,SETTINGS=5;
 reg [2:0] state;
 reg [63:0] hold_count;
 reg key1_pending,exit_pending;
 reg nav_pending,nav_selected,home_pending;
 assign physical_key=|press||(|held)||key1_pending||exit_pending;
 assign game_held=state==PLAY&&!exit_pending?{held[3:1],1'b0}:4'd0;
 always @(posedge clk) begin
  if(!rst_n)begin state<=HOME;game_active<=0;replay_active<=0;settings_active<=0;settings_press<=0;selected<=0;game_press<=0;hold_count<=0;key1_pending<=0;exit_pending<=0;nav_pending<=0;nav_selected<=0;home_pending<=0;navigation_done<=0;navigation_home<=0;end
  else begin
   game_press<=0;settings_press<=0;navigation_done<=0;navigation_home<=0;
   if((navigate_valid||home_request)&&!lock_exit&&!physical_key&&(state==HOME||state==PLAY))begin
    nav_pending<=navigate_valid;nav_selected<=navigate_replay;home_pending<=home_request;
   end
   if(physical_key||lock_exit||(state!=HOME&&state!=PLAY))begin nav_pending<=0;home_pending<=0;end
   case(state)
    HOME:begin
     hold_count<=0;key1_pending<=0;exit_pending<=0;
     if(armed==4'hf&&((press==2&&held==2)||(press==4&&held==4)))selected<=!selected;
     if(armed==4'hf&&press==4'b1000&&held==4'b1000)state<=ENTER_RELEASE;
     else if(armed==4'hf&&press==4'b0001&&held==4'b0001)state<=SETTINGS_RELEASE;
    end
    ENTER_RELEASE:begin
     if(held==0&&armed==4'hf&&frame_tick)begin game_active<=!selected;replay_active<=selected;state<=PLAY;end
    end
    PLAY:begin
     // A short KEY1 is delivered on release. Long KEY1 belongs only to home.
     if(press[0]&&held==1)begin key1_pending<=1;hold_count<=0;end
     if(key1_pending&&held==1&&!exit_pending)begin
      if(hold_count>=RETURN_CYCLES-1)begin exit_pending<=1;key1_pending<=0;end
      else hold_count<=hold_count+1'b1;
     end
     if(key1_pending&&held!=0&&held!=1)begin key1_pending<=0;hold_count<=0;end
     if(release_key[0]&&key1_pending&&!exit_pending)begin game_press<=4'b0001;key1_pending<=0;hold_count<=0;end
     if(!held[0]&&!exit_pending)begin
      if(held==2||held==4||held==8)game_press<=press&4'b1110;
     end
     if(exit_pending&&frame_tick&&!lock_exit)begin game_active<=0;replay_active<=0;game_press<=0;state<=EXIT_RELEASE;end
    end
    EXIT_RELEASE:if(held==0&&armed==4'hf)begin state<=HOME;exit_pending<=0;end
    SETTINGS_RELEASE:if(held==0&&armed==4'hf&&frame_tick)begin settings_active<=1;state<=SETTINGS;end
    SETTINGS:begin
     if(!lock_exit)begin
      if(!exit_pending&&(held==1||held==2||held==4||held==8))settings_press<=press;
      if(press==1&&held==1)exit_pending<=1;
      if(exit_pending&&frame_tick)begin settings_active<=0;settings_press<=0;state<=EXIT_RELEASE;end
     end
    end
    default:begin state<=HOME;game_active<=0;replay_active<=0;key1_pending<=0;exit_pending<=0;end
   endcase
   if(frame_tick&&(nav_pending||home_pending)&&!lock_exit&&!physical_key&&
      (state==HOME||state==PLAY))begin
    game_active<=0;replay_active<=0;settings_active<=0;state<=HOME;
    navigation_done<=1;navigation_home<=home_pending&&!nav_pending;
    if(nav_pending)selected<=nav_selected;
    game_press<=0;nav_pending<=0;home_pending<=0;key1_pending<=0;hold_count<=0;exit_pending<=0;
   end
  end
 end
endmodule
`default_nettype wire
