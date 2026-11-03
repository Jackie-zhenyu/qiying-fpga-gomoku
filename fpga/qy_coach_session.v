`timescale 1ns/1ps
`default_nettype none
// Read-only adjunct: only an exact accepted formal human move creates answers.
module qy_coach_session(
 input wire clk,rst_n,new_game,
 input wire [337:0] board_i,input wire [31:0] version_i,
 input wire [3:0] size_i,phase_i,input wire [1:0] human_i,next_i,
 input wire [7:0] move_count_i,input wire [2:0] mode_i,
 input wire safe_i,input wire hint_press_i,review_press_i,
 input wire event_valid_i,event_is_ai_i,input wire [7:0] event_index_i,input wire [1:0] event_color_i,
 output reg [1:0] level_o,output wire [3:0] fact_o,output reg [3:0] feedback_o,
 output wire [7:0] own_count_o,opp_count_o,target_o,
 output wire [168:0] targets_o,line_o,
 output wire uncertain_o,output wire review_o,output reg review_valid_o,
 output wire [337:0] display_board_o,output wire [7:0] review_move_o,
 output wire [7:0] review_number_o,output wire [3:0] display_feedback_o,
 output wire [1:0] display_level_o,
 output wire counterexample_valid_o,output wire [7:0] counterexample_index_o,
 output wire [168:0] counterexample_line_o,
 output reg answer_valid_o,answer_correct_o,
 output reg [31:0] tactics_cycles_o,
 output reg [15:0] attempts_o,hints_o
);
 reg start,review_requested,requested,scan_attempted,scan_failed,event_wait;
 wire busy,done,valid,terminal_own,terminal_opp,tactic_error;
 wire [31:0] result_version;
 wire [168:0] own_wins,opp_wins,own_line,opp_line;
 wire [7:0] own_count,opp_count,own_first,opp_first;
 reg cert_valid;reg [337:0] cert_board;reg [31:0] cert_version;
 reg [3:0] cert_size,cert_fact;reg [1:0] cert_side;
 reg [168:0] cert_own,cert_opp,cert_line;
 reg [7:0] cert_own_count,cert_opp_count,cert_target;
 wire human_turn=phase_i==3&&next_i==human_i;
 wire request_current=requested&&cert_version==version_i&&cert_board==board_i&&
  cert_size==size_i&&cert_side==human_i;
 wire current_cert=cert_valid&&request_current;
 wire live_available=current_cert&&cert_fact!=5&&human_turn&&safe_i&&mode_i==0;
 wire hint_allowed=human_turn&&safe_i&&mode_i==0&&size_i>=5&&size_i<=13&&
  (human_i==1||human_i==2);
 wire scan_cancel=new_game||!safe_i||mode_i!=0||!human_turn||!request_current;
 qy_coach_tactics tactics(.clk(clk),.rst_n(rst_n),.start(start),.cancel(scan_cancel),
  .board_i(board_i),.board_size_i(size_i),.side_i(human_i),.version_i(version_i),
  .busy(busy),.done(done),.valid(valid),.result_version(result_version),
  .own_wins(own_wins),.opp_wins(opp_wins),.own_count(own_count),.opp_count(opp_count),
  .own_first(own_first),.opp_first(opp_first),.own_line(own_line),.opp_line(opp_line),
  .terminal_own(terminal_own),.terminal_opp(terminal_opp),.error(tactic_error));
 function [168:0] occupied_mask;
  input [337:0] b;integer k;
  begin
   for(k=0;k<169;k=k+1)occupied_mask[k]=(b[k*2+:2]==1||b[k*2+:2]==2);
  end
 endfunction
 function [168:0] one_point;
  input [7:0] index;
  begin one_point=169'd0;if(index<169)one_point[index]=1'b1;end
 endfunction
 reg [337:0] expected_after;
 always @* begin
  expected_after=cert_board;
  if(event_index_i<169)expected_after[event_index_i*2+:2]=cert_side;
 end
 // The formal event was already visually verified. safe_i may fall during
 // the normal observation gap just after that formal commit.
 wire certified_event=event_valid_i&&!event_is_ai_i&&requested&&cert_valid&&mode_i==0&&
  event_index_i<169&&event_index_i/13<cert_size&&event_index_i%13<cert_size&&
  cert_board[event_index_i*2+:2]==0&&version_i==cert_version+32'd1&&
  board_i==expected_after&&size_i==cert_size&&human_i==cert_side&&event_color_i==cert_side;
 reg [3:0] assessed;
 always @* begin
  assessed=7;
  if(certified_event)begin
   if(cert_own[event_index_i])assessed=1;
   else if(cert_own_count!=0)assessed=3;
   else if(cert_opp_count>1)assessed=5;
   else if(cert_opp_count==1)assessed=cert_opp[event_index_i]?4'd2:4'd4;
   else assessed=6;
  end
 end
 wire scored_event=certified_event&&(cert_fact==1||cert_fact==2);
 // rules updates board/version/accepted on one edge; game publishes its
 // event on the following edge. Keep only internal evidence across that one
 // intervening edge, then require the complete certified_event check above.
 // event_wait cannot renew: its next edge always consumes or discards it.
 wire wait_for_event=requested&&cert_valid&&!event_wait&&!event_valid_i&&mode_i==0&&
  version_i==cert_version+32'd1&&size_i==cert_size&&human_i==cert_side;
 wire meaningful=assessed>=1&&assessed<=5;
 wire mistake=assessed>=3&&assessed<=5;
 reg counter_valid;reg [7:0] counter_index;reg [168:0] counter_line;
 reg [337:0] counter_board;reg [31:0] counter_version;
 reg [3:0] counter_size;reg [1:0] counter_side;
 wire counter_context=counter_version==version_i&&counter_board==board_i&&
  counter_size==size_i&&counter_side==human_i&&mode_i==0;
 // Preserve evidence across an observation gap, but expose it only when the
 // same accepted formal position is safe and its counterexample is still empty.
 assign counterexample_valid_o=counter_valid&&counter_context&&safe_i&&
  counter_index<169&&board_i[counter_index*2+:2]==0;
 assign counterexample_index_o=counterexample_valid_o?counter_index:8'd255;
 assign counterexample_line_o=counterexample_valid_o?counter_line:169'd0;
 reg [337:0] review_board;
 reg [168:0] review_targets,review_line;
 reg [3:0] review_fact,review_feedback;
 reg [7:0] review_own_count,review_opp_count,review_target,review_move,review_number;
 reg review_mistake;
 reg feedback_valid;reg [31:0] feedback_version;
 assign review_o=review_requested&&mode_i==4&&review_valid_o;
 assign uncertain_o=!review_o&&!safe_i;
 assign display_board_o=review_o?review_board:board_i;
 assign review_move_o=review_o?review_move:8'd255;
 assign review_number_o=review_number;
 assign display_feedback_o=review_o?review_feedback:feedback_o;
 assign display_level_o=review_o?2'd3:level_o;
 assign fact_o=review_o?review_fact:!safe_i||mode_i!=0?4'd6:phase_i==9?4'd5:
  !human_turn?4'd6:current_cert?cert_fact:request_current?(scan_failed?4'd6:4'd7):4'd0;
 assign own_count_o=review_o?review_own_count:current_cert&&safe_i?cert_own_count:8'd0;
 assign opp_count_o=review_o?review_opp_count:current_cert&&safe_i?cert_opp_count:8'd0;
 assign target_o=review_o?review_target:live_available&&level_o==3?cert_target:8'd255;
 assign targets_o=review_o?review_targets:live_available&&level_o==3?one_point(cert_target):169'd0;
 // Level two shows only occupied support. Level three adds one empty answer;
 // scoring still accepts every certified correct answer, not just that hint.
 assign line_o=review_o?review_line:live_available&&level_o>=2?cert_line:169'd0;
 always @(posedge clk)begin
  if(!rst_n||new_game)begin
   start<=0;requested<=0;scan_attempted<=0;scan_failed<=0;event_wait<=0;
   cert_valid<=0;cert_board<=0;cert_version<=0;cert_size<=13;cert_side<=1;cert_fact<=0;
   cert_own<=0;cert_opp<=0;cert_line<=0;cert_own_count<=0;cert_opp_count<=0;cert_target<=255;
   level_o<=0;feedback_o<=0;feedback_valid<=0;feedback_version<=0;
   answer_valid_o<=0;answer_correct_o<=0;tactics_cycles_o<=0;attempts_o<=0;hints_o<=0;
   counter_valid<=0;counter_index<=255;counter_line<=0;counter_board<=0;
   counter_version<=0;counter_size<=13;counter_side<=1;
   review_requested<=0;review_valid_o<=0;review_board<=0;review_targets<=0;review_line<=0;
   review_fact<=0;review_feedback<=0;review_own_count<=0;review_opp_count<=0;
   review_target<=255;review_move<=255;review_number<=0;review_mistake<=0;
  end else begin
   start<=0;answer_valid_o<=0;answer_correct_o<=0;
   // Measured busy clocks of the actual unchanged core. Cancellation retains
   // clocks already consumed. Dispatch of the next scan resets the count.
   if(start&&!busy&&!scan_cancel)tactics_cycles_o<=0;
   else if(busy&&tactics_cycles_o!=32'hffffffff)tactics_cycles_o<=tactics_cycles_o+1'b1;
   if(event_wait||!request_current)begin
    level_o<=0;scan_attempted<=0;
    if(wait_for_event)event_wait<=1;
    else begin requested<=0;cert_valid<=0;scan_failed<=0;event_wait<=0;end
   end
   if(!safe_i||!human_turn)begin level_o<=0;scan_attempted<=0;end
   if(mode_i!=0)begin requested<=0;cert_valid<=0;scan_attempted<=0;scan_failed<=0;level_o<=0;event_wait<=0;end
   if(request_current&&safe_i&&human_turn&&mode_i==0&&!cert_valid&&!scan_failed&&
      !busy&&!start&&!scan_attempted)begin start<=1;scan_attempted<=1;end
   if(done&&request_current&&safe_i&&human_turn&&mode_i==0)begin
    if(valid&&result_version==cert_version&&!tactic_error)begin
     cert_valid<=1;cert_own<=own_wins;cert_opp<=opp_wins;
     cert_own_count<=own_count;cert_opp_count<=opp_count;
     cert_fact<=terminal_own||terminal_opp?5:own_count!=0?1:opp_count==1?2:opp_count>1?3:4;
     cert_target<=own_count!=0?own_first:opp_count==1?opp_first:8'd255;
     cert_line<=(own_count!=0?own_line:opp_count!=0?opp_line:169'd0)&occupied_mask(cert_board);
    end else begin cert_valid<=0;scan_failed<=1;end
   end
   if(hint_press_i&&hint_allowed)begin
    if(hints_o!=16'hffff)hints_o<=hints_o+1'b1;
    if(request_current)level_o<=level_o==3?0:level_o+1'b1;
    else begin
     requested<=1;cert_valid<=0;scan_attempted<=0;scan_failed<=0;level_o<=1;event_wait<=0;
     cert_board<=board_i;cert_version<=version_i;cert_size<=size_i;cert_side<=human_i;
     cert_own<=0;cert_opp<=0;cert_line<=0;cert_own_count<=0;cert_opp_count<=0;
     cert_target<=255;cert_fact<=0;
    end
   end
   if(counter_valid&&!counter_context)counter_valid<=0;
   if(feedback_valid&&version_i!=feedback_version)begin feedback_o<=0;feedback_valid<=0;end
   if(certified_event)begin
    // A mistake remains on board_i. There is no hypothetical move write path.
    requested<=0;cert_valid<=0;level_o<=0;scan_attempted<=0;event_wait<=0;
    feedback_o<=assessed;feedback_valid<=1;feedback_version<=version_i;
    if(scored_event)begin
     answer_valid_o<=1;answer_correct_o<=assessed==1||assessed==2;
     if(attempts_o!=16'hffff)attempts_o<=attempts_o+1'b1;
    end
    if(cert_fact==2&&assessed==4&&cert_target<169&&board_i[cert_target*2+:2]==0)begin
     counter_valid<=1;counter_index<=cert_target;counter_line<=cert_line|one_point(cert_target);
     counter_board<=board_i;counter_version<=version_i;counter_size<=size_i;counter_side<=human_i;
    end
    if(meaningful&&(!review_valid_o||(!review_mistake&&mistake)))begin
     review_valid_o<=1;review_board<=cert_board;review_targets<=one_point(cert_target);
     review_line<=cert_line;review_fact<=cert_fact;review_feedback<=assessed;
     review_own_count<=cert_own_count;review_opp_count<=cert_opp_count;review_target<=cert_target;
     review_move<=event_index_i;review_number<=move_count_i;review_mistake<=mistake;
    end
   end
   if(mode_i!=4)review_requested<=0;
   else if(review_press_i&&review_valid_o)review_requested<=!review_requested;
  end
 end
endmodule
`default_nettype wire
