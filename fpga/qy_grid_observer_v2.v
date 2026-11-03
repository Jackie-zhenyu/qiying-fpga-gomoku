`timescale 1ns/1ps
`default_nettype none
// Empty-grid measurement and image-only local stone classification share one
// frozen sampled image. A missing radial box is never interpreted as emptiness.
module qy_grid_observer_v2 #(
 parameter DYNAMIC_SIZE=0, parameter ORIGIN_OPENING=0, parameter PROBE_OFFSET_FILE="grid_probe_offsets.hex"
)(
 input wire clk,rst_n,start,calibrate,
 input wire anchor_mode,input wire [7:0] anchor_index_i,
 output reg anchor_seed_valid,output reg [7:0] anchor_seed_index,
 output reg signed [2:0] track_tx,track_ty,output reg signed [4:0] track_sx,track_sy,
 input wire [3:0] nominal_size,output reg [3:0] board_size,
 input wire [2872:0] nominal_points,input wire [7:0] box_count,detector_error,
 output wire [15:0] raw_address,input wire [16:0] raw_data,
 output reg busy,done,observation_valid,calibration_done,calibration_success,
 output reg calibrated,output reg [2872:0] points,
 output reg [337:0] cells,output reg [168:0] observable,
 output reg [1351:0] confidence,output reg [15:0] quality,
 output wire board_observable,output wire [6143:0] observed_boxes,output reg [7:0] observed_count
);
 localparam IDLE=0,CELL_LOAD=1,PIX_ADDR=2,PIX_WAIT=3,PIX_USE=4,LINE_INIT=5,
  LINE_SCAN=6,CLASSIFY=7,NEXT_CELL=8,VERIFY_INIT=9,VERIFY_INDEX=10,
  VERIFY_LOAD=11,VERIFY_CHECK=12,FINISH=13,PROBE_START=14,PROBE_WAIT=15,PROBE_ACCEPT=16,
  DISK_LOAD=17,DISK_DIFF=18,DISK_SQUARE=19,DISK_CHECK=20,DISK_SAVE=21,ADVANCE=22,PIX_ACCUM=23,VERIFY_GAPS=24,VERIFY_RADIUS=25,
  CELL_ADDR=26,CELL_WAIT=27,INIT_LOAD=28,INIT_WRITE=29,
  VERIFY_POINT_WAIT=30,VERIFY_POINT_USE=31,VERIFY_LEFT_WAIT=32,VERIFY_LEFT_USE=33,
  VERIFY_ABOVE_WAIT=34,COMMIT_ADDR=35,COMMIT_WAIT=36,COMMIT_USE=37,
  ANCHOR_ADDR=38,ANCHOR_WAIT=39,ANCHOR_LOAD=40,ANCHOR_CHECK=41,TRACK_SOLVE=42,TRACK_WAIT=43,
  RECORDS_CLEAR=44;
 reg [5:0] state;
 reg [5:0] after_clear_state;
 reg tracking_pending,records_clear,record_write;
 reg [7:0] record_index;reg [31:0] record_data;
 wire records_busy;
 qy_banked_records record_bank(
  .clk(clk),.rst_n(rst_n),.capture_start(records_clear),.capture_zero(1'b1),.capture_data(6144'd0),
  .write_valid(record_write),.write_index(record_index),.write_data(record_data),
  .busy(records_busy),.done(),.records(observed_boxes));
 reg [3:0] run_size,cell_row,verify_row;
 reg calibration_mode,calibration_verify,failed,point_bounds;
 reg run_anchor,anchor_checked;reg [7:0] run_anchor_index;
 // First pass records grid supports around immutable baseline points.
 // Second pass classifies every cell at the bounded whole-grid model.
 reg tracking_mode;reg [3:0] run_anchor_row,run_anchor_col;
 reg signed [2:0] frame_tx,frame_ty;reg signed [4:0] frame_sx,frame_sy;
 reg tracker_begin,tracker_write,tracker_sample_valid,tracker_solve;
 reg signed [2:0] tracker_dx,tracker_dy;
 wire tracker_done,tracker_valid;
 wire signed [2:0] candidate_tx,candidate_ty;
 wire signed [4:0] candidate_sx,candidate_sy;
 // One synchronous 256x21 table holds refined coordinates and local radii.
 // No RAM reset: calibration initializes all169 entries before any use.
 // The caller holds nominal_points stable during INIT_LOAD/INIT_WRITE.
 (* ram_style="bram" *) reg [20:0] point_table[0:255];
 (* keep="true" *) reg [7:0] table_read_address,table_write_address;
 reg [20:0] table_read_data,table_write_data;
 reg table_we;
 reg [7:0] init_index,commit_index;
 reg [16:0] init_point;
 always @(posedge clk)begin
  table_read_data<=point_table[table_read_address];
  if(table_we)point_table[table_write_address]<=table_write_data;
 end
 reg [7:0] cell_index,point_index,verify_left_index,verify_above_index;
 reg [3:0] verify_col,local_limit,cell_col;
 wire cell_active=cell_row<run_size&&cell_col<run_size;
 wire verify_active=verify_row<run_size&&verify_col<run_size;
 reg verify_has_left,verify_has_above;
 reg [16:0] verify_point,verify_left,verify_above;
 reg [8:0] gap_x_latched;reg [7:0] gap_y_latched;reg [3:0] radius_latched;
 reg [8:0] cx;reg [7:0] cy;
 reg [2:0] px,py,line_index,h_index,v_index;
 reg [10:0] hsum[0:6],vsum[0:6];
 reg [9:0] left_sum[0:6],right_sum[0:6],top_sum[0:6],bottom_sum[0:6];
 reg [9:0] left_min,left_max,right_min,right_max,top_min,top_max,bottom_min,bottom_max;
 reg [10:0] hmin,hmax,vmin,vmax;
 // One scan row of independently detected discs, not the expected game board.
 // Reject overlapping neighboring discs instead of treating a stacked/merged
 // large-stone image as a valid complete placement. Four predecessors cover
 // horizontal, vertical and both diagonal neighboring crossings.
 reg [285:0] disk_row;
 reg [21:0] disk_left,disk_upper_left,current_disk,neighbor_disk;
 reg [2:0] neighbor_index;
 reg [8:0] disk_dx;reg [7:0] disk_dy;reg [4:0] disk_radius_sum;
 reg [18:0] disk_distance2;reg [9:0] disk_radius2;
 reg [5:0] neutral,bright;
 reg [16:0] pixel_latched;
 reg [15:0] local_address;
 wire [16:0] cell_point=table_read_data[16:0];
 qy_grid_local_tracker tracker(
  .clk(clk),.rst_n(rst_n),.begin_frame(tracker_begin),
  .sample_write(tracker_write),.sample_valid(tracker_sample_valid),.sample_index(cell_index),
  .sample_row(cell_row),.sample_col(cell_col),.sample_dx(tracker_dx),.sample_dy(tracker_dy),
  .solve_start(tracker_solve),.board_size(run_size),.anchor_row(run_anchor_row),.anchor_col(run_anchor_col),
  .busy(),.done(tracker_done),.model_valid(tracker_valid),
  .tx(candidate_tx),.ty(candidate_ty),.sx(candidate_sx),.sy(candidate_sy),
  .support_count(),.support_rows(),.support_cols());
 function signed [5:0] model_delta;
  input signed [2:0] t;input signed [4:0] slope;
  input [3:0] coordinate,origin;
  reg signed [5:0] distance;reg signed [10:0] product,rounded;
  begin
   distance=$signed({2'b00,coordinate})-$signed({2'b00,origin});
   product=slope*distance;rounded=product+11'sd8;
   model_delta=$signed({{3{t[2]}},t})+(rounded>>>4);
  end
 endfunction
 wire apply_model=run_anchor&&!calibration_mode&&!tracking_mode;
 wire signed [5:0] frame_dx=apply_model?model_delta(frame_tx,frame_sx,cell_row,run_anchor_row):6'sd0;
 wire signed [5:0] frame_dy=apply_model?model_delta(frame_ty,frame_sy,cell_col,run_anchor_col):6'sd0;
 wire signed [10:0] followed_x=$signed({2'b00,cell_point[8:0]})+$signed({{5{frame_dx[5]}},frame_dx});
 wire signed [9:0] followed_y=$signed({2'b00,cell_point[16:9]})+$signed({{4{frame_dy[5]}},frame_dy});
 wire visible_paper=neutral>=32&&bright>=35;
 wire line_good=hmax>=hmin+11'd50&&vmax>=vmin+11'd50;
 wire aligned=h_index>=2&&h_index<=4&&v_index>=2&&v_index<=4;
 wire arms_good=(cell_col==0||left_max>=left_min+10'd30)&&
  (cell_col==run_size-1||right_max>=right_min+10'd30)&&
  (cell_row==0||top_max>=top_min+10'd30)&&
  (cell_row==run_size-1||bottom_max>=bottom_min+10'd30);
 wire [8:0] refined_x=cx+{6'd0,v_index}-9'd3;
 wire [7:0] refined_y=cy+{5'd0,h_index}-8'd3;
 wire [8:0] gap_x=verify_point[8:0]>=verify_left[8:0]?verify_point[8:0]-verify_left[8:0]:verify_left[8:0]-verify_point[8:0];
 wire [7:0] gap_y=verify_point[16:9]>=verify_above[16:9]?verify_point[16:9]-verify_above[16:9]:verify_above[16:9]-verify_point[16:9];
 wire [8:0] gap_min=gap_x_latched<{1'b0,gap_y_latched}?gap_x_latched:{1'b0,gap_y_latched};
 // Size tolerance is independent of center tolerance. Permit a stone diameter
 // near1.3 times the measured pitch for the user's temporary sparse-board trial.
 // Probe centers still remain within2 pixels of this exact measured crossing;
 // unknown/occluded neighboring crossings still invalidate the whole frame.
 wire [10:0] extended_radius=({2'd0,gap_min}*11'd3+11'd3)>>2;
 wire [8:0] available_radius=extended_radius[8:0];
 reg probe_start;
 (* keep="true" *) reg probe_owner;
 wire [15:0] probe_address;wire probe_busy,probe_done;wire [1:0] probe_color;
 wire [8:0] probe_x;wire [7:0] probe_y;wire [3:0] probe_radius;
 qy_grid_stone_probe #(.OFFSET_FILE(PROBE_OFFSET_FILE)) probe(
  .clk(clk),.rst_n(rst_n),.start(probe_start),.point_x(cx),.point_y(cy),.radius_limit(local_limit),
  .raw_address(probe_address),.raw_data(raw_data),.busy(probe_busy),.done(probe_done),.color(probe_color),
  .found_x(probe_x),.found_y(probe_y),.found_radius(probe_radius),.cycles());
 assign raw_address=probe_owner?probe_address:local_address;
 reg all_active_seen;
 integer visible_index;
 always @* begin
  all_active_seen=1;
  for(visible_index=0;visible_index<169;visible_index=visible_index+1)
   if(visible_index/13<board_size&&visible_index%13<board_size&&!observable[visible_index])all_active_seen=0;
 end
 assign board_observable=calibrated&&quality==0&&all_active_seen;
 integer j;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;after_clear_state<=IDLE;tracking_pending<=0;records_clear<=0;record_write<=0;record_index<=0;record_data<=0;
   run_anchor<=0;run_anchor_index<=255;anchor_checked<=0;
   tracking_mode<=0;run_anchor_row<=0;run_anchor_col<=0;
   track_tx<=0;track_ty<=0;track_sx<=0;track_sy<=0;
   frame_tx<=0;frame_ty<=0;frame_sx<=0;frame_sy<=0;
   tracker_begin<=0;tracker_write<=0;tracker_sample_valid<=0;tracker_solve<=0;tracker_dx<=0;tracker_dy<=0;
   anchor_seed_valid<=0;anchor_seed_index<=255;
   run_size<=13;board_size<=13;cell_row<=0;verify_row<=0;calibration_mode<=0;calibration_verify<=0;failed<=0;point_bounds<=0;
   table_read_address<=0;table_write_address<=0;table_write_data<=0;table_we<=0;init_index<=0;commit_index<=0;init_point<=0;cell_index<=0;point_index<=0;verify_left_index<=0;verify_above_index<=0;
   verify_col<=0;local_limit<=0;cell_col<=0;verify_has_left<=0;verify_has_above<=0;verify_point<=0;verify_left<=0;verify_above<=0;
   cx<=0;cy<=0;px<=0;py<=0;line_index<=0;h_index<=0;v_index<=0;
   gap_x_latched<=0;gap_y_latched<=0;radius_latched<=0;pixel_latched<=0;hmin<=0;hmax<=0;vmin<=0;vmax<=0;neutral<=0;bright<=0;local_address<=0;probe_start<=0;probe_owner<=0;
   busy<=0;done<=0;observation_valid<=0;calibration_done<=0;calibration_success<=0;
   disk_row<=0;disk_left<=0;disk_upper_left<=0;current_disk<=0;neighbor_disk<=0;neighbor_index<=0;
   disk_dx<=0;disk_dy<=0;disk_radius_sum<=0;disk_distance2<=0;disk_radius2<=0;
   calibrated<=0;points<=0;cells<=0;observable<=0;confidence<=0;quality<=0;observed_count<=0;
   left_min<=0;left_max<=0;right_min<=0;right_max<=0;top_min<=0;top_max<=0;bottom_min<=0;bottom_max<=0;
   for(j=0;j<7;j=j+1)begin hsum[j]<=0;vsum[j]<=0;left_sum[j]<=0;right_sum[j]<=0;top_sum[j]<=0;bottom_sum[j]<=0;end
  end else begin
   done<=0;observation_valid<=0;calibration_done<=0;probe_start<=0;table_we<=0;records_clear<=0;record_write<=0;
   tracker_begin<=0;tracker_write<=0;tracker_solve<=0;
   // Decode the next owner into a register beside the shared RAM address mux.
   probe_owner <= state==PROBE_START || (state==PROBE_WAIT && !probe_done);
   case(state)
    IDLE:if(start)begin
     busy<=1;run_size<=DYNAMIC_SIZE?(calibrate?nominal_size:board_size):4'd13;calibration_mode<=calibrate;
     run_anchor<=ORIGIN_OPENING&&(calibrate?anchor_mode:anchor_seed_valid);
     run_anchor_index<=calibrate?anchor_index_i:anchor_seed_index;anchor_checked<=0;
     run_anchor_row<=(calibrate?anchor_index_i:anchor_seed_index)/13;
     run_anchor_col<=(calibrate?anchor_index_i:anchor_seed_index)%13;
     tracking_mode<=0;tracking_pending<=ORIGIN_OPENING&&!calibrate&&anchor_seed_valid&&calibrated&&detector_error==0;
     frame_tx<=track_tx;frame_ty<=track_ty;frame_sx<=track_sx;frame_sy<=track_sy;
     calibration_verify<=0;failed<=0;quality<=0;
     cell_index<=0;cell_col<=0;cell_row<=0;cells<=0;observable<=0;confidence<=0;records_clear<=1;observed_count<=0;state<=RECORDS_CLEAR;
     disk_row<=0;disk_left<=0;disk_upper_left<=0;current_disk<=0;
     if(calibrate)begin
      calibrated<=0;calibration_success<=0;anchor_seed_valid<=0;anchor_seed_index<=255;init_index<=0;after_clear_state<=INIT_LOAD;
      if(detector_error!=0||(ORIGIN_OPENING&&anchor_mode?box_count!=1:box_count!=0)||
         (DYNAMIC_SIZE&&(nominal_size<5||nominal_size>13))||
         (ORIGIN_OPENING&&anchor_mode&&(anchor_index_i>=169||
          anchor_index_i/13>=(DYNAMIC_SIZE?nominal_size:13)||anchor_index_i%13>=(DYNAMIC_SIZE?nominal_size:13))))
       begin failed<=1;quality<=16'h0002;end
     end else if(!calibrated||detector_error!=0)begin quality<=16'h0001;after_clear_state<=FINISH;end
     else after_clear_state<=CELL_ADDR;
    end
    RECORDS_CLEAR:if(!records_clear&&!records_busy)begin
     tracking_mode<=tracking_pending;tracker_begin<=tracking_pending;state<=after_clear_state;
    end
    INIT_LOAD:begin
     init_point<=nominal_points[init_index*17+:17];state<=INIT_WRITE;
    end
    INIT_WRITE:begin
     table_we<=1;table_write_address<=init_index;table_write_data<={4'd0,init_point};
     if(init_index==168)state<=CELL_ADDR;
     else begin init_index<=init_index+1'b1;state<=INIT_LOAD;end
    end
    CELL_ADDR:begin
     table_read_address<=cell_index;
     state<=CELL_WAIT;
    end
    CELL_WAIT:state<=CELL_LOAD;
    CELL_LOAD:begin
     cx<=followed_x[8:0];cy<=followed_y[7:0];px<=0;py<=0;neutral<=0;bright<=0;
     current_disk<=0;
     local_limit<=table_read_data[20:17];
     point_bounds<=followed_x>=11'sd4&&followed_x<=11'sd315&&followed_y>=10'sd4&&followed_y<=10'sd175&&
      frame_dx>=-6'sd3&&frame_dx<=6'sd3&&frame_dy>=-6'sd3&&frame_dy<=6'sd3;
     if(tracking_mode)begin tracker_write<=1;tracker_sample_valid<=0;end
     for(j=0;j<7;j=j+1)begin hsum[j]<=0;vsum[j]<=0;left_sum[j]<=0;right_sum[j]<=0;top_sum[j]<=0;bottom_sum[j]<=0;end
     // Only the specified anchor may be covered during calibration.
     // Its original line-derived point is checked after spacing/radius.
     state<=!cell_active||(calibration_mode&&run_anchor&&cell_index==run_anchor_index)?ADVANCE:PIX_ADDR;
    end
    PIX_ADDR:begin
     if(!point_bounds)begin
      if(tracking_mode)state<=ADVANCE;
      else begin failed<=1;quality[4]<=1;state<=NEXT_CELL;end
     end
     else begin local_address<=({8'd0,cy}+{13'd0,py}-16'd3)*16'd320+{7'd0,cx}+{13'd0,px}-16'd3;state<=PIX_WAIT;end
    end
    PIX_WAIT:state<=PIX_USE;
    // Capture the shared image RAM return before the local accumulators.
    PIX_USE:begin pixel_latched<=raw_data;state<=PIX_ACCUM;end
    PIX_ACCUM:begin
     neutral<=neutral+pixel_latched[8];bright<=bright+(pixel_latched[7:0]>=80);
     hsum[py]<=hsum[py]+{3'd0,pixel_latched[16:9]};vsum[px]<=vsum[px]+{3'd0,pixel_latched[16:9]};
     if(px<3)left_sum[py]<=left_sum[py]+{2'd0,pixel_latched[16:9]};
     if(px>3)right_sum[py]<=right_sum[py]+{2'd0,pixel_latched[16:9]};
     if(py<3)top_sum[px]<=top_sum[px]+{2'd0,pixel_latched[16:9]};
     if(py>3)bottom_sum[px]<=bottom_sum[px]+{2'd0,pixel_latched[16:9]};
     if(px==6)begin px<=0;if(py==6)state<=LINE_INIT;else begin py<=py+1'b1;state<=PIX_ADDR;end end
     else begin px<=px+1'b1;state<=PIX_ADDR;end
    end
    LINE_INIT:begin
     hmin<=2047;hmax<=0;vmin<=2047;vmax<=0;h_index<=0;v_index<=0;line_index<=0;
     left_min<=1023;left_max<=0;right_min<=1023;right_max<=0;top_min<=1023;top_max<=0;bottom_min<=1023;bottom_max<=0;
     state<=LINE_SCAN;
    end
    LINE_SCAN:begin
     if(hsum[line_index]<hmin)begin hmin<=hsum[line_index];h_index<=line_index;end
     if(hsum[line_index]>hmax)hmax<=hsum[line_index];
     if(vsum[line_index]<vmin)begin vmin<=vsum[line_index];v_index<=line_index;end
     if(vsum[line_index]>vmax)vmax<=vsum[line_index];
     if(left_sum[line_index]<left_min)left_min<=left_sum[line_index];
     if(left_sum[line_index]>left_max)left_max<=left_sum[line_index];
     if(right_sum[line_index]<right_min)right_min<=right_sum[line_index];
     if(right_sum[line_index]>right_max)right_max<=right_sum[line_index];
     if(top_sum[line_index]<top_min)top_min<=top_sum[line_index];
     if(top_sum[line_index]>top_max)top_max<=top_sum[line_index];
     if(bottom_sum[line_index]<bottom_min)bottom_min<=bottom_sum[line_index];
     if(bottom_sum[line_index]>bottom_max)bottom_max<=bottom_sum[line_index];
     if(line_index==6)state<=CLASSIFY;else line_index<=line_index+1'b1;
    end
    CLASSIFY:begin
     if(tracking_mode)begin
      if(visible_paper&&line_good&&arms_good&&cell_index!=run_anchor_index)begin
       tracker_write<=1;tracker_sample_valid<=1;
       tracker_dx<=$signed({1'b0,v_index})-4'sd3;tracker_dy<=$signed({1'b0,h_index})-4'sd3;
      end
      state<=ADVANCE;
     end else if(calibration_mode)begin
      if(visible_paper&&line_good&&arms_good&&(!calibration_verify||aligned))begin
       if(!calibration_verify)begin
        table_we<=1;table_write_address<=cell_index;table_write_data<={4'd0,refined_y,refined_x};
       end
      end else begin failed<=1;quality[5]<=1;end
      state<=NEXT_CELL;
     end else if(run_anchor&&cell_index==run_anchor_index)begin
      // An empty-looking origin must never hide a removed anchor.
      state<=PROBE_START;
     end else if(visible_paper&&line_good&&arms_good&&aligned)begin
      cells[cell_index*2+:2]<=0;observable[cell_index]<=1;confidence[cell_index*8+:8]<=255;state<=NEXT_CELL;
     end else state<=PROBE_START;
    end
    PROBE_START:begin probe_start<=1;state<=PROBE_WAIT;end
    PROBE_WAIT:if(probe_done)state<=calibration_mode?ANCHOR_CHECK:PROBE_ACCEPT;
    PROBE_ACCEPT:begin
     if(run_anchor&&cell_index==run_anchor_index&&probe_color!=1)quality[9]<=1;
     if(probe_color==1||probe_color==2)begin
      cells[cell_index*2+:2]<=probe_color;observable[cell_index]<=1;confidence[cell_index*8+:8]<=255;
      record_write<=1;record_index<=cell_index;record_data<={8'hff,1'b1,probe_color,probe_radius,probe_y,probe_x};
      observed_count<=observed_count+1'b1;
      current_disk<={1'b1,probe_radius,probe_y,probe_x};
     end else begin cells[cell_index*2+:2]<=3;quality[6]<=1;end
     state<=NEXT_CELL;
    end
    NEXT_CELL:begin
     neighbor_index<=0;
     state<=calibration_mode?ADVANCE:current_disk[21]?DISK_LOAD:DISK_SAVE;
    end
    DISK_LOAD:begin
     case(neighbor_index)
      0:neighbor_disk<=cell_col>0?disk_left:22'd0;
      1:neighbor_disk<=cell_index>=13?disk_row[cell_col*22+:22]:22'd0;
      2:neighbor_disk<=cell_index>=13&&cell_col>0?disk_upper_left:22'd0;
      3:neighbor_disk<=cell_index>=13&&cell_col<run_size-1?disk_row[(cell_col+1'b1)*22+:22]:22'd0;
      default:neighbor_disk<=0;
     endcase
     state<=DISK_DIFF;
    end
    DISK_DIFF:begin
     disk_dx<=current_disk[8:0]>=neighbor_disk[8:0]?current_disk[8:0]-neighbor_disk[8:0]:neighbor_disk[8:0]-current_disk[8:0];
     disk_dy<=current_disk[16:9]>=neighbor_disk[16:9]?current_disk[16:9]-neighbor_disk[16:9]:neighbor_disk[16:9]-current_disk[16:9];
     disk_radius_sum<={1'b0,current_disk[20:17]}+{1'b0,neighbor_disk[20:17]};
     state<=DISK_SQUARE;
    end
    DISK_SQUARE:begin
     disk_distance2<={10'd0,disk_dx}*{10'd0,disk_dx}+{11'd0,disk_dy}*{11'd0,disk_dy};
     disk_radius2<={5'd0,disk_radius_sum}*{5'd0,disk_radius_sum};
     state<=DISK_CHECK;
    end
    DISK_CHECK:begin
     if(neighbor_disk[21]&&disk_distance2<{9'd0,disk_radius2})quality[8]<=1;
     if(neighbor_index==3)state<=DISK_SAVE;
     else begin neighbor_index<=neighbor_index+1'b1;state<=DISK_LOAD;end
    end
    DISK_SAVE:begin
     disk_upper_left<=disk_row[cell_col*22+:22];disk_row[cell_col*22+:22]<=current_disk;
     disk_left<=current_disk;state<=ADVANCE;
    end
    ADVANCE:if(cell_index==168)begin
     if(tracking_mode)state<=TRACK_SOLVE;
     else if(calibration_mode&&!calibration_verify)begin calibration_verify<=1;cell_index<=0;cell_col<=0;cell_row<=0;state<=CELL_ADDR;end
     else state<=calibration_mode?VERIFY_INIT:FINISH;
    end else begin cell_index<=cell_index+1'b1;cell_col<=cell_col==12?0:cell_col+1'b1;if(cell_col==12)cell_row<=cell_row+1'b1;state<=CELL_ADDR;end
    TRACK_SOLVE:begin tracker_solve<=1;state<=TRACK_WAIT;end
    TRACK_WAIT:if(tracker_done)begin
     // Insufficient visible grid support freezes the last accepted transform.
     // It does not label a cell empty: the full strict observation still runs.
     if(tracker_valid)begin frame_tx<=candidate_tx;frame_ty<=candidate_ty;frame_sx<=candidate_sx;frame_sy<=candidate_sy;end
     tracking_mode<=0;cell_index<=0;cell_col<=0;cell_row<=0;state<=CELL_ADDR;
    end
    VERIFY_INIT:begin point_index<=0;verify_col<=0;verify_row<=0;state<=VERIFY_INDEX;end
    VERIFY_INDEX:begin
     verify_left_index<=verify_col!=0?point_index-1'b1:point_index+1'b1;
     verify_above_index<=point_index>=13?point_index-8'd13:point_index+8'd13;
     verify_has_left<=verify_col!=0;verify_has_above<=point_index>=13;table_read_address<=point_index;state<=VERIFY_POINT_WAIT;
    end
    VERIFY_POINT_WAIT:state<=VERIFY_POINT_USE;
    VERIFY_POINT_USE:begin
     verify_point<=table_read_data[16:0];table_read_address<=verify_left_index;state<=VERIFY_LEFT_WAIT;
    end
    VERIFY_LEFT_WAIT:state<=VERIFY_LEFT_USE;
    VERIFY_LEFT_USE:begin
     verify_left<=table_read_data[16:0];table_read_address<=verify_above_index;state<=VERIFY_ABOVE_WAIT;
    end
    VERIFY_ABOVE_WAIT:state<=VERIFY_LOAD;
    VERIFY_LOAD:begin verify_above<=table_read_data[16:0];state<=VERIFY_GAPS;end
    // Register spacing and radius separately before the indexed radius write.
    VERIFY_GAPS:begin gap_x_latched<=gap_x;gap_y_latched<=gap_y;state<=VERIFY_RADIUS;end
    VERIFY_RADIUS:begin radius_latched<=available_radius>11?4'd11:available_radius[3:0];state<=VERIFY_CHECK;end
    VERIFY_CHECK:begin
     if(verify_active&&(verify_point[8:0]<4||verify_point[8:0]>315||verify_point[16:9]<4||verify_point[16:9]>175||
        gap_min<8||
        (verify_has_left&&{1'b0,verify_point[8:0]}<{1'b0,verify_left[8:0]}+10'd8)||
        (verify_has_above&&{1'b0,verify_point[16:9]}<{1'b0,verify_above[16:9]}+9'd8)))begin failed<=1;quality[7]<=1;end
     table_we<=1;table_write_address<=point_index;table_write_data<={radius_latched,verify_point};
     if(point_index==168)state<=FINISH;
     else begin point_index<=point_index+1'b1;verify_col<=verify_col==12?0:verify_col+1'b1;if(verify_col==12)verify_row<=verify_row+1'b1;state<=VERIFY_INDEX;end
    end
    ANCHOR_ADDR:begin table_read_address<=run_anchor_index;state<=ANCHOR_WAIT;end
    ANCHOR_WAIT:state<=ANCHOR_LOAD;
    ANCHOR_LOAD:begin
     cx<=cell_point[8:0];cy<=cell_point[16:9];local_limit<=table_read_data[20:17];
     state<=PROBE_START;
    end
    ANCHOR_CHECK:begin
     anchor_checked<=1;
     if(probe_color!=1)begin failed<=1;quality[9]<=1;end
     state<=FINISH;
    end
    FINISH:if(!records_busy&&!record_write)begin
     if(calibration_mode&&!failed&&run_anchor&&!anchor_checked)state<=ANCHOR_ADDR;
     else if(calibration_mode&&!failed)begin commit_index<=0;state<=COMMIT_ADDR;end
     else begin
      busy<=0;done<=1;state<=IDLE;
      if(calibration_mode)begin calibration_done<=1;calibration_success<=0;calibrated<=0;end
      else begin
       observation_valid<=1;
       // No model is published from a partially observed or rejected frame.
       if(run_anchor&&quality==0)begin track_tx<=frame_tx;track_ty<=frame_ty;track_sx<=frame_sx;track_sy<=frame_sy;end
      end
     end
    end
    // Publish validity only after the complete verified table is copied out.
    // A failed calibration never enters this commit loop or changes points.
    COMMIT_ADDR:begin table_read_address<=commit_index;state<=COMMIT_WAIT;end
    COMMIT_WAIT:state<=COMMIT_USE;
    COMMIT_USE:begin
     points[commit_index*17+:17]<=table_read_data[16:0];
     if(commit_index==168)begin
      board_size<=run_size;calibration_done<=1;calibration_success<=1;calibrated<=1;
      anchor_seed_valid<=run_anchor;anchor_seed_index<=run_anchor?run_anchor_index:8'd255;
      track_tx<=0;track_ty<=0;track_sx<=0;track_sy<=0;
      busy<=0;done<=1;state<=IDLE;
     end else begin commit_index<=commit_index+1'b1;state<=COMMIT_ADDR;end
    end
    default:begin state<=IDLE;busy<=0;quality<=16'h8000;calibrated<=0;end
   endcase
  end
 end
endmodule
`default_nettype wire
