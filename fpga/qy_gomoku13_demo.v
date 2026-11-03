`timescale 1ns/1ps
`default_nettype none
// 13x13 autonomous algorithm demonstration; packed display stride is 13.
// Autonomous algorithm demonstration. No camera pixels become game moves.
// Both recommendations refer to exactly the same immutable rules version.
module qy_gomoku13_demo #(
    parameter HOLD_FRAMES=90, END_FRAMES=180, MAX_AI_CYCLES=2000000
)(
    input wire clk_i,rst_n_i,frame_tick_i,
    output wire [337:0] board_o,
    output wire [7:0] last_index_o,
    output wire last_valid_o,
    output wire [1:0] next_color_o,winner_o,
    output wire game_over_o,draw_o,
    output wire [7:0] move_count_o,
    output reg [7:0] black_index_o,white_index_o,
    output reg recommendations_valid_o,
    output reg [1:0] black_reason_o,white_reason_o,
    output wire [2:0] phase_o,
    output reg fault_o
);
    localparam NEW=0, SETTLE=1, START_BLACK=2, WAIT_BLACK=3,
        START_WHITE=4, WAIT_WHITE=5, SHOW=6, COMMIT=7,
        WAIT_ACCEPT=8, WAIT_RULES=9, END_SHOW=10, FAULT=11;
    reg [3:0] state;
    reg new_game,move_valid,ai_start,ai_cancel;
    reg [3:0] move_row,move_col;
    reg [1:0] move_color,ai_color;
    wire [449:0] board;
    wire [31:0] version,ai_version;
    wire [7:0] last_index;
    wire ready,accepted,rejected,ai_busy,ai_done,ai_valid;
    wire [3:0] ai_row,ai_col;
    wire [31:0] ai_score;
    wire [1:0] ai_reason;
    reg [3:0] black_row,black_col,white_row,white_col;
    reg [31:0] pair_version;
    reg [31:0] age;
    reg [15:0] frames;
    genvar r,c;
    generate for(r=0;r<13;r=r+1) begin: rows
        for(c=0;c<13;c=c+1) begin: cols
            assign board_o[(r*13+c)*2+:2]=board[(r*15+c)*2+:2];
        end
    end endgenerate
    assign last_index_o=(last_index/15)*13+last_index%15;
    assign phase_o=fault_o?3'd5:state==END_SHOW?3'd4:
        state==SHOW?3'd1:(state==COMMIT||state==WAIT_ACCEPT||state==WAIT_RULES)?3'd2:3'd0;
    qy_gomoku_rules #(.BOARD_SIZE(13)) rules(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.new_game_i(new_game),
        .move_valid_i(move_valid),.move_row_i(move_row),.move_col_i(move_col),.move_color_i(move_color),
        .move_ready_o(ready),.accepted_o(accepted),.rejected_o(rejected),.board_o(board),
        .next_color_o(next_color_o),.winner_o(winner_o),.game_over_o(game_over_o),.draw_o(draw_o),
        .move_count_o(move_count_o),.last_index_o(last_index),.last_valid_o(last_valid_o),.state_version_o(version));
    qy_gomoku_ai #(.BOARD_SIZE(13)) ai(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.start_i(ai_start),.cancel_i(ai_cancel),
        .board_i(board),.color_i(ai_color),.state_version_i(version),
        .busy_o(ai_busy),.done_o(ai_done),.result_valid_o(ai_valid),
        .row_o(ai_row),.col_o(ai_col),.score_o(ai_score),.result_version_o(ai_version),.reason_o(ai_reason));
    always @(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            state<=NEW;new_game<=0;move_valid<=0;ai_start<=0;ai_cancel<=0;
            move_row<=0;move_col<=0;move_color<=0;ai_color<=1;
            black_row<=0;black_col<=0;white_row<=0;white_col<=0;
            black_index_o<=0;white_index_o<=0;recommendations_valid_o<=0;
            black_reason_o<=0;white_reason_o<=0;pair_version<=0;
            age<=0;frames<=0;fault_o<=0;
        end else begin
            new_game<=0;move_valid<=0;ai_start<=0;ai_cancel<=0;
            if(state==WAIT_BLACK||state==WAIT_WHITE||state==WAIT_ACCEPT||state==WAIT_RULES) age<=age+1'b1;
            else age<=0;
            if(recommendations_valid_o&&version!=pair_version) recommendations_valid_o<=0;
            case(state)
                NEW: begin new_game<=1;ai_cancel<=1;recommendations_valid_o<=0;frames<=0;state<=SETTLE;end
                SETTLE: state<=START_BLACK;
                START_BLACK: if(ready&&!game_over_o&&!ai_busy) begin
                    pair_version<=version;ai_color<=1;ai_start<=1;state<=WAIT_BLACK;
                end
                WAIT_BLACK: if(ai_done) begin
                    if(ai_valid&&ai_version==pair_version&&version==pair_version&&ai_row<13&&ai_col<13) begin
                        black_row<=ai_row;black_col<=ai_col;
                        black_index_o<=ai_row*13+ai_col;black_reason_o<=ai_reason;state<=START_WHITE;
                    end else begin state<=FAULT;fault_o<=1;end
                end
                START_WHITE: begin ai_color<=2;ai_start<=1;state<=WAIT_WHITE;end
                WAIT_WHITE: if(ai_done) begin
                    if(ai_valid&&ai_version==pair_version&&version==pair_version&&ai_row<13&&ai_col<13) begin
                        white_row<=ai_row;white_col<=ai_col;
                        white_index_o<=ai_row*13+ai_col;white_reason_o<=ai_reason;
                        recommendations_valid_o<=1;frames<=0;state<=SHOW;
                    end else begin state<=FAULT;fault_o<=1;end
                end
                SHOW: if(frame_tick_i) begin
                    if(frames==HOLD_FRAMES-1) begin frames<=0;state<=COMMIT;end
                    else frames<=frames+1'b1;
                end
                COMMIT: begin
                    recommendations_valid_o<=0;
                    if(ready&&version==pair_version&&(next_color_o==1||next_color_o==2)) begin
                        move_row<=next_color_o==1?black_row:white_row;
                        move_col<=next_color_o==1?black_col:white_col;
                        move_color<=next_color_o;move_valid<=1;state<=WAIT_ACCEPT;
                    end else begin state<=FAULT;fault_o<=1;end
                end
                WAIT_ACCEPT: if(accepted) state<=WAIT_RULES;
                    else if(rejected) begin state<=FAULT;fault_o<=1;end
                WAIT_RULES: if(ready) begin
                    if(game_over_o) begin frames<=0;state<=END_SHOW;end
                    else state<=START_BLACK;
                end
                END_SHOW: if(frame_tick_i) begin
                    if(frames==END_FRAMES-1) state<=NEW;
                    else frames<=frames+1'b1;
                end
                FAULT: begin recommendations_valid_o<=0;ai_cancel<=1;end
                default: begin state<=FAULT;fault_o<=1;end
            endcase
            if(age>=MAX_AI_CYCLES) begin state<=FAULT;fault_o<=1;recommendations_valid_o<=0;ai_cancel<=1;end
        end
    end
endmodule
`default_nettype wire
