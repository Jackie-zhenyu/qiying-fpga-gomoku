`timescale 1ns/1ps
`default_nettype none
// Physical-key save/view transaction. All signals share the video clock.
// The formal game is paused before entry. Its state is copied on the same edge
// that observes completion of a whole frozen thumbnail. Loaded data is display-only.
module qy_storage_session #(parameter CLK_HZ=137500000)(
 input wire clk,rst_n,game_active,replay_active,input wire [3:0] key_press,
 input wire [2:0] game_mode,input wire camera_ready,calibrated,fault,
 input wire [3:0] phase,board_size,input wire [337:0] board,
 input wire [7:0] moves,last_index,origin_index,input wire [1:0] human,next_color,winner,
 input wire last_valid,game_over,draw,origin_valid,
 input wire [1351:0] history,
 input wire initialized,input wire [7:0] init_error,input wire [3:0] slot_valid,
 output reg [1:0] selected,output reg [3:0] ui_state,output reg [7:0] error,
 output wire busy,intercept,preview,
 output wire freeze_request,input wire frozen,input wire [31:0] frozen_frame,
 output reg dump_start,load_begin,load_commit,load_abort,
 output wire save_valid,input wire save_ready,output reg [2015:0] save_metadata,
 output wire load_valid,input wire load_ready,
 input wire done_valid,output wire done_ready,input wire [7:0] done_error
);
 localparam OFF=0,SAVE_SELECT=1,FREEZE=2,SAVE_COMMAND=3,SAVE_WAIT=4,SAVED=5,
  ERROR=6,LOAD_SELECT=7,LOAD_COMMAND=8,LOAD_WAIT=9,VIEW=10;
 reg [31:0] wait_count;reg was_replay;
 wire stable=phase!=0&&phase!=1&&phase!=7&&phase!=8&&phase!=10&&phase!=11;
 wire eligible=game_mode==4&&calibrated&&camera_ready&&!fault&&stable&&moves!=0;
 assign intercept=ui_state!=OFF||replay_active;
 assign preview=replay_active;
 assign busy=ui_state==FREEZE||ui_state==SAVE_COMMAND||ui_state==SAVE_WAIT||ui_state==LOAD_COMMAND||ui_state==LOAD_WAIT;
 assign freeze_request=ui_state==FREEZE||ui_state==SAVE_COMMAND||ui_state==SAVE_WAIT||ui_state==SAVED||replay_active;
 assign save_valid=ui_state==SAVE_COMMAND;
 assign load_valid=ui_state==LOAD_COMMAND;
 assign done_ready=ui_state==SAVE_WAIT||ui_state==LOAD_WAIT;
 integer j;
 always @(posedge clk)begin
  if(!rst_n)begin
   ui_state<=OFF;selected<=0;error<=0;wait_count<=0;was_replay<=0;
   dump_start<=0;load_begin<=0;load_commit<=0;load_abort<=0;save_metadata<=0;
  end else begin
   dump_start<=0;load_begin<=0;load_commit<=0;load_abort<=0;was_replay<=replay_active;
   if(!game_active&&!replay_active&&!busy)begin ui_state<=OFF;error<=0;end
   else if(replay_active&&!was_replay)begin ui_state<=LOAD_SELECT;selected<=0;error<=0;load_abort<=1;end
   else case(ui_state)
    OFF:if(game_active&&game_mode==4&&key_press[1])begin
     selected<=0;error<=0;
     if(eligible)ui_state<=SAVE_SELECT;else begin ui_state<=ERROR;error<=8'h30;end
    end
    SAVE_SELECT,LOAD_SELECT:begin
     if(key_press[0])begin if(ui_state==SAVE_SELECT)ui_state<=OFF;end
     else if(key_press[1])selected<=selected-1'b1;
     else if(key_press[2])selected<=selected+1'b1;
     else if(key_press[3])begin
      if(!initialized)begin ui_state<=ERROR;error<=init_error!=0?init_error:8'h31;end
      else if(ui_state==LOAD_SELECT)begin
       if(!slot_valid[selected])begin ui_state<=ERROR;error<=8'h13;end
       else begin load_begin<=1;ui_state<=LOAD_COMMAND;end
      end else if(!eligible)begin ui_state<=ERROR;error<=8'h30;end
      else begin ui_state<=FREEZE;wait_count<=0;end
     end
    end
    FREEZE:begin
     if(!eligible)begin ui_state<=ERROR;error<=8'h30;end
     else if(frozen)begin
      save_metadata<=0;
      save_metadata[9*8+:8]<={4'd0,board_size};save_metadata[10*8+:8]<={6'd0,human};
      save_metadata[11*8+:8]<={6'd0,next_color};save_metadata[12*8+:8]<=moves;
      save_metadata[13*8+:8]<=last_index;
      save_metadata[14*8+:8]<={4'd0,origin_valid,draw,game_over,last_valid};
      save_metadata[15*8+:8]<=origin_valid?origin_index:8'hff;
      save_metadata[20*8+:32]<=frozen_frame;
      save_metadata[32*8+:338]<=board;save_metadata[75*8+:8]<={6'd0,winner};
      save_metadata[76*8+:1352]<=history;
      dump_start<=1;ui_state<=SAVE_COMMAND;
     end else if(wait_count>=CLK_HZ*2-1)begin ui_state<=ERROR;error<=8'h32;end
     else wait_count<=wait_count+1'b1;
    end
    SAVE_COMMAND:if(save_ready)ui_state<=SAVE_WAIT;
    SAVE_WAIT:if(done_valid)begin error<=done_error;ui_state<=done_error==0?SAVED:ERROR;end
    SAVED:if(key_press[0]||key_press[3])ui_state<=OFF;
    ERROR:if(key_press[0]||key_press[3])begin ui_state<=replay_active?LOAD_SELECT:OFF;error<=0;load_abort<=1;end
    LOAD_COMMAND:if(load_ready)ui_state<=LOAD_WAIT;
    LOAD_WAIT:if(done_valid)begin
     error<=done_error;
     if(done_error==0)begin load_commit<=1;ui_state<=VIEW;end
     else begin load_abort<=1;ui_state<=ERROR;end
    end
    VIEW:begin
     if(key_press[0]||key_press[3])begin ui_state<=LOAD_SELECT;load_abort<=1;end
     else if(key_press[1]||key_press[2])begin
      selected<=key_press[1]?selected-1'b1:selected+1'b1;ui_state<=LOAD_SELECT;load_abort<=1;
     end
    end
    default:begin ui_state<=OFF;error<=8'hff;end
   endcase
  end
 end
endmodule
`default_nettype wire
