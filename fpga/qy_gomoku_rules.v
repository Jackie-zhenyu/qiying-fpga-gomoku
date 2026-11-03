`timescale 1ns/1ps
// FPGA-only freestyle Gomoku rules. Packed board always uses row * 15 + col,
// two bits per cell: 0 empty, 1 black, 2 white; 3 is never a legal move.
// A valid/ready handshake updates board/count/last/version immediately and
// pulses accepted. Ready stays low until the sequential >=5 scan resolves.
// Consumers must wait for ready before using winner/draw/next_color. While
// busy, valid is ignored. Terminal next_color is 0; ready then accepts invalid
// attempts for rejection reporting. new_game dominates and aborts any scan.
module qy_gomoku_rules #(
    parameter BOARD_SIZE = 9, parameter DYNAMIC_SIZE = 0
) (
    input wire clk_i,
    input wire rst_n_i,
    input wire new_game_i,
    input wire [3:0] board_size_i,
    input wire move_valid_i,
    input wire [3:0] move_row_i,
    input wire [3:0] move_col_i,
    input wire [1:0] move_color_i,
    output reg move_ready_o,
    output reg accepted_o,
    output reg rejected_o,
    output reg [449:0] board_o,
    output reg [1:0] next_color_o,
    output reg [1:0] winner_o,
    output reg game_over_o,
    output reg draw_o,
    output reg [7:0] move_count_o,
    output reg [7:0] last_index_o,
    output reg last_valid_o,
    output reg [31:0] state_version_o
);
    localparam [3:0] ST_IDLE = 0, ST_START = 1, ST_READ = 2,
                     ST_CHECK = 3, ST_RAY_END = 4, ST_DIRECTION = 5,
                     ST_FINISH = 6;
    reg [3:0] active_size;
    wire size_good=active_size>=5 && active_size<=BOARD_SIZE;
    wire [7:0] cell_count=active_size*active_size;
    reg [3:0] state_q;
    reg [3:0] origin_row_q, origin_col_q;
    reg [1:0] color_q, direction_q;
    reg side_q;
    reg [4:0] scan_row_q, scan_col_q;
    reg [2:0] depth_q;
    reg [3:0] line_count_q;
    reg [1:0] sampled_cell_q;
    reg sampled_in_bounds_q;
    reg win_q;

    wire [7:0] move_index = {move_row_i,4'b0000}
                           - {4'b0000,move_row_i} + {4'b0000,move_col_i};
    wire [8:0] move_bit_index = {move_index,1'b0};
    wire [14:0] occupied_rows;
    wire request_legal=state_q==ST_IDLE&&move_valid_i&&size_good&&!game_over_o&&
        move_row_i<active_size&&move_col_i<active_size&&
        (move_color_i==1||move_color_i==2)&&move_color_i==next_color_o;
    // Decode row/column locally. A legal write to an empty selected cell does
    // not depend on a global 225-cell occupancy mux. Rejection and metadata
    // still use the same-cycle selected occupancy, preserving the handshake.
    genvar rr,cc;
    generate for(rr=0;rr<15;rr=rr+1)begin:move_row_bank
        wire [14:0] occupied_columns;
        for(cc=0;cc<15;cc=cc+1)begin:slot
            assign occupied_columns[cc]=(move_col_i==cc)&&(board_o[(rr*15+cc)*2+:2]!=0);
            always @(posedge clk_i)begin
                if(!rst_n_i||new_game_i)board_o[(rr*15+cc)*2+:2]<=0;
                else if(request_legal&&move_row_i==rr&&move_col_i==cc&&board_o[(rr*15+cc)*2+:2]==0)
                    board_o[(rr*15+cc)*2+:2]<=move_color_i;
            end
        end
        assign occupied_rows[rr]=(move_row_i==rr)&&(|occupied_columns);
    end endgenerate
    wire move_occupied=|occupied_rows;
    wire [7:0] scan_index = {scan_row_q[3:0],4'b0000}
                           - {4'b0000,scan_row_q[3:0]}
                           + {4'b0000,scan_col_q[3:0]};
    wire [8:0] scan_bit_index = {scan_index,1'b0};

    // Unsigned 5-bit coordinates encode an off-edge -1 as 31. Every read is
    // range checked before its value is used, so a row cannot wrap into another.
    function [4:0] step_row;
        input [4:0] value;
        input [1:0] direction;
        input side;
        begin
            if (direction == 0) step_row = value;
            else if (side) step_row = value - 5'd1;
            else step_row = value + 5'd1;
        end
    endfunction
    function [4:0] step_col;
        input [4:0] value;
        input [1:0] direction;
        input side;
        begin
            if (direction == 1) step_col = value;
            else if (side ^ (direction == 3)) step_col = value - 5'd1;
            else step_col = value + 5'd1;
        end
    endfunction

    // synthesis translate_off
    initial begin
        if ((BOARD_SIZE != 5) && (BOARD_SIZE != 9) &&
            (BOARD_SIZE != 13) && (BOARD_SIZE != 15)) begin
            $display("CONFIG_ERROR: qy_gomoku_rules BOARD_SIZE must be 5,9,13,15");
            $finish;
        end
    end
    // synthesis translate_on

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_q <= ST_IDLE;
            active_size <= DYNAMIC_SIZE ? board_size_i : BOARD_SIZE;
            move_ready_o <= 1'b1;
            accepted_o <= 1'b0;
            rejected_o <= 1'b0;
            next_color_o <= 2'd1;
            winner_o <= 2'd0;
            game_over_o <= 1'b0;
            draw_o <= 1'b0;
            move_count_o <= 8'd0;
            last_index_o <= 8'd0;
            last_valid_o <= 1'b0;
            state_version_o <= 32'd0;
            origin_row_q <= 4'd0;
            origin_col_q <= 4'd0;
            color_q <= 2'd0;
            direction_q <= 2'd0;
            side_q <= 1'b0;
            scan_row_q <= 5'd0;
            scan_col_q <= 5'd0;
            depth_q <= 3'd0;
            line_count_q <= 4'd0;
            sampled_cell_q <= 2'd0;
            sampled_in_bounds_q <= 1'b0;
            win_q <= 1'b0;
        end else begin
            accepted_o <= 1'b0;
            rejected_o <= 1'b0;
            if (new_game_i) begin
                active_size <= DYNAMIC_SIZE ? board_size_i : BOARD_SIZE;
                state_q <= ST_IDLE;
                move_ready_o <= 1'b1;
                next_color_o <= 2'd1;
                winner_o <= 2'd0;
                game_over_o <= 1'b0;
                draw_o <= 1'b0;
                move_count_o <= 8'd0;
                last_index_o <= 8'd0;
                last_valid_o <= 1'b0;
                state_version_o <= state_version_o + 32'd1;
                win_q <= 1'b0;
            end else begin
                case (state_q)
                    ST_IDLE: begin
                        if (move_valid_i) begin
                            if (!size_good || game_over_o || (move_row_i >= active_size) ||
                                (move_col_i >= active_size) ||
                                ((move_color_i != 1) && (move_color_i != 2)) ||
                                (move_color_i != next_color_o)) begin
                                rejected_o <= 1'b1;
                            end else if (move_occupied) begin
                                rejected_o <= 1'b1;
                            end else begin
                                move_count_o <= move_count_o + 8'd1;
                                last_index_o <= move_index;
                                last_valid_o <= 1'b1;
                                state_version_o <= state_version_o + 32'd1;
                                accepted_o <= 1'b1;
                                move_ready_o <= 1'b0;
                                origin_row_q <= move_row_i;
                                origin_col_q <= move_col_i;
                                color_q <= move_color_i;
                                direction_q <= 2'd0;
                                side_q <= 1'b0;
                                line_count_q <= 4'd1;
                                win_q <= 1'b0;
                                state_q <= ST_START;
                            end
                        end
                    end
                    ST_START: begin
                        scan_row_q <= step_row({1'b0,origin_row_q},direction_q,side_q);
                        scan_col_q <= step_col({1'b0,origin_col_q},direction_q,side_q);
                        depth_q <= 3'd1;
                        state_q <= ST_READ;
                    end
                    ST_READ: begin
                        // The board mux is registered separately from count,
                        // win and next-address decisions for a short data path.
                        sampled_cell_q <= board_o[scan_bit_index +: 2];
                        sampled_in_bounds_q <= (scan_row_q < active_size)
                                            && (scan_col_q < active_size);
                        state_q <= ST_CHECK;
                    end
                    ST_CHECK: begin
                        if (sampled_in_bounds_q && (sampled_cell_q == color_q)) begin
                            line_count_q <= line_count_q + 4'd1;
                            if (depth_q == 4) state_q <= ST_RAY_END;
                            else begin
                                depth_q <= depth_q + 3'd1;
                                scan_row_q <= step_row(scan_row_q,direction_q,side_q);
                                scan_col_q <= step_col(scan_col_q,direction_q,side_q);
                                state_q <= ST_READ;
                            end
                        end else state_q <= ST_RAY_END;
                    end
                    ST_RAY_END: begin
                        if (!side_q) begin
                            side_q <= 1'b1;
                            state_q <= ST_START;
                        end else state_q <= ST_DIRECTION;
                    end
                    ST_DIRECTION: begin
                        if (line_count_q >= 5) begin
                            win_q <= 1'b1;
                            state_q <= ST_FINISH;
                        end else if (direction_q == 3) state_q <= ST_FINISH;
                        else begin
                            direction_q <= direction_q + 2'd1;
                            side_q <= 1'b0;
                            line_count_q <= 4'd1;
                            state_q <= ST_START;
                        end
                    end
                    ST_FINISH: begin
                        // Winning on the final empty cell is a win, not a draw.
                        if (win_q) begin
                            winner_o <= color_q;
                            game_over_o <= 1'b1;
                            next_color_o <= 2'd0;
                        end else if (move_count_o == cell_count) begin
                            game_over_o <= 1'b1;
                            draw_o <= 1'b1;
                            next_color_o <= 2'd0;
                        end else next_color_o <= (color_q == 1) ? 2'd2 : 2'd1;
                        move_ready_o <= 1'b1;
                        state_q <= ST_IDLE;
                    end
                    default: begin
                        state_q <= ST_IDLE;
                        move_ready_o <= 1'b1;
                    end
                endcase
            end
        end
    end
endmodule
