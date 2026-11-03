`timescale 1ns/1ps
`default_nettype none
// Fresh, complete, confident whole-board match. Does not write a game board.
module qy_teacher_match #(
 parameter MIN_FRAMES=3, parameter [63:0] STABLE_US=250000
)(
 input wire clk,rst_n,enable,
 input wire [337:0] expected,
 input wire [3:0] size,
 input wire [191:0] context_i,
 input wire [31:0] epoch_i,
 input wire [63:0] now_us,
 input wire obs_valid,output wire obs_ready,
 input wire [337:0] cells,input wire [168:0] seen,input wire [1351:0] confidence,
 input wire [191:0] obs_context,input wire [31:0] obs_epoch,
 input wire [63:0] frame,capture_us,input wire complete,observable,input wire [15:0] quality,
 output reg matched,output reg qualified
);
 reg scanning,bad;reg [7:0] index;
 reg [337:0] snap,expected_snap;reg [168:0] seen_snap;reg [1351:0] conf_snap;
 reg [3:0] size_snap;reg [191:0] ctx;reg [31:0] ep;
 reg [63:0] last_frame,last_capture,first_capture,scan_time;
 reg [15:0] count;
 wire changed=ctx!=context_i||ep!=epoch_i||expected_snap!=expected||size_snap!=size;
 wire fresh=now_us>=capture_us&&now_us-capture_us<=500000;
 wire active=index/13<size_snap&&index%13<size_snap;
 wire cell_bad=(snap[index*2+:2]!=expected_snap[index*2+:2])||
  (active&&(!seen_snap[index]||conf_snap[index*8+:8]<160||snap[index*2+:2]==3))||
  (!active&&snap[index*2+:2]!=0);
 assign obs_ready=enable&&!scanning&&!changed;
 always @(posedge clk)begin
  if(!rst_n)begin scanning<=0;bad<=0;index<=0;snap<=0;expected_snap<=0;seen_snap<=0;conf_snap<=0;
   size_snap<=0;ctx<=0;ep<=0;last_frame<=0;last_capture<=0;first_capture<=0;scan_time<=0;count<=0;matched<=0;qualified<=0;end
  else begin
   matched<=0;
   if(!enable||changed)begin
    scanning<=0;count<=0;qualified<=0;ctx<=context_i;ep<=epoch_i;expected_snap<=expected;size_snap<=size;
   end else if(scanning)begin
    if(cell_bad)begin bad<=1;qualified<=0;end
    if(index==168)begin
     scanning<=0;
     if(bad||cell_bad||now_us<scan_time||now_us-scan_time>500000)begin count<=0;qualified<=0;end
     else if(count==0||scan_time<=last_capture||scan_time-last_capture>250000)begin
      count<=1;first_capture<=scan_time;
      if(scan_time<=last_capture||scan_time-last_capture>250000)qualified<=0;
     end else if(count+1>=MIN_FRAMES&&scan_time-first_capture>=STABLE_US)begin matched<=1;qualified<=1;count<=0;end
     else if(count!=65535)count<=count+1'b1;
     last_capture<=scan_time;
    end else index<=index+1'b1;
   end else if(obs_valid&&obs_ready)begin
    if(obs_context!=context_i||obs_epoch!=epoch_i||frame==0||frame==64'hffffffffffffffff||
      frame<=last_frame||capture_us==64'hffffffffffffffff||!fresh||!complete||!observable||quality!=0||
      size<5||size>13||context_i[159:128]==0||context_i[159:128]==32'hffffffff||
      context_i[63:0]==0||context_i[63:0]==64'hffffffffffffffff||epoch_i==32'hffffffff||
      now_us==64'hffffffffffffffff)begin count<=0;qualified<=0;end
    else begin
     last_frame<=frame;snap<=cells;seen_snap<=seen;conf_snap<=confidence;
     scan_time<=capture_us;scanning<=1;bad<=0;index<=0;
    end
   end
   if(now_us<last_capture||now_us-last_capture>500000)qualified<=0;
  end
 end
endmodule
`default_nettype wire
