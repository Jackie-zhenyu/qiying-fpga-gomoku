`timescale 1ns/1ps
// Bounded, sequential one-ply recommender. Formal cells: 0 empty, 1 black,
// 2 white. Any 3 in the active board rejects the request; padding is ignored.
// Board storage always has stride 15, including BOARD_SIZE 5, 9 and 13.
// Scores describe contiguous runs only: no broken shapes or forced-line search.
// Results are tied to the input version. Cancel has no completion pulse;
// a version change during work produces an invalid completion (reason 3).
module qy_gomoku_ai #(
    parameter BOARD_SIZE = 9, parameter DYNAMIC_SIZE = 0
)(
    input wire clk_i, rst_n_i, start_i, cancel_i,
    input wire [449:0] board_i,
    input wire [3:0] board_size_i,
    input wire [1:0] color_i,
    input wire [31:0] state_version_i,
    output reg busy_o, done_o, result_valid_o,
    output reg [3:0] row_o, col_o,
    output reg [31:0] score_o, result_version_o,
    output reg [1:0] reason_o
);
    localparam [4:0] IDLE=0, VALID_ADDR=1, VALID_READ=2, VALID_CHECK=3,
        CAND_ADDR=4, CAND_READ=5, CAND_CHECK=6, DIR_INIT=7, RAY_INIT=8,
        RAY_ADDR=9, RAY_READ=10, RAY_CHECK=11, RAY_DONE=12,
        DIR_SCORE=13, DIR_ADD=14, DIR_NEXT=15, SUM_SCORE=16,
        ENCODE_SCORE=17, COMPARE=18, CAND_NEXT=19, COMPLETE=20;
    reg [4:0] state;
    reg [3:0] active_size;
    wire [3:0] requested_size=DYNAMIC_SIZE?board_size_i:BOARD_SIZE;
    reg [449:0] board;
    reg [1:0] color;
    reg [31:0] version;
    reg [3:0] cand_r, cand_c;
    reg [7:0] cell_addr;
    reg [1:0] cell_value;
    reg [1:0] direction;
    reg opponent, negative_ray;
    reg signed [5:0] scan_r, scan_c;
    reg [4:0] run_length;
    reg [1:0] open_ends;
    reg [18:0] pattern_term, own_sum, opp_sum;
    reg [20:0] heuristic_score;
    reg own_win, opp_win;
    reg [31:0] candidate_score, best_score;
    reg [1:0] candidate_reason, best_reason;
    reg [3:0] best_r, best_c;
    reg [4:0] candidate_distance, best_distance;
    reg have_best;
    wire [1:0] scan_color = opponent ? (2'd3-color) : color;

    function [7:0] address;
        input [3:0] r, c;
        begin address = {r,4'b0} - {4'b0,r} + {4'b0,c}; end
    endfunction
    function [4:0] distance_to_center;
        input [3:0] r, c;
        reg [4:0] dr, dc;
        begin
            dr = (r > ((active_size-1)/2)) ? r-((active_size-1)/2) : ((active_size-1)/2)-r;
            dc = (c > ((active_size-1)/2)) ? c-((active_size-1)/2) : ((active_size-1)/2)-c;
            distance_to_center = dr+dc;
        end
    endfunction
    function [18:0] contiguous_score;
        input [4:0] length;
        input [1:0] ends_open;
        begin
            contiguous_score = 0;
            if (length >= 5) contiguous_score = 100000;
            else if (ends_open != 0) begin
                case (length)
                    4: contiguous_score = (ends_open==2) ? 10000 : 2000;
                    3: contiguous_score = (ends_open==2) ? 1000 : 100;
                    2: contiguous_score = (ends_open==2) ? 80 : 10;
                    1: contiguous_score = (ends_open==2) ? 2 : 0;
                    default: contiguous_score = 0;
                endcase
            end
        end
    endfunction

    // synthesis translate_off
    initial begin
        if (BOARD_SIZE!=5 && BOARD_SIZE!=9 && BOARD_SIZE!=13 && BOARD_SIZE!=15) begin
            $display("CONFIG_ERROR: qy_gomoku_ai BOARD_SIZE must be 5, 9, 13 or 15");
            $finish;
        end
    end
    // synthesis translate_on

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state<=IDLE; busy_o<=0; done_o<=0; result_valid_o<=0; active_size<=BOARD_SIZE;
            row_o<=0; col_o<=0; score_o<=0; result_version_o<=0; reason_o<=3;
            board<=0; color<=1; version<=0; cand_r<=0; cand_c<=0;
            cell_addr<=0; cell_value<=0; direction<=0; opponent<=0;
            negative_ray<=0; scan_r<=0; scan_c<=0; run_length<=0; open_ends<=0;
            pattern_term<=0; own_sum<=0; opp_sum<=0; heuristic_score<=0;
            own_win<=0; opp_win<=0; candidate_score<=0; best_score<=0;
            candidate_reason<=3; best_reason<=3; best_r<=0; best_c<=0;
            candidate_distance<=0; best_distance<=0; have_best<=0;
        end else begin
            done_o <= 0;
            if (cancel_i) begin
                state<=IDLE; busy_o<=0; result_valid_o<=0; reason_o<=3;
            end else if (busy_o && (state_version_i != version || requested_size!=active_size)) begin
                state<=IDLE; busy_o<=0; done_o<=1; result_valid_o<=0;
                score_o<=0; reason_o<=3;
            end else begin
                if (result_valid_o && (state_version_i != result_version_o || requested_size!=active_size))
                    result_valid_o<=0;
                case (state)
                    IDLE: if (start_i) begin
                        board<=board_i; color<=color_i; version<=state_version_i; active_size<=requested_size;
                        result_version_o<=state_version_i;
                        busy_o<=1; result_valid_o<=0; score_o<=0; reason_o<=3;
                        cand_r<=0; cand_c<=0; have_best<=0; best_score<=0;
                        best_distance<=31; best_reason<=3;
                        state<=VALID_ADDR;
                    end
                    VALID_ADDR: begin
                        if ((color!=1 && color!=2) || active_size<5 || active_size>BOARD_SIZE) begin
                            state<=IDLE; busy_o<=0; done_o<=1;
                        end else begin cell_addr<=address(cand_r,cand_c); state<=VALID_READ; end
                    end
                    VALID_READ: begin cell_value<=board[{cell_addr,1'b0} +: 2]; state<=VALID_CHECK; end
                    VALID_CHECK: begin
                        if (cell_value==3) begin state<=IDLE; busy_o<=0; done_o<=1; end
                        else if (cand_r==active_size-1 && cand_c==active_size-1) begin
                            cand_r<=0; cand_c<=0; state<=CAND_ADDR;
                        end else begin
                            if (cand_c==active_size-1) begin cand_c<=0; cand_r<=cand_r+1'b1; end
                            else cand_c<=cand_c+1'b1;
                            state<=VALID_ADDR;
                        end
                    end
                    CAND_ADDR: begin cell_addr<=address(cand_r,cand_c); state<=CAND_READ; end
                    CAND_READ: begin cell_value<=board[{cell_addr,1'b0} +: 2]; state<=CAND_CHECK; end
                    CAND_CHECK: begin
                        if (cell_value!=0) state<=CAND_NEXT;
                        else begin
                            direction<=0; opponent<=0; own_sum<=0; opp_sum<=0;
                            own_win<=0; opp_win<=0;
                            candidate_distance<=distance_to_center(cand_r,cand_c);
                            state<=DIR_INIT;
                        end
                    end
                    DIR_INIT: begin run_length<=1; open_ends<=0; negative_ray<=0; state<=RAY_INIT; end
                    RAY_INIT: begin
                        case (direction)
                            0: begin scan_r<=$signed({2'b0,cand_r}); scan_c<=$signed({2'b0,cand_c})+(negative_ray ? -6'sd1 : 6'sd1); end
                            1: begin scan_r<=$signed({2'b0,cand_r})+(negative_ray ? -6'sd1 : 6'sd1); scan_c<=$signed({2'b0,cand_c}); end
                            2: begin scan_r<=$signed({2'b0,cand_r})+(negative_ray ? -6'sd1 : 6'sd1); scan_c<=$signed({2'b0,cand_c})+(negative_ray ? -6'sd1 : 6'sd1); end
                            3: begin scan_r<=$signed({2'b0,cand_r})+(negative_ray ? -6'sd1 : 6'sd1); scan_c<=$signed({2'b0,cand_c})+(negative_ray ? 6'sd1 : -6'sd1); end
                        endcase
                        state<=RAY_ADDR;
                    end
                    RAY_ADDR: begin
                        if (scan_r<0 || scan_c<0 || scan_r>=active_size || scan_c>=active_size) state<=RAY_DONE;
                        else begin cell_addr<=address(scan_r[3:0],scan_c[3:0]); state<=RAY_READ; end
                    end
                    RAY_READ: begin cell_value<=board[{cell_addr,1'b0} +: 2]; state<=RAY_CHECK; end
                    RAY_CHECK: begin
                        if (cell_value==scan_color) begin
                            run_length<=run_length+1'b1;
                            if (direction!=0) scan_r<=scan_r+(negative_ray ? -6'sd1 : 6'sd1);
                            if (direction==0 || direction==2) scan_c<=scan_c+(negative_ray ? -6'sd1 : 6'sd1);
                            else if (direction==3) scan_c<=scan_c+(negative_ray ? 6'sd1 : -6'sd1);
                            state<=RAY_ADDR;
                        end else begin
                            if (cell_value==0) open_ends<=open_ends+1'b1;
                            state<=RAY_DONE;
                        end
                    end
                    RAY_DONE: begin
                        if (!negative_ray) begin negative_ray<=1; state<=RAY_INIT; end
                        else state<=DIR_SCORE;
                    end
                    DIR_SCORE: begin pattern_term<=contiguous_score(run_length,open_ends); state<=DIR_ADD; end
                    DIR_ADD: begin
                        if (opponent) begin
                            opp_sum<=opp_sum+pattern_term;
                            if (run_length>=5) opp_win<=1;
                        end else begin
                            own_sum<=own_sum+pattern_term;
                            if (run_length>=5) own_win<=1;
                        end
                        state<=DIR_NEXT;
                    end
                    DIR_NEXT: begin
                        if (direction!=3) begin direction<=direction+1'b1; state<=DIR_INIT; end
                        else if (!opponent) begin direction<=0; opponent<=1; state<=DIR_INIT; end
                        else state<=SUM_SCORE;
                    end
                    SUM_SCORE: begin heuristic_score<=({2'b0,own_sum}<<1)+{2'b0,opp_sum}; state<=ENCODE_SCORE; end
                    ENCODE_SCORE: begin
                        candidate_score <= {11'b0,heuristic_score} + (own_win ? 32'h01000000 : (opp_win ? 32'h00800000 : 32'd0));
                        candidate_reason <= own_win ? 2'd1 : (opp_win ? 2'd2 : 2'd0);
                        state<=COMPARE;
                    end
                    COMPARE: begin
                        if (!have_best || candidate_score>best_score ||
                            (candidate_score==best_score && candidate_distance<best_distance)) begin
                            have_best<=1; best_score<=candidate_score; best_reason<=candidate_reason;
                            best_r<=cand_r; best_c<=cand_c; best_distance<=candidate_distance;
                        end
                        state<=CAND_NEXT;
                    end
                    CAND_NEXT: begin
                        if (cand_r==active_size-1 && cand_c==active_size-1) state<=COMPLETE;
                        else begin
                            if (cand_c==active_size-1) begin cand_c<=0; cand_r<=cand_r+1'b1; end
                            else cand_c<=cand_c+1'b1;
                            state<=CAND_ADDR;
                        end
                    end
                    COMPLETE: begin
                        busy_o<=0; done_o<=1; result_valid_o<=have_best;
                        row_o<=best_r; col_o<=best_c; score_o<=have_best ? best_score : 0;
                        reason_o<=have_best ? best_reason : 2'd3; state<=IDLE;
                    end
                    default: begin state<=IDLE; busy_o<=0; done_o<=1; result_valid_o<=0; reason_o<=3; end
                endcase
            end
        end
    end
endmodule
