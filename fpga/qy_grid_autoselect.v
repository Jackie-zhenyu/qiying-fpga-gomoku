`timescale 1ns/1ps
`default_nettype none
// Single-black-origin calibration proposal. The radial seed is a proposal only:
// the observer must verify this one nominal anchor with its independent probe
// and verify every other crossing as empty before calibration is committed.
// anchor_mode=0 preserves legacy empty-board proposal/refinement behavior.
// Per-frame following belongs to the observer, not this locator.
// All image/histogram reads are synchronous. This module never sees game state.
module qy_grid_autoselect #(
 parameter MIN_VOTES=35, parameter MAX_SIZE=13
)(
 input wire clk,rst_n,start,
 input wire anchor_mode,seed_valid,input wire [8:0] seed_x,input wire [7:0] seed_y,
 input wire retry_next,
 output reg busy,done,success,output reg [3:0] board_size,
 output reg [2872:0] points,
 output reg [15:0] raw_address,input wire [16:0] raw_data,
 output reg [31:0] cycles,
 output reg [3:0] anchor_row,anchor_col,
 output reg [7:0] anchor_index,error_reason
);
 localparam IDLE=0,CLEAR=1,PADDR=2,PWAIT=3,PUSE=4,AADDR=5,AWAIT=6,AUSE=7,
 BADDR=8,BWAIT=9,BUSE=10,HADDR=11,HWAIT=12,HADD=13,PNEXT=14,
 SADDR=15,SWAIT=16,SUSE=17,PEAK=18,RINIT=19,RSTEP=20,REVAL=21,
 RSAVE=22,SLOPE_NEXT=23,CINIT=24,CSTART=25,XSTEP=26,YSTEP=27,
 CORNER=28,CNEXT=29,CDECIDE=30,GENERATE=31,STORE_POINT=32,FINISH=33,
 REFINE_INIT=34,REFINE_ADDR=35,REFINE_WAIT=36,REFINE_USE=37,REFINE_SCAN=38,REFINE_END=39,
 BTEST=40,REFINE_LATCH=41,RUN_ANCHOR_INIT=42,RUN_ANCHOR_SCAN=43,
 RUN_ANCHOR_CHECK=44,REFINE_POLICY=45,RSTEP_READ=46,RSTEP_GAP=47;
 localparam ERR_NONE=8'h00,ERR_SEED=8'h01,ERR_ANCHOR_LINES=8'h02,
 ERR_WINDOW=8'h03,ERR_REFINE_MARGIN=8'h04,
 ERR_FSM=8'h80;
 reg [5:0] state;
 reg run_anchor_mode;reg [8:0] run_seed_x;reg [7:0] run_seed_y;
 reg [5:0] anchor_scan_index,nearest_anchor_index,h_anchor,v_anchor;
 reg [8:0] nearest_anchor_distance,second_anchor_distance;
 reg [3:0] selected_anchor_row,selected_anchor_col;
 wire [7:0] selected_anchor_index=selected_anchor_row*8'd13+selected_anchor_col;
 reg pending_valid;
 reg axis; // 0 horizontal y=intercept+slope*x/64; 1 vertical x=...y.
 reg signed [5:0] slope;
 reg [8:0] x;reg [7:0] y;
 reg [7:0] near_gray;reg paper;
 reg [9:0] ink_threshold;reg [8:0] neighbor_sum;reg [7:0] refine_ink;
 reg [8:0] clear_index,scan_index;
 reg [8:0] bin;
 (* ram_style="bram" *) reg [8:0] histogram[0:511];
 (* keep="true" *) reg [8:0] hist_read_address,hist_write_address;
 reg [8:0] hist_read_data,hist_write_data;reg hist_we;
 always @(posedge clk)begin
  hist_read_data<=histogram[hist_read_address];
  if(hist_we)histogram[hist_write_address]<=hist_write_data;
 end
 reg cluster;reg [8:0] cluster_peak,cluster_value;reg [5:0] cluster_width;
 reg [431:0] peak_locations,peak_votes;
 reg [5:0] peak_count;
 reg [5:0] run_begin,run_end,run_length;
 reg [8:0] pitch,run_gap_max;
 reg [14:0] run_score;
 reg [431:0] h_locations,v_locations;
 reg [5:0] h_begin,v_begin,h_count,v_count;
 reg [14:0] h_score,v_score;
 reg [8:0] h_gap,v_gap;
 reg signed [5:0] h_slope,v_slope;
 wire [8:0] current_peak=peak_locations[run_end*9+:9];
 wire [8:0] previous_peak=peak_locations[(run_end-1'b1)*9+:9];
 reg [8:0] current_peak_q,previous_peak_q,run_votes_q,gap;
 wire [5:0] slope_abs=slope<0?-slope:slope;
 wire [5:0] best_slope_abs=axis?(v_slope<0?-v_slope:v_slope):(h_slope<0?-h_slope:h_slope);
 wire better_run=run_length>(axis?v_count:h_count)||
  (run_length==(axis?v_count:h_count)&&(run_score>(axis?v_score:h_score)||
   (run_score==(axis?v_score:h_score)&&slope_abs<best_slope_abs)));
 wire signed [15:0] vote_product=$signed(slope)*$signed(axis?{2'b0,y}:{1'b0,x});
 wire signed [15:0] vote_bin=$signed(axis?{7'd0,x}:{8'd0,y})-(vote_product>>>6)+16'sd48;
 wire signed [15:0] seed_product=$signed(slope)*$signed(axis?{2'b0,run_seed_y}:{1'b0,run_seed_x});
 wire signed [15:0] seed_bin=$signed(axis?{7'd0,run_seed_x}:{8'd0,run_seed_y})-(seed_product>>>6)+16'sd48;
 wire signed [16:0] anchor_peak_difference=$signed({8'd0,peak_locations[anchor_scan_index*9+:9]})-$signed({seed_bin[15],seed_bin});
 wire [16:0] anchor_peak_distance=anchor_peak_difference<0?-anchor_peak_difference:anchor_peak_difference;
 reg [3:0] n;
 reg [5:0] candidate_row,candidate_col,best_row,best_col;
 reg [1:0] corner_index,iteration;
 reg [3:0] generate_row,generate_col;
 reg [7:0] generate_index;
 reg signed [15:0] px,py,base_x,base_y;
 reg signed [15:0] min_x,max_x,min_y,max_y;
 reg [8:0] margin;
 reg have_candidate,generating;
 reg [10:0] best_distance;
 // Failed refinements advance strictly through (distance,row,col) at this N.
 reg retry_active;
 reg [10:0] last_rejected_distance;
 reg [5:0] last_rejected_row,last_rejected_col;
 wire signed [21:0] x_product=$signed(v_slope)*$signed(py);
 wire signed [21:0] y_product=$signed(h_slope)*$signed(px);
 wire signed [16:0] distance_x=min_x+max_x-17'sd319;
 wire signed [16:0] distance_y=min_y+max_y-17'sd179;
 wire [16:0] abs_distance_x=distance_x<0?-distance_x:distance_x;
 wire [16:0] abs_distance_y=distance_y<0?-distance_y:distance_y;
 wire [17:0] candidate_distance=abs_distance_x+abs_distance_y;
 wire candidate_after_rejection=!retry_active||
  candidate_distance>{7'd0,last_rejected_distance}||
  (candidate_distance=={7'd0,last_rejected_distance}&&
   (candidate_row>last_rejected_row||
    (candidate_row==last_rejected_row&&candidate_col>last_rejected_col)));
 wire candidate_inside=min_x>=$signed({7'd0,margin})&&max_x<320-$signed({7'd0,margin})&&
  min_y>=$signed({7'd0,margin})&&max_y<180-$signed({7'd0,margin});
 wire [6:0] candidate_h_start={1'b0,h_begin}+{1'b0,candidate_row};
 wire [6:0] candidate_v_start={1'b0,v_begin}+{1'b0,candidate_col};
 wire candidate_anchor_inside={1'b0,h_anchor}>candidate_h_start&&
  {1'b0,h_anchor}<candidate_h_start+{3'd0,n}-7'd1&&
  {1'b0,v_anchor}>candidate_v_start&&
  {1'b0,v_anchor}<candidate_v_start+{3'd0,n}-7'd1;
 reg [5:0] point_h_index,point_v_index;
 reg [3:0] refine_x,refine_y,refine_index,refined_dx,refined_dy;
 reg [11:0] refine_h[0:10],refine_v[0:10];
 reg [11:0] refine_h_min,refine_v_min;
 reg [3:0] refine_radius,refine_width;
 reg signed [15:0] refined_x,refined_y;
 integer k;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;busy<=0;done<=0;success<=0;board_size<=0;points<=0;cycles<=0;
   anchor_row<=0;anchor_col<=0;anchor_index<=255;error_reason<=ERR_NONE;
   run_anchor_mode<=0;run_seed_x<=0;run_seed_y<=0;anchor_scan_index<=0;nearest_anchor_index<=0;h_anchor<=0;v_anchor<=0;
   nearest_anchor_distance<=511;second_anchor_distance<=511;selected_anchor_row<=0;selected_anchor_col<=0;
   pending_valid<=0;
   raw_address<=0;axis<=0;slope<=-8;x<=3;y<=3;near_gray<=0;paper<=0;
   ink_threshold<=0;neighbor_sum<=0;refine_ink<=0;
   clear_index<=0;scan_index<=0;bin<=0;hist_read_address<=0;hist_write_address<=0;
   hist_write_data<=0;hist_we<=0;cluster<=0;cluster_peak<=0;cluster_value<=0;cluster_width<=0;
   peak_locations<=0;peak_votes<=0;peak_count<=0;run_begin<=0;run_end<=0;run_length<=0;
   current_peak_q<=0;previous_peak_q<=0;run_votes_q<=0;gap<=0;
   pitch<=0;run_gap_max<=0;run_score<=0;h_locations<=0;v_locations<=0;
   h_begin<=0;v_begin<=0;h_count<=0;v_count<=0;h_score<=0;v_score<=0;
   h_gap<=0;v_gap<=0;h_slope<=0;v_slope<=0;n<=0;
   candidate_row<=0;candidate_col<=0;best_row<=0;best_col<=0;corner_index<=0;iteration<=0;
   generate_row<=0;generate_col<=0;generate_index<=0;px<=0;py<=0;base_x<=0;base_y<=0;
   min_x<=0;max_x<=0;min_y<=0;max_y<=0;margin<=0;have_candidate<=0;generating<=0;
   best_distance<=2047;point_h_index<=0;point_v_index<=0;
   retry_active<=0;last_rejected_distance<=0;last_rejected_row<=0;last_rejected_col<=0;
   refine_x<=0;refine_y<=0;refine_index<=0;refined_dx<=0;refined_dy<=0;
   refine_h_min<=4095;refine_v_min<=4095;refine_radius<=5;refine_width<=10;refined_x<=0;refined_y<=0;
   for(k=0;k<11;k=k+1)begin refine_h[k]<=0;refine_v[k]<=0;end
  end else begin
   done<=0;hist_we<=0;
   if(busy)cycles<=cycles+1'b1;
   case(state)
    IDLE:if(retry_next&&pending_valid)begin
     // Caller still owns the same frozen frame. No new Hough scan is needed.
     busy<=1;success<=0;board_size<=0;points<=0;pending_valid<=0;error_reason<=ERR_NONE;
     anchor_row<=0;anchor_col<=0;anchor_index<=255;
     retry_active<=1;last_rejected_distance<=best_distance;
     last_rejected_row<=best_row;last_rejected_col<=best_col;
     candidate_row<=0;candidate_col<=0;have_candidate<=0;generating<=0;best_distance<=2047;
     generate_row<=0;generate_col<=0;generate_index<=0;state<=CSTART;
    end else if(start)begin
     busy<=1;success<=0;board_size<=0;points<=0;cycles<=0;
     pending_valid<=0;run_anchor_mode<=anchor_mode;
     error_reason<=ERR_NONE;run_seed_x<=seed_x;run_seed_y<=seed_y;
     anchor_row<=0;anchor_col<=0;anchor_index<=255;
     retry_active<=0;last_rejected_distance<=0;last_rejected_row<=0;last_rejected_col<=0;
     have_candidate<=0;generating<=0;best_distance<=2047;
     axis<=0;slope<=-8;clear_index<=0;h_count<=0;v_count<=0;h_score<=0;v_score<=0;
     h_slope<=0;v_slope<=0;h_anchor<=0;v_anchor<=0;
     if(anchor_mode&&(!seed_valid||seed_x<4||seed_x>315||seed_y<4||seed_y>175))begin error_reason<=ERR_SEED;state<=FINISH;end
     else state<=CLEAR;
    end
    CLEAR:begin
     hist_we<=1;hist_write_address<=clear_index;hist_write_data<=0;
     if(clear_index==511)begin x<=3;y<=3;state<=PADDR;end
     else clear_index<=clear_index+1'b1;
    end
    PADDR:begin raw_address<=y*16'd320+x;state<=PWAIT;end
    PWAIT:state<=PUSE;
    PUSE:begin
     paper<=raw_data[8];
     ink_threshold<=({2'd0,raw_data[16:9]}+10'd18)<<1;state<=AADDR;
    end
    AADDR:begin raw_address<=axis?y*16'd320+x-16'd3:(y-16'd3)*16'd320+x;state<=AWAIT;end
    AWAIT:state<=AUSE;
    AUSE:begin near_gray<=raw_data[7:0];state<=BADDR;end
    BADDR:begin raw_address<=axis?y*16'd320+x+16'd3:(y+16'd3)*16'd320+x;state<=BWAIT;end
    BWAIT:state<=BUSE;
    BUSE:begin
     // Keep the synchronous image-RAM return separate from the vote decision.
     neighbor_sum<={1'b0,near_gray}+{1'b0,raw_data[7:0]};state<=BTEST;
    end
    BTEST:begin
     if(paper&&ink_threshold<={1'b0,neighbor_sum}&&vote_bin>=0&&vote_bin<416)begin
      bin<=vote_bin[8:0];state<=HADDR;
     end else state<=PNEXT;
    end
    HADDR:begin hist_read_address<=bin;state<=HWAIT;end
    HWAIT:state<=HADD;
    HADD:begin hist_we<=1;hist_write_address<=bin;hist_write_data<=hist_read_data+1'b1;state<=PNEXT;end
    PNEXT:begin
     if(x==316)begin
      x<=3;
      if(y==176)begin scan_index<=0;peak_count<=0;peak_locations<=0;peak_votes<=0;cluster<=0;state<=SADDR;end
      else begin y<=y+1'b1;state<=PADDR;end
     end else begin x<=x+1'b1;state<=PADDR;end
    end
    SADDR:begin hist_read_address<=scan_index;state<=SWAIT;end
    SWAIT:state<=SUSE;
    SUSE:begin
     if(hist_read_data>=MIN_VOTES&&scan_index<416)begin
      if(!cluster)begin cluster<=1;cluster_peak<=scan_index;cluster_value<=hist_read_data;cluster_width<=1;end
      else begin
       if(cluster_width<63)cluster_width<=cluster_width+1'b1;
       if(hist_read_data>cluster_value)begin cluster_value<=hist_read_data;cluster_peak<=scan_index;end
      end
      scan_index<=scan_index+1'b1;state<=SADDR;
     end else if(cluster)begin cluster<=0;state<=PEAK;end
     else if(scan_index==416)begin run_begin<=0;state<=RINIT;end
     else begin scan_index<=scan_index+1'b1;state<=SADDR;end
    end
    PEAK:begin
     if(cluster_width<=5)begin
      if(peak_count==0||cluster_peak>=peak_locations[(peak_count-1'b1)*9+:9]+9'd7)begin
       if(peak_count<48)begin
        peak_locations[peak_count*9+:9]<=cluster_peak;peak_votes[peak_count*9+:9]<=cluster_value;peak_count<=peak_count+1'b1;
       end
      end else if(cluster_value>peak_votes[(peak_count-1'b1)*9+:9])begin
       peak_locations[(peak_count-1'b1)*9+:9]<=cluster_peak;peak_votes[(peak_count-1'b1)*9+:9]<=cluster_value;
      end
     end
     state<=SUSE;
    end
    RINIT:begin
     if(peak_count<2||run_begin+1>=peak_count)state<=SLOPE_NEXT;
     else begin
      pitch<=peak_locations[(run_begin+1'b1)*9+:9]-peak_locations[run_begin*9+:9];
      run_gap_max<=peak_locations[(run_begin+1'b1)*9+:9]-peak_locations[run_begin*9+:9];
      run_length<=2;run_end<=run_begin+2;
      run_score<={6'd0,peak_votes[run_begin*9+:9]}+{6'd0,peak_votes[(run_begin+1'b1)*9+:9]};state<=RSTEP_READ;
     end
    end
    RSTEP_READ:begin
     current_peak_q<=current_peak;previous_peak_q<=previous_peak;
     run_votes_q<=peak_votes[run_end*9+:9];state<=RSTEP_GAP;
    end
    RSTEP_GAP:begin gap<=current_peak_q-previous_peak_q;state<=RSTEP;end
    RSTEP:begin
     if(pitch<8||pitch>32)begin run_begin<=run_begin+1'b1;state<=RINIT;end
     else if(run_end>=peak_count||gap+9'd3<pitch||gap>pitch+9'd3)state<=REVAL;
     else begin
      run_end<=run_end+1'b1;run_length<=run_length+1'b1;
      run_score<=run_score+{6'd0,run_votes_q};state<=RSTEP_READ;
      if(gap>run_gap_max)run_gap_max<=gap;
     end
    end
    REVAL:begin
     if(!run_anchor_mode)begin
      if(better_run)begin
       if(axis)begin v_count<=run_length;v_score<=run_score;v_begin<=run_begin;v_locations<=peak_locations;v_slope<=slope;v_gap<=run_gap_max;end
       else begin h_count<=run_length;h_score<=run_score;h_begin<=run_begin;h_locations<=peak_locations;h_slope<=slope;h_gap<=run_gap_max;end
      end
      run_begin<=run_begin+1'b1;state<=RINIT;
     end else if(run_length>=5&&better_run)state<=RUN_ANCHOR_INIT;
     else begin run_begin<=run_begin+1'b1;state<=RINIT;end
    end
    RUN_ANCHOR_INIT:begin
     anchor_scan_index<=run_begin;nearest_anchor_index<=run_begin;
     nearest_anchor_distance<=511;second_anchor_distance<=511;state<=RUN_ANCHOR_SCAN;
    end
    RUN_ANCHOR_SCAN:begin
     // One peak per cycle: no all-points nearest-neighbor combinational mux.
     if(anchor_peak_distance<{8'd0,nearest_anchor_distance})begin
      second_anchor_distance<=nearest_anchor_distance;nearest_anchor_distance<=anchor_peak_distance[8:0];
      nearest_anchor_index<=anchor_scan_index;
     end else if(anchor_peak_distance<{8'd0,second_anchor_distance})second_anchor_distance<=anchor_peak_distance[8:0];
     if(anchor_scan_index+1'b1==run_begin+run_length)state<=RUN_ANCHOR_CHECK;
     else anchor_scan_index<=anchor_scan_index+1'b1;
    end
    RUN_ANCHOR_CHECK:begin
     // Unique closest line, closer than half a pitch, with a line on each side.
     // The independent final probe still must prove BLACK at the nominal point.
     if(nearest_anchor_distance<second_anchor_distance&&
        {nearest_anchor_distance,1'b0}<{1'b0,pitch}&&
        nearest_anchor_index>run_begin&&nearest_anchor_index+1'b1<run_begin+run_length)begin
      if(axis)begin
       v_count<=run_length;v_score<=run_score;v_begin<=run_begin;v_locations<=peak_locations;
       v_slope<=slope;v_gap<=run_gap_max;v_anchor<=nearest_anchor_index;
      end else begin
       h_count<=run_length;h_score<=run_score;h_begin<=run_begin;h_locations<=peak_locations;
       h_slope<=slope;h_gap<=run_gap_max;h_anchor<=nearest_anchor_index;
      end
     end
     run_begin<=run_begin+1'b1;state<=RINIT;
    end
    SLOPE_NEXT:begin
     clear_index<=0;
     if(slope<8)begin slope<=slope+1'b1;state<=CLEAR;end
     else if(!axis)begin axis<=1;slope<=-8;state<=CLEAR;end
     else state<=CINIT;
    end
    CINIT:begin
     retry_active<=0;last_rejected_distance<=0;last_rejected_row<=0;last_rejected_col<=0;
     if(h_count<5||v_count<5)begin error_reason<=ERR_ANCHOR_LINES;state<=FINISH;end
     else begin
      n<=h_count<v_count?(h_count>MAX_SIZE?MAX_SIZE:h_count):(v_count>MAX_SIZE?MAX_SIZE:v_count);
      margin<=((h_gap>v_gap?h_gap:v_gap)+9'd1)/2+9'd2;
      candidate_row<=0;candidate_col<=0;have_candidate<=0;best_distance<=2047;generating<=0;state<=CSTART;
     end
    end
    CSTART:begin
     corner_index<=0;min_x<=32767;max_x<=-32767;min_y<=32767;max_y<=-32767;
     point_h_index<=h_begin+candidate_row;point_v_index<=v_begin+candidate_col;state<=GENERATE;
    end
    GENERATE:begin
     base_x<=$signed({7'd0,v_locations[point_v_index*9+:9]})-16'sd48;
     base_y<=$signed({7'd0,h_locations[point_h_index*9+:9]})-16'sd48;
     px<=$signed({7'd0,v_locations[point_v_index*9+:9]})-16'sd48;
     py<=$signed({7'd0,h_locations[point_h_index*9+:9]})-16'sd48;
     iteration<=0;state<=XSTEP;
    end
    XSTEP:begin px<=base_x+(x_product>>>6);state<=YSTEP;end
    YSTEP:begin
     py<=base_y+(y_product>>>6);
     if(iteration==2)state<=generating?REFINE_POLICY:CORNER;
     else begin iteration<=iteration+1'b1;state<=XSTEP;end
    end
    CORNER:begin
     if(px<min_x)min_x<=px;if(px>max_x)max_x<=px;
     if(py<min_y)min_y<=py;if(py>max_y)max_y<=py;
     if(corner_index==3)state<=CNEXT;
     else begin
      corner_index<=corner_index+1'b1;
      point_h_index<=h_begin+candidate_row+(corner_index>=1?n-1'b1:0);
      point_v_index<=v_begin+candidate_col+(corner_index==1?0:n-1'b1);state<=GENERATE;
     end
    end
    CNEXT:begin
     if(candidate_inside&&(!run_anchor_mode||candidate_anchor_inside)&&candidate_after_rejection&&(!have_candidate||candidate_distance<best_distance))begin
      have_candidate<=1;best_row<=candidate_row;best_col<=candidate_col;best_distance<=candidate_distance[10:0];
     end
     if(candidate_col+n<v_count)begin candidate_col<=candidate_col+1'b1;state<=CSTART;end
     else if(candidate_row+n<h_count)begin candidate_col<=0;candidate_row<=candidate_row+1'b1;state<=CSTART;end
     else state<=CDECIDE;
    end
    CDECIDE:begin
     if(have_candidate)begin
      generating<=1;generate_row<=0;generate_col<=0;generate_index<=0;
      selected_anchor_row<=run_anchor_mode?h_anchor-h_begin-best_row:4'd0;
      selected_anchor_col<=run_anchor_mode?v_anchor-v_begin-best_col:4'd0;
      point_h_index<=h_begin+best_row;point_v_index<=v_begin+best_col;state<=GENERATE;
     end else if(n>5)begin
      n<=n-1'b1;candidate_row<=0;candidate_col<=0;
      retry_active<=0;last_rejected_distance<=0;last_rejected_row<=0;last_rejected_col<=0;
      have_candidate<=0;generating<=0;best_distance<=2047;points<=0;state<=CSTART;
     end
     else begin if(error_reason==ERR_NONE)error_reason<=ERR_WINDOW;state<=FINISH;end
    end
    REFINE_POLICY:begin
     if(run_anchor_mode&&generate_index==selected_anchor_index)begin
      // A covered crossing stays at the line-derived nominal intersection.
      // Never recenter it onto the dark disc or write back the probe center.
      refined_x<=px;refined_y<=py;state<=STORE_POINT;
     end else state<=REFINE_INIT;
    end
    REFINE_INIT:begin
     // A wider first refinement accommodates differently tilted hand-drawn
     // lines. The independent7x7 observer subsequently verifies alignment.
     refine_radius<=h_gap<12||v_gap<12?3:5;refine_width<=h_gap<12||v_gap<12?6:10;
     refine_x<=0;refine_y<=0;refine_h_min<=4095;refine_v_min<=4095;
     refined_dx<=0;refined_dy<=0;
     for(k=0;k<11;k=k+1)begin refine_h[k]<=0;refine_v[k]<=0;end
     state<=REFINE_ADDR;
    end
    REFINE_ADDR:begin
     raw_address<=(py+$signed({12'd0,refine_y})-$signed({12'd0,refine_radius}))*16'd320+
      px+$signed({12'd0,refine_x})-$signed({12'd0,refine_radius});state<=REFINE_WAIT;
    end
    REFINE_WAIT:state<=REFINE_LATCH;
    REFINE_LATCH:begin refine_ink<=raw_data[16:9];state<=REFINE_USE;end
    REFINE_USE:begin
     refine_h[refine_y]<=refine_h[refine_y]+{4'd0,refine_ink};
     refine_v[refine_x]<=refine_v[refine_x]+{4'd0,refine_ink};
     if(refine_x==refine_width)begin
      refine_x<=0;
      if(refine_y==refine_width)begin refine_index<=0;state<=REFINE_SCAN;end
      else begin refine_y<=refine_y+1'b1;state<=REFINE_ADDR;end
     end else begin refine_x<=refine_x+1'b1;state<=REFINE_ADDR;end
    end
    REFINE_SCAN:begin
     if(refine_h[refine_index]<refine_h_min)begin refine_h_min<=refine_h[refine_index];refined_dy<=refine_index;end
     if(refine_v[refine_index]<refine_v_min)begin refine_v_min<=refine_v[refine_index];refined_dx<=refine_index;end
     if(refine_index==refine_width)state<=REFINE_END;
     else refine_index<=refine_index+1'b1;
    end
    REFINE_END:begin
     refined_x<=px+$signed({12'd0,refined_dx})-$signed({12'd0,refine_radius});
     refined_y<=py+$signed({12'd0,refined_dy})-$signed({12'd0,refine_radius});state<=STORE_POINT;
    end
    STORE_POINT:begin
     points[generate_index*17+:17]<={refined_y[7:0],refined_x[8:0]};
     if(refined_x<$signed({7'd0,margin})||refined_x>=320-$signed({7'd0,margin})||
        refined_y<$signed({7'd0,margin})||refined_y>=180-$signed({7'd0,margin}))begin
      // Discard every partial point; keep N and rescan after this exact candidate.
      success<=0;board_size<=0;points<=0;
      pending_valid<=0;error_reason<=ERR_REFINE_MARGIN;
      retry_active<=1;last_rejected_distance<=best_distance;
      last_rejected_row<=best_row;last_rejected_col<=best_col;
      candidate_row<=0;candidate_col<=0;have_candidate<=0;generating<=0;best_distance<=2047;
      generate_row<=0;generate_col<=0;generate_index<=0;state<=CSTART;
     end else
     if(generate_col==n-1'b1)begin
      if(generate_row==n-1'b1)begin
       success<=1;board_size<=n;error_reason<=ERR_NONE;
       anchor_row<=selected_anchor_row;anchor_col<=selected_anchor_col;
       anchor_index<=run_anchor_mode?selected_anchor_index:8'd255;
       pending_valid<=1;state<=FINISH;
      end
      else begin
       generate_col<=0;generate_row<=generate_row+1'b1;generate_index<=(generate_row+1'b1)*13;
       point_h_index<=h_begin+best_row+generate_row+1'b1;point_v_index<=v_begin+best_col;state<=GENERATE;
      end
     end else begin
      generate_col<=generate_col+1'b1;generate_index<=generate_index+1'b1;
      point_v_index<=v_begin+best_col+generate_col+1'b1;state<=GENERATE;
     end
    end
    FINISH:begin busy<=0;done<=1;state<=IDLE;end
    default:begin busy<=0;success<=0;board_size<=0;points<=0;pending_valid<=0;
     error_reason<=ERR_FSM;done<=1;state<=IDLE;end
   endcase
  end
 end
endmodule
`default_nettype wire
