`timescale 1ns/1ps
// qy-window-ab-v1, bounded FPGA port of tools/gomoku_search.py.
// 13x13 freestyle; strict_turn=False permits the two teaching perspectives.
// All five-cell windows and tactical winning cells are global. Only ordinary
// candidates use radius 2 / top K. No transposition table is used (tt_capacity=0).
// Each node is scanned serially; all descendants share the window arithmetic.
// Root moves use full alpha/beta windows and only a whole iterative layer may
// replace the published recommendation. score_o is SIGNED, uncalibrated, NOT a
// probability. completed_depth_o==0 means legacy fallback and score_o==0.
module qy_gomoku_search #(
    parameter BOARD_SIZE = 13, parameter DYNAMIC_SIZE = 0,
    parameter MAX_DEPTH = 3,
    parameter NODE_BUDGET = 20000,
    parameter CANDIDATE_LIMIT = 12
)(
    input wire clk_i, rst_n_i, start_i, cancel_i,
    input wire [449:0] board_i,
    input wire [3:0] board_size_i,
    input wire [1:0] color_i,
    input wire [31:0] state_version_i,
    output reg busy_o, done_o, result_valid_o,
    output reg [3:0] row_o, col_o,
    output reg [31:0] score_o, result_version_o,
    output reg [1:0] reason_o,
    output reg [2:0] completed_depth_o,
    output reg [31:0] nodes_o,
    output reg budget_exhausted_o, fallback_used_o
);
    localparam signed [31:0] MATE=32'sd1000000, INF=32'sd2000000;
    localparam [6:0] IDLE=0, COPY_ADDR=1, COPY_READ=2, COPY_STORE=3,
      NODE_BEGIN=4, CLEAR_PRIORITY=5, WINDOW_BEGIN=6, WINDOW_VALID=7,
      WINDOW_ADDR=8, WINDOW_READ=9, WINDOW_COUNT=10, WINDOW_TERM=11,
      PRIORITY_SELECT=12, PRIORITY_READ=13, PRIORITY_WRITE=14,
      WINDOW_NEXT=15, NODE_DECIDE=16, CANDIDATE_BEGIN=17,
      NEAR_ADDR=18, NEAR_READ=19, NEAR_CHECK=20, NEAR_MARK=21,
      NEAR_NEXT=22, SCAN_ADDR=23, SCAN_READ=24, SCAN_CHECK=25,
      SCAN_PRIORITY=26, INSERT_FIND=27, INSERT_SHIFT=28,
      INSERT_STORE=29, SCAN_NEXT=30, TOP_WRITE=31, CANDIDATE_DONE=32,
      FALLBACK_WAIT=33, FALLBACK_READ=34, FALLBACK_CHECK=35,
      ROOT_START=36, FETCH_MOVE=37, PLAY_MOVE=38, NODE_TICK=39,
      RETURN_NODE=40, CHILD_RESULT=41, CHILD_NEXT=42,
      LAYER_DONE=43, FINISH=44, INVALID=45, OUTPUT_COORD=46,
      FETCH_WAIT=47, FETCH_USE=48, FALLBACK_RAM_WAIT=49, FALLBACK_RAM_USE=50;
    reg [6:0] state;
    reg [3:0] active_size;
    wire [3:0] requested_size=DYNAMIC_SIZE?board_size_i:BOARD_SIZE;
    wire [3:0] center=(active_size-1)>>1;
    wire [7:0] active_count=active_size*active_size;
    reg [449:0] snapshot;
    // The small mutable search board is initialized explicitly, never reset as
    // an array. Candidate and priority arrays also have clocked reads/writes.
    reg [1:0] cells [0:168];
    reg [21:0] priorities [0:168];
    (* ram_style = "bram" *) reg [7:0] candidate_mem [0:1023];
    // Keep both ports synchronous and independent of the FSM/reset muxes.
    // The routed predecessor exposed cursor -> large distributed-RAM mux ->
    // move_cell in one cycle. The private table needs no reset: each node
    // writes every entry below count[sp] before any candidate is fetched.
    (* keep = "true" *) reg [9:0] candidate_read_addr_q, candidate_write_addr_q;
    (* keep = "true" *) reg candidate_write_en_q;
    (* keep = "true" *) reg [7:0] candidate_write_data_q;
    reg [7:0] candidate_read_q;
    reg [1:0] side [0:3];
    reg [2:0] remaining [0:3];
    reg signed [31:0] alpha [0:3], beta [0:3], best [0:3];
    reg [7:0] count [0:3], cursor [0:3], last_move [0:3];
    reg [1:0] sp;
    reg [31:0] version;
    reg [7:0] empty_count, cell_index;
    // TD can absorb a conditional read address FF into an ERAM and expose its
    // synchronous reset as a combinational RAM address mux. Native keep retains
    // the physical boundary (the same pattern as qy_camera_thumbnail).
    (* keep = "true" *) reg [7:0] cell_addr;
    (* keep = "true" *) reg cells_write_en_q, priorities_write_en_q;
    (* keep = "true" *) reg [7:0] cells_write_addr_q, priorities_write_addr_q;
    (* keep = "true" *) reg [1:0] cells_write_data_q;
    (* keep = "true" *) reg [21:0] priorities_write_data_q;
    reg [1:0] cells_read_q;
    reg [21:0] priorities_read_q;
    reg [3:0] scan_r, scan_c;
    wire scan_active=scan_r<active_size && scan_c<active_size;
    reg [1:0] cell_value;
    reg [7:0] source_addr;
    reg invalid_input;
    reg need_priority;
    reg [168:0] wins_black, wins_white, nearby;
    reg [7:0] wins_black_count, wins_white_count;
    reg winner_black, winner_white;
    reg signed [31:0] evaluation;
    reg [3:0] window_r, window_c, ray_r, ray_c;
    reg [1:0] direction;
    reg [2:0] window_pos, black_count, white_count;
    reg [4:0] empty_flags;
    reg [7:0] window_cells [0:4];
    reg [7:0] last_empty;
    reg [21:0] window_delta, priority_value;
    reg [1:0] candidate_mode; // 0 ordinary, 1 own wins, 2 forced defenses
    reg [7:0] candidate_count;
    reg signed [5:0] near_r, near_c;
    reg [2:0] near_dr, near_dc;
    reg [3:0] top_count, insert_index, shift_index, write_index;
    reg [7:0] top_cells [0:11];
    reg [21:0] top_values [0:11];
    reg [4:0] top_distances [0:11];
    reg [4:0] candidate_distance;
    reg [7:0] move_cell, returned_move;
    reg signed [31:0] node_value, returned_value;
    reg [2:0] iteration_depth, published_depth;
    reg signed [31:0] layer_best, published_score;
    reg [7:0] layer_cell, published_cell;
    reg [1:0] root_reason;
    reg [7:0] fallback_cell, fallback_scan;
    reg fallback_seen, fallback_valid, fallback_member;
    reg [7:0] legacy_cell;
    reg [3:0] output_row;
    reg [7:0] output_remainder;
    wire legacy_busy, legacy_done, legacy_valid;
    wire [3:0] legacy_row, legacy_col;
    wire [31:0] legacy_score, legacy_version;
    wire [1:0] legacy_reason;
    wire accept_start = start_i && !busy_o && !cancel_i;
    // A terminal/invalid request can finish before the legacy scan. Cancel it
    // on that same edge so the next accepted request gets its own fallback.
    wire legacy_cancel = cancel_i || (state==INVALID) ||
                         (busy_o && (state_version_i!=version || requested_size!=active_size));
    qy_gomoku_ai #(.BOARD_SIZE(13),.DYNAMIC_SIZE(DYNAMIC_SIZE)) fallback_ai (
      .clk_i(clk_i), .rst_n_i(rst_n_i), .start_i(accept_start),
      .cancel_i(legacy_cancel), .board_i(board_i), .board_size_i(requested_size), .color_i(color_i),
      .state_version_i(state_version_i), .busy_o(legacy_busy),
      .done_o(legacy_done), .result_valid_o(legacy_valid),
      .row_o(legacy_row), .col_o(legacy_col), .score_o(legacy_score),
      .result_version_o(legacy_version), .reason_o(legacy_reason)
    );

    function [7:0] addr13;
      input [3:0] r,c;
      begin addr13=({4'b0,r}<<3)+({4'b0,r}<<2)+{4'b0,r}+{4'b0,c}; end
    endfunction
    function [7:0] addr15;
      input [3:0] r,c;
      begin addr15=({4'b0,r}<<4)-{4'b0,r}+{4'b0,c}; end
    endfunction
    function [4:0] center_distance;
      input [3:0] r,c;
      reg [4:0] dr,dc;
      begin dr=(r>center)?r-center:center-r; dc=(c>center)?c-center:center-c; center_distance=dr+dc; end
    endfunction
    function [21:0] weight;
      input [2:0] n;
      begin case(n)
        1:weight=1; 2:weight=8; 3:weight=64;
        4:weight=512; 5:weight=100000; default:weight=0;
      endcase end
    endfunction
    function [21:0] delta_weight;
      input [2:0] own,other;
      begin
        if(other==0) delta_weight=weight(own+3'd1)-weight(own);
        else if(own==0) delta_weight=weight(other);
        else delta_weight=0;
      end
    endfunction

    // synthesis translate_off
    initial begin
      if(BOARD_SIZE!=13 || MAX_DEPTH<1 || MAX_DEPTH>3 || NODE_BUDGET<1 ||
         NODE_BUDGET>20000 || CANDIDATE_LIMIT<1 || CANDIDATE_LIMIT>12) begin
        $display("CONFIG_ERROR: qy_gomoku_search requires 13x13, depth 1..3, budget 1..20000, top K 1..12");
        $finish;
      end
    end
    // synthesis translate_on

    // Physical RAM ports only see kept synchronous registers. No reset,
    // cancellation, version comparison or state decode gates these accesses.
    // One already-issued private write can retire on a cancel/reset edge; a new
    // request overwrites every board cell before reading, and every node clears
    // all priorities before use. No cancelled result is published.
    always @(posedge clk_i) begin
      if(cells_write_en_q) cells[cells_write_addr_q]<=cells_write_data_q;
      if(priorities_write_en_q) priorities[priorities_write_addr_q]<=priorities_write_data_q;
      cells_read_q<=cells[cell_addr];
      priorities_read_q<=priorities[cell_addr];
      if(candidate_write_en_q) candidate_mem[candidate_write_addr_q]<=candidate_write_data_q;
      candidate_read_q<=candidate_mem[candidate_read_addr_q];
    end

    always @(posedge clk_i) begin
      if(!rst_n_i) begin
        cells_write_en_q<=0; priorities_write_en_q<=0;
        candidate_write_en_q<=0;candidate_read_addr_q<=0;candidate_write_addr_q<=0;candidate_write_data_q<=0;
        cells_write_addr_q<=0; priorities_write_addr_q<=0;
        cells_write_data_q<=0; priorities_write_data_q<=0;
        state<=IDLE; busy_o<=0; done_o<=0; result_valid_o<=0; active_size<=BOARD_SIZE;
        row_o<=0; col_o<=0; score_o<=0; result_version_o<=0; reason_o<=3;
        completed_depth_o<=0; nodes_o<=0; budget_exhausted_o<=0; fallback_used_o<=0;
        snapshot<=0; version<=0; sp<=0; cell_index<=0; cell_addr<=0;
        scan_r<=0; scan_c<=0; source_addr<=0; cell_value<=0;
        empty_count<=0; invalid_input<=0; need_priority<=0;
        wins_black<=0; wins_white<=0; nearby<=0;
        wins_black_count<=0; wins_white_count<=0;
        winner_black<=0; winner_white<=0; evaluation<=0;
        window_r<=0; window_c<=0; ray_r<=0; ray_c<=0; direction<=0;
        window_pos<=0; black_count<=0; white_count<=0; empty_flags<=0;
        last_empty<=0; window_delta<=0; priority_value<=0;
        candidate_mode<=0; candidate_count<=0; near_r<=0; near_c<=0;
        near_dr<=0; near_dc<=0; top_count<=0; insert_index<=0;
        shift_index<=0; write_index<=0; candidate_distance<=0;
        move_cell<=0; returned_move<=0; node_value<=0; returned_value<=0;
        iteration_depth<=0; published_depth<=0; layer_best<=-INF;
        published_score<=0; layer_cell<=255; published_cell<=0; root_reason<=3;
        fallback_cell<=0; fallback_scan<=0; fallback_seen<=0; fallback_valid<=0;
        fallback_member<=0; legacy_cell<=0; output_row<=0; output_remainder<=0;
      end else begin
        cells_write_en_q<=0; priorities_write_en_q<=0;
        candidate_write_en_q<=0;
        done_o<=0;
        if(legacy_done && busy_o) begin
          fallback_seen<=1; fallback_valid<=legacy_valid;
          legacy_cell<=addr13(legacy_row,legacy_col);
        end
        if(cancel_i) begin
          state<=IDLE; busy_o<=0; result_valid_o<=0; reason_o<=3;
        end else if(busy_o && (state_version_i!=version || requested_size!=active_size)) begin
          state<=IDLE; busy_o<=0; done_o<=1; result_valid_o<=0;
          score_o<=0; reason_o<=3;
        end else begin
          if(result_valid_o && (state_version_i!=result_version_o || requested_size!=active_size)) result_valid_o<=0;
          case(state)
            IDLE: if(start_i) begin
              snapshot<=board_i; version<=state_version_i; active_size<=requested_size; result_version_o<=state_version_i;
              side[0]<=color_i; sp<=0; busy_o<=1; result_valid_o<=0;
              score_o<=0; reason_o<=3; completed_depth_o<=0; nodes_o<=0;
              budget_exhausted_o<=0; fallback_used_o<=0;
              scan_r<=0; scan_c<=0; cell_index<=0; empty_count<=0;
              invalid_input<=0; published_depth<=0; published_score<=0;
              fallback_seen<=0; fallback_valid<=0; fallback_member<=0;
              state<=COPY_ADDR;
            end
            COPY_ADDR: begin source_addr<=addr15(scan_r,scan_c); state<=COPY_READ; end
            COPY_READ: begin cell_value<=snapshot[{source_addr,1'b0} +: 2]; state<=COPY_STORE; end
            COPY_STORE: begin
              cells_write_en_q<=1; cells_write_addr_q<=cell_index; cells_write_data_q<=scan_active?cell_value:2'd3;
              if(scan_active&&cell_value==0) empty_count<=empty_count+1'b1;
              if(scan_active&&cell_value==3) invalid_input<=1;
              if(cell_index==168) begin
                if((scan_active&&cell_value==3) || invalid_input || active_size<5 || active_size>13 || (side[0]!=1 && side[0]!=2)) state<=INVALID;
                else state<=NODE_BEGIN;
              end else begin
                cell_index<=cell_index+1'b1;
                if(scan_c==12) begin scan_c<=0; scan_r<=scan_r+1'b1; end
                else scan_c<=scan_c+1'b1;
                state<=COPY_ADDR;
              end
            end
            NODE_TICK: begin
              if(nodes_o>=NODE_BUDGET) begin budget_exhausted_o<=1; state<=FINISH; end
              else begin nodes_o<=nodes_o+1'b1; state<=NODE_BEGIN; end
            end
            NODE_BEGIN: begin
              wins_black<=0; wins_white<=0; wins_black_count<=0; wins_white_count<=0;
              winner_black<=0; winner_white<=0; evaluation<=0;
              need_priority<= (sp==0 || remaining[sp]!=0);
              cell_index<=0;
              if(sp==0 || remaining[sp]!=0) state<=CLEAR_PRIORITY;
              else state<=WINDOW_BEGIN;
            end
            CLEAR_PRIORITY: begin
              priorities_write_en_q<=1; priorities_write_addr_q<=cell_index; priorities_write_data_q<=0;
              if(cell_index==168) state<=WINDOW_BEGIN;
              else cell_index<=cell_index+1'b1;
            end
            WINDOW_BEGIN: begin window_r<=0; window_c<=0; direction<=0; state<=WINDOW_VALID; end
            WINDOW_VALID: begin
              if(window_r<active_size && window_c<active_size && ((direction==0 && window_c+4<active_size) ||
                 (direction==1 && window_r+4<active_size) ||
                 (direction==2 && window_r+4<active_size && window_c+4<active_size) ||
                 (direction==3 && window_r+4<active_size && window_c>=4))) begin
                ray_r<=window_r; ray_c<=window_c; window_pos<=0;
                black_count<=0; white_count<=0; empty_flags<=0;
                state<=WINDOW_ADDR;
              end else state<=WINDOW_NEXT;
            end
            WINDOW_ADDR: begin cell_addr<=addr13(ray_r,ray_c); state<=WINDOW_READ; end
            WINDOW_READ: begin state<=WINDOW_COUNT; end
            WINDOW_COUNT: begin
              window_cells[window_pos]<=cell_addr;
              if(cells_read_q==1) black_count<=black_count+1'b1;
              else if(cells_read_q==2) white_count<=white_count+1'b1;
              else begin empty_flags[window_pos]<=1; last_empty<=cell_addr; end
              if(window_pos==4) state<=WINDOW_TERM;
              else begin
                window_pos<=window_pos+1'b1;
                if(direction!=0) ray_r<=ray_r+1'b1;
                if(direction==0 || direction==2) ray_c<=ray_c+1'b1;
                else if(direction==3) ray_c<=ray_c-1'b1;
                state<=WINDOW_ADDR;
              end
            end
            WINDOW_TERM: begin
              if(white_count==0) evaluation<=evaluation+$signed({10'b0,weight(black_count)});
              else if(black_count==0) evaluation<=evaluation-$signed({10'b0,weight(white_count)});
              if(black_count==5) winner_black<=1;
              if(white_count==5) winner_white<=1;
              if(black_count==4 && white_count==0) begin
                wins_black[last_empty]<=1;
                if(!wins_black[last_empty]) wins_black_count<=wins_black_count+1'b1;
              end
              if(white_count==4 && black_count==0) begin
                wins_white[last_empty]<=1;
                if(!wins_white[last_empty]) wins_white_count<=wins_white_count+1'b1;
              end
              window_delta <= (side[sp]==1) ? delta_weight(black_count,white_count) : delta_weight(white_count,black_count);
              window_pos<=0;
              state<=need_priority ? PRIORITY_SELECT : WINDOW_NEXT;
            end
            PRIORITY_SELECT: begin
              if(empty_flags[window_pos]) begin cell_addr<=window_cells[window_pos]; state<=PRIORITY_READ; end
              else if(window_pos==4) state<=WINDOW_NEXT;
              else window_pos<=window_pos+1'b1;
            end
            PRIORITY_READ: begin state<=PRIORITY_WRITE; end
            PRIORITY_WRITE: begin
              priorities_write_en_q<=1; priorities_write_addr_q<=cell_addr; priorities_write_data_q<=priorities_read_q+window_delta;
              if(window_pos==4) state<=WINDOW_NEXT;
              else begin window_pos<=window_pos+1'b1; state<=PRIORITY_SELECT; end
            end
            WINDOW_NEXT: begin
              if(direction!=3) begin direction<=direction+1'b1; state<=WINDOW_VALID; end
              else if(window_c!=12) begin direction<=0; window_c<=window_c+1'b1; state<=WINDOW_VALID; end
              else if(window_r!=12) begin direction<=0; window_c<=0; window_r<=window_r+1'b1; state<=WINDOW_VALID; end
              else state<=NODE_DECIDE;
            end
            NODE_DECIDE: begin
              if(sp==0) begin
                if(winner_black || winner_white || empty_count==0) state<=INVALID;
                else state<=CANDIDATE_BEGIN;
              end else if(winner_black || winner_white) begin
                node_value<= ((side[sp]==1 && winner_black) || (side[sp]==2 && winner_white)) ? MATE-$signed({30'b0,sp}) : -MATE+$signed({30'b0,sp});
                state<=RETURN_NODE;
              end else if(empty_count==0) begin node_value<=0; state<=RETURN_NODE; end
              else if((side[sp]==1 && wins_black_count!=0) || (side[sp]==2 && wins_white_count!=0)) begin
                node_value<=MATE-$signed({30'b0,sp})-1; state<=RETURN_NODE;
              end else if((side[sp]==1 && wins_white_count>=2) || (side[sp]==2 && wins_black_count>=2)) begin
                node_value<=-MATE+$signed({30'b0,sp})+2; state<=RETURN_NODE;
              end else if(remaining[sp]==0) begin
                node_value<=(side[sp]==1) ? evaluation : -evaluation; state<=RETURN_NODE;
              end else state<=CANDIDATE_BEGIN;
            end
            CANDIDATE_BEGIN: begin
              cell_index<=0; scan_r<=0; scan_c<=0; candidate_count<=0; top_count<=0; nearby<=0;
              if((side[sp]==1 && wins_black_count!=0) || (side[sp]==2 && wins_white_count!=0)) begin
                candidate_mode<=1; if(sp==0) root_reason<=1; state<=SCAN_ADDR;
              end else if((side[sp]==1 && wins_white_count!=0) || (side[sp]==2 && wins_black_count!=0)) begin
                candidate_mode<=2; if(sp==0) root_reason<=2; state<=SCAN_ADDR;
              end else if(empty_count==active_count) begin
                candidate_write_en_q<=1;candidate_write_addr_q<={sp,8'b0};
                candidate_write_data_q<=addr13(center,center); count[sp]<=1; cursor[sp]<=0;
                candidate_mode<=0; if(sp==0) root_reason<=0; state<=CANDIDATE_DONE;
              end else begin
                candidate_mode<=0; if(sp==0) root_reason<=0; state<=NEAR_ADDR;
              end
            end
            NEAR_ADDR: begin cell_addr<=cell_index; state<=NEAR_READ; end
            NEAR_READ: begin state<=NEAR_CHECK; end
            NEAR_CHECK: begin
              if(cells_read_q!=1&&cells_read_q!=2) state<=NEAR_NEXT;
              else begin near_dr<=0; near_dc<=0; near_r<=$signed({2'b0,scan_r})-2; near_c<=$signed({2'b0,scan_c})-2; state<=NEAR_MARK; end
            end
            NEAR_MARK: begin
              if(near_r>=0 && near_r<active_size && near_c>=0 && near_c<active_size) nearby[addr13(near_r[3:0],near_c[3:0])]<=1;
              if(near_dc<4) begin near_dc<=near_dc+1'b1; near_c<=near_c+1'b1; end
              else if(near_dr<4) begin near_dc<=0; near_dr<=near_dr+1'b1; near_r<=near_r+1'b1; near_c<=$signed({2'b0,scan_c})-2; end
              else state<=NEAR_NEXT;
            end
            NEAR_NEXT: begin
              if(cell_index==168) begin cell_index<=0; scan_r<=0; scan_c<=0; state<=SCAN_ADDR; end
              else begin
                cell_index<=cell_index+1'b1;
                if(scan_c==12) begin scan_c<=0; scan_r<=scan_r+1'b1; end
                else scan_c<=scan_c+1'b1;
                state<=NEAR_ADDR;
              end
            end
            SCAN_ADDR: begin cell_addr<=cell_index; state<=SCAN_READ; end
            SCAN_READ: begin state<=SCAN_CHECK; end
            SCAN_CHECK: begin
              if(cells_read_q!=0) state<=SCAN_NEXT;
              else if(candidate_mode!=0) begin
                if((candidate_mode==1 && ((side[sp]==1 && wins_black[cell_index]) || (side[sp]==2 && wins_white[cell_index]))) ||
                   (candidate_mode==2 && ((side[sp]==1 && wins_white[cell_index]) || (side[sp]==2 && wins_black[cell_index])))) begin
                  candidate_write_en_q<=1;candidate_write_addr_q<={sp,candidate_count};
                  candidate_write_data_q<=cell_index; candidate_count<=candidate_count+1'b1;
                end
                state<=SCAN_NEXT;
              end else if(nearby[cell_index]) begin
                candidate_distance<=center_distance(scan_r,scan_c); state<=SCAN_PRIORITY;
              end else state<=SCAN_NEXT;
            end
            SCAN_PRIORITY: begin priority_value<=priorities_read_q; insert_index<=0; state<=INSERT_FIND; end
            INSERT_FIND: begin
              if(insert_index>=top_count) begin
                if(top_count<CANDIDATE_LIMIT) begin shift_index<=top_count; state<=INSERT_STORE; end
                else state<=SCAN_NEXT;
              end else if(priority_value>top_values[insert_index] ||
                (priority_value==top_values[insert_index] && candidate_distance<top_distances[insert_index]) ||
                (priority_value==top_values[insert_index] && candidate_distance==top_distances[insert_index] && cell_index<top_cells[insert_index])) begin
                shift_index<=(top_count<CANDIDATE_LIMIT) ? top_count : CANDIDATE_LIMIT-1;
                state<=INSERT_SHIFT;
              end else insert_index<=insert_index+1'b1;
            end
            INSERT_SHIFT: begin
              if(shift_index>insert_index) begin
                top_cells[shift_index]<=top_cells[shift_index-1'b1];
                top_values[shift_index]<=top_values[shift_index-1'b1];
                top_distances[shift_index]<=top_distances[shift_index-1'b1];
                shift_index<=shift_index-1'b1;
              end else state<=INSERT_STORE;
            end
            INSERT_STORE: begin
              top_cells[insert_index]<=cell_index; top_values[insert_index]<=priority_value;
              top_distances[insert_index]<=candidate_distance;
              if(top_count<CANDIDATE_LIMIT) top_count<=top_count+1'b1;
              state<=SCAN_NEXT;
            end
            SCAN_NEXT: begin
              if(cell_index==168) begin
                if(candidate_mode!=0) begin count[sp]<=candidate_count; cursor[sp]<=0; state<=CANDIDATE_DONE; end
                else begin write_index<=0; state<=TOP_WRITE; end
              end else begin
                cell_index<=cell_index+1'b1;
                if(scan_c==12) begin scan_c<=0; scan_r<=scan_r+1'b1; end
                else scan_c<=scan_c+1'b1;
                state<=SCAN_ADDR;
              end
            end
            TOP_WRITE: begin
              candidate_write_en_q<=1;candidate_write_addr_q<={sp,4'b0,write_index};
              candidate_write_data_q<=top_cells[write_index];
              if(write_index+1'b1==top_count) begin count[sp]<={4'b0,top_count}; cursor[sp]<=0; state<=CANDIDATE_DONE; end
              else write_index<=write_index+1'b1;
            end
            CANDIDATE_DONE: begin
              if(sp==0) state<=FALLBACK_WAIT;
              else begin best[sp]<=-INF; state<=FETCH_MOVE; end
            end
            FALLBACK_WAIT: begin
              if(fallback_seen) begin fallback_scan<=0; fallback_member<=0; state<=FALLBACK_READ; end
            end
            FALLBACK_READ: begin candidate_read_addr_q<={2'b0,fallback_scan}; state<=FALLBACK_RAM_WAIT; end
            FALLBACK_RAM_WAIT: state<=FALLBACK_RAM_USE;
            FALLBACK_RAM_USE: begin move_cell<=candidate_read_q;state<=FALLBACK_CHECK;end
            FALLBACK_CHECK: begin
              if(fallback_scan==0) fallback_cell<=move_cell;
              if(fallback_valid && move_cell==legacy_cell) begin fallback_cell<=move_cell; fallback_member<=1; end
              if(fallback_scan+1'b1==count[0]) state<=ROOT_START;
              else begin fallback_scan<=fallback_scan+1'b1; state<=FALLBACK_READ; end
            end
            ROOT_START: begin
              published_cell<=fallback_cell; published_score<=0; published_depth<=0;
              nodes_o<=1; iteration_depth<=1; cursor[0]<=0;
              layer_best<=-INF; layer_cell<=255; state<=FETCH_MOVE;
            end
            FETCH_MOVE: begin candidate_read_addr_q<={sp,cursor[sp]};state<=FETCH_WAIT;end
            FETCH_WAIT: state<=FETCH_USE;
            FETCH_USE: begin move_cell<=candidate_read_q;state<=PLAY_MOVE;end
            PLAY_MOVE: begin
              cells_write_en_q<=1; cells_write_addr_q<=move_cell; cells_write_data_q<=side[sp]; empty_count<=empty_count-1'b1;
              last_move[sp+1'b1]<=move_cell; side[sp+1'b1]<=3-side[sp];
              remaining[sp+1'b1]<=(sp==0) ? iteration_depth-1'b1 : remaining[sp]-1'b1;
              alpha[sp+1'b1]<=(sp==0) ? -INF : -beta[sp];
              beta[sp+1'b1]<=(sp==0) ? INF : -alpha[sp];
              sp<=sp+1'b1; state<=NODE_TICK;
            end
            RETURN_NODE: begin
              cells_write_en_q<=1; cells_write_addr_q<=last_move[sp]; cells_write_data_q<=0; empty_count<=empty_count+1'b1;
              returned_move<=last_move[sp]; returned_value<=-node_value;
              sp<=sp-1'b1; state<=CHILD_RESULT;
            end
            CHILD_RESULT: begin
              if(sp==0) begin
                if(returned_value>layer_best || (returned_value==layer_best && returned_move<layer_cell)) begin
                  layer_best<=returned_value; layer_cell<=returned_move;
                end
                if(cursor[0]+1'b1==count[0]) state<=LAYER_DONE;
                else begin cursor[0]<=cursor[0]+1'b1; state<=FETCH_MOVE; end
              end else begin
                if(returned_value>best[sp]) best[sp]<=returned_value;
                if(returned_value>alpha[sp]) alpha[sp]<=returned_value;
                state<=CHILD_NEXT;
              end
            end
            CHILD_NEXT: begin
              if(alpha[sp]>=beta[sp] || cursor[sp]+1'b1==count[sp]) begin node_value<=best[sp]; state<=RETURN_NODE; end
              else begin cursor[sp]<=cursor[sp]+1'b1; state<=FETCH_MOVE; end
            end
            LAYER_DONE: begin
              published_depth<=iteration_depth; published_score<=layer_best; published_cell<=layer_cell;
              if(iteration_depth==MAX_DEPTH) state<=FINISH;
              else begin
                iteration_depth<=iteration_depth+1'b1; cursor[0]<=0;
                layer_best<=-INF; layer_cell<=255; state<=FETCH_MOVE;
              end
            end
            FINISH: begin
              score_o<=published_score; completed_depth_o<=published_depth;
              fallback_used_o<=(published_depth==0); reason_o<=root_reason;
              output_remainder<=published_cell; output_row<=0; state<=OUTPUT_COORD;
            end
            OUTPUT_COORD: begin
              if(output_remainder>=13) begin output_remainder<=output_remainder-13; output_row<=output_row+1'b1; end
              else begin
                row_o<=output_row; col_o<=output_remainder[3:0];
                busy_o<=0; done_o<=1; result_valid_o<=1; state<=IDLE;
              end
            end
            INVALID: begin
              busy_o<=0; done_o<=1; result_valid_o<=0; score_o<=0; reason_o<=3;
              state<=IDLE;
            end
            default: begin state<=IDLE; busy_o<=0; done_o<=1; result_valid_o<=0; reason_o<=3; end
          endcase
        end
      end
    end
endmodule
