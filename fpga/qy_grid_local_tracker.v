`timescale 1ns/1ps
`default_nettype none
// Bounded grid-only registration. Input supports come from the baseline 7x7
// paper/line/arms predicate, never from the expected board or a stone center.
// Every one of the 169 slots must be written (invalid slots included) before solve.
module qy_grid_local_tracker(
 input wire clk,rst_n,begin_frame,
 input wire sample_write,sample_valid,input wire [7:0] sample_index,
 input wire [3:0] sample_row,sample_col,
 input wire signed [2:0] sample_dx,sample_dy,
 input wire solve_start,input wire [3:0] board_size,anchor_row,anchor_col,
 output reg busy,done,model_valid,
 output reg signed [2:0] tx,ty,output reg signed [4:0] sx,sy,
 output reg [7:0] support_count,output reg [12:0] support_rows,support_cols
);
 localparam IDLE=0,MODEL=1,ADDR=2,WAIT_DATA=3,EVAL=4,COMPARE=5,NEXT_MODEL=6;
 reg [2:0] state;
 (* ram_style="bram" *) reg [6:0] support_ram[0:255];
 reg [7:0] read_address;reg [6:0] read_data;
 always @(posedge clk)begin
  read_data<=support_ram[read_address];
  if(sample_write)support_ram[sample_index]<={sample_valid,sample_dy,sample_dx};
 end
 reg [3:0] min_row,max_row,min_col,max_col;
 reg [3:0] n,ar,ac,row,col;
 reg [7:0] index;
 reg axis;
 reg signed [2:0] trial_t,best_t;
 reg signed [4:0] trial_s,best_s;
 reg [8:0] cost,best_cost;reg [7:0] exact,best_exact;reg best_valid;
 function [3:0] pop13;
  input [12:0] bits;integer k;begin pop13=0;for(k=0;k<13;k=k+1)pop13=pop13+bits[k];end
 endfunction
 function signed [5:0] delta;
  input signed [2:0] t;input signed [4:0] s;
  input [3:0] coordinate,origin;
  reg signed [5:0] distance;reg signed [10:0] product,rounded;
  begin
   distance=$signed({2'b00,coordinate})-$signed({2'b00,origin});
   product=s*distance;rounded=product+11'sd8;
   delta=$signed({{3{t[2]}},t})+(rounded>>>4);
  end
 endfunction
 function [5:0] abs_s;input signed [4:0] v;begin abs_s=v<0?-$signed({v[4],v}):{1'b0,v};end endfunction
 function [3:0] abs_t;input signed [2:0] v;begin abs_t=v<0?-$signed({v[2],v}):{1'b0,v};end endfunction
 wire signed [5:0] first_delta=delta(trial_t,trial_s,4'd0,axis?ac:ar);
 wire signed [5:0] last_delta=delta(trial_t,trial_s,n-1'b1,axis?ac:ar);
 wire bounded=first_delta>=-6'sd3&&first_delta<=6'sd3&&last_delta>=-6'sd3&&last_delta<=6'sd3;
 wire signed [5:0] predicted=delta(trial_t,trial_s,axis?col:row,axis?ac:ar);
 wire signed [2:0] measured=axis?$signed(read_data[5:3]):$signed(read_data[2:0]);
 wire signed [6:0] residual=$signed({{4{measured[2]}},measured})-$signed({predicted[5],predicted});
 wire [6:0] magnitude=residual<0?-residual:residual;
 wire better=!best_valid||cost<best_cost||(cost==best_cost&&
  (exact>best_exact||(exact==best_exact&&(abs_s(trial_s)<abs_s(best_s)||
   (abs_s(trial_s)==abs_s(best_s)&&abs_t(trial_t)<abs_t(best_t))))));
 // Rounded linear models are monotonic, so endpoint bounds cover every row/col.
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;busy<=0;done<=0;model_valid<=0;tx<=0;ty<=0;sx<=0;sy<=0;
   support_count<=0;support_rows<=0;support_cols<=0;min_row<=15;max_row<=0;min_col<=15;max_col<=0;
   read_address<=0;n<=13;ar<=0;ac<=0;row<=0;col<=0;index<=0;axis<=0;
   trial_t<=0;trial_s<=0;best_t<=0;best_s<=0;cost<=0;exact<=0;best_cost<=0;best_exact<=0;best_valid<=0;
  end else begin
   done<=0;
   if(begin_frame&&!busy)begin
    support_count<=0;support_rows<=0;support_cols<=0;min_row<=15;max_row<=0;min_col<=15;max_col<=0;
    model_valid<=0;
   end else if(sample_write&&sample_valid&&!busy)begin
    support_count<=support_count+1'b1;support_rows[sample_row]<=1;support_cols[sample_col]<=1;
    if(sample_row<min_row)min_row<=sample_row;if(sample_row>max_row)max_row<=sample_row;
    if(sample_col<min_col)min_col<=sample_col;if(sample_col>max_col)max_col<=sample_col;
   end
   case(state)
    IDLE:if(solve_start)begin
     model_valid<=0;
     if(board_size<5||board_size>13||anchor_row>=board_size||anchor_col>=board_size||
        support_count<8||pop13(support_rows)<3||pop13(support_cols)<3||
        max_row-min_row<((board_size-1'b1)>>1)||max_col-min_col<((board_size-1'b1)>>1))begin
      done<=1;
     end else begin
      busy<=1;n<=board_size;ar<=anchor_row;ac<=anchor_col;axis<=0;
      trial_t<=-3'sd3;trial_s<=-5'sd8;best_valid<=0;state<=MODEL;
     end
    end
    MODEL:begin
     if(!bounded)state<=NEXT_MODEL;
     else begin index<=0;row<=0;col<=0;cost<=0;exact<=0;state<=ADDR;end
    end
    ADDR:begin read_address<=index;state<=WAIT_DATA;end
    WAIT_DATA:state<=EVAL;
    EVAL:begin
     if(read_data[6]&&row<n&&col<n)begin
      cost<=cost+(magnitude>2?9'd2:{2'd0,magnitude});
      if(magnitude==0)exact<=exact+1'b1;
     end
     if(index==168)state<=COMPARE;
     else begin index<=index+1'b1;col<=col==12?0:col+1'b1;if(col==12)row<=row+1'b1;state<=ADDR;end
    end
    COMPARE:begin
     if(better)begin best_valid<=1;best_cost<=cost;best_exact<=exact;best_t<=trial_t;best_s<=trial_s;end
     state<=NEXT_MODEL;
    end
    NEXT_MODEL:begin
     if(trial_s==8)begin
      if(trial_t==3)begin
       if(!axis)begin
        tx<=best_t;sx<=best_s;axis<=1;trial_t<=-3'sd3;trial_s<=-5'sd8;best_valid<=0;state<=MODEL;
       end else begin ty<=best_t;sy<=best_s;model_valid<=best_valid;done<=1;busy<=0;state<=IDLE;end
      end else begin trial_t<=trial_t+1'b1;trial_s<=-5'sd8;state<=MODEL;end
     end else begin trial_s<=trial_s+1'b1;state<=MODEL;end
    end
    default:begin busy<=0;model_valid<=0;state<=IDLE;done<=1;end
   endcase
  end
 end
endmodule
`default_nettype wire
