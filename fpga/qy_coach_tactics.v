// Bounded freestyle Gomoku facts for a stable formal-board snapshot.
// Coordinates: cell = y*13+x, board_i[cell*2 +: 2]. Active sizes 5..13.
// 0 empty, 1 black, 2 white, 3 unknown/invalid. Padding is ignored.
// Each legal length-five window is inspected once in four directions.
// Results describe one-move wins, not deeper search or a guarantee of defence.
module qy_coach_tactics (
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire cancel,
    input wire [337:0] board_i,
    input wire [3:0] board_size_i,
    input wire [1:0] side_i,
    input wire [31:0] version_i,
    output reg busy,
    output reg done,
    output reg valid,
    output reg [31:0] result_version,
    output reg [168:0] own_wins,
    output reg [168:0] opp_wins,
    output reg [7:0] own_count,
    output reg [7:0] opp_count,
    output reg [7:0] own_first,
    output reg [7:0] opp_first,
    output reg [168:0] own_line,
    output reg [168:0] opp_line,
    output reg terminal_own,
    output reg terminal_opp,
    output reg error
);
    localparam [3:0] S_IDLE=0, S_VALIDATE=1, S_WINDOW=2,
        S_READ=3, S_EVAL=4, S_ADVANCE=5, S_COUNT=6, S_PUBLISH=7,
        S_VALIDATE_ADDR=8,S_VALIDATE_WAIT=9,S_READ_ADDR=10,S_READ_WAIT=11,
        S_COUNT_ADDR=12,S_COUNT_WAIT=13;
    reg [3:0] state;
    reg [337:0] board_snap;
    reg [3:0] size_snap;
    reg [1:0] side_snap;
    reg [31:0] version_snap;
    reg [3:0] x, y;
    reg [1:0] direction;
    reg [7:0] cell_index;
    reg [2:0] read_number, black_n, white_n, empty_n;
    reg [7:0] empty_index;
    reg [168:0] window_line;
    reg [168:0] own_work, opp_work, own_line_work, opp_line_work;
    reg [7:0] own_count_work, opp_count_work;
    reg [7:0] own_first_work, opp_first_work;
    reg terminal_own_work, terminal_opp_work;

    wire [351:0] padded_board={14'd0,board_snap};
    wire [175:0] padded_own={7'd0,own_work},padded_opp={7'd0,opp_work};
    reg [1:0] board_bank[0:10],count_bank[0:10];
    reg [3:0] read_bank_q;
    reg [1:0] cell_value,count_hits;
    genvar bank;
    generate for(bank=0;bank<11;bank=bank+1)begin:local_read
        always @(posedge clk)begin
            board_bank[bank]<=padded_board[bank*32+cell_index[3:0]*2+:2];
            count_bank[bank]<={padded_opp[bank*16+cell_index[3:0]],padded_own[bank*16+cell_index[3:0]]};
        end
    end endgenerate
    always @(posedge clk)begin
        read_bank_q<=cell_index[7:4];
        cell_value<=read_bank_q<11?board_bank[read_bank_q]:2'd0;
        count_hits<=read_bank_q<11?count_bank[read_bank_q]:2'd0;
    end
    wire [4:0] x_end = {1'b0,x} + 5'd4;
    wire [4:0] y_end = {1'b0,y} + 5'd4;
    wire window_inside = (x < size_snap) && (y < size_snap) &&
        ((direction==0 && x_end < {1'b0,size_snap}) ||
         (direction==1 && y_end < {1'b0,size_snap}) ||
         (direction==2 && x_end < {1'b0,size_snap} && y_end < {1'b0,size_snap}) ||
         (direction==3 && x >= 4 && y_end < {1'b0,size_snap}));
    wire [7:0] window_start = y*8'd13 + x;
    wire [7:0] window_step = (direction==0) ? 8'd1 :
        (direction==1) ? 8'd13 : (direction==2) ? 8'd14 : 8'd12;
    wire [2:0] own_n = (side_snap==1) ? black_n : white_n;
    wire [2:0] opp_n = (side_snap==1) ? white_n : black_n;
    wire changed = board_i != board_snap || board_size_i != size_snap ||
        side_i != side_snap || version_i != version_snap;

    // These are private request data. A simultaneous cancel may discard a
    // captured snapshot, but never starts work or validates a result. Keeping
    // capture separate removes the full-board cancel comparison from hundreds
    // of data-register enables; cancellation retains priority in the FSM.
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin board_snap<=0;size_snap<=0;side_snap<=0;version_snap<=0;end
        else if(start&&!busy)begin
            board_snap<=board_i;size_snap<=board_size_i;side_snap<=side_i;version_snap<=version_i;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            busy <= 0; done <= 0; valid <= 0; error <= 0;
            result_version <= 0;
            own_wins <= 0; opp_wins <= 0;
            own_count <= 0; opp_count <= 0;
            own_first <= 8'hff; opp_first <= 8'hff;
            own_line <= 0; opp_line <= 0;
            terminal_own <= 0; terminal_opp <= 0;
            x <= 0; y <= 0; direction <= 0; cell_index <= 0;
            read_number <= 0; black_n <= 0; white_n <= 0; empty_n <= 0;
            empty_index <= 0; window_line <= 0;
            own_work <= 0; opp_work <= 0; own_line_work <= 0; opp_line_work <= 0;
            own_count_work <= 0; opp_count_work <= 0;
            own_first_work <= 8'hff; opp_first_work <= 8'hff;
            terminal_own_work <= 0; terminal_opp_work <= 0;
        end else begin
            done <= 0;
            // Cancellation wins over start. A changing input cancels an active
            // job and invalidates a published result even if version was reused.
            if (cancel || (busy && changed)) begin
                state <= S_IDLE;
                busy <= 0; valid <= 0; error <= 0;
            end else if (start && !busy) begin
                valid <= 0; error <= 0;
                x <= 0; y <= 0; direction <= 0; cell_index <= 0;
                own_work <= 0; opp_work <= 0;
                own_line_work <= 0; opp_line_work <= 0;
                own_count_work <= 0; opp_count_work <= 0;
                own_first_work <= 8'hff; opp_first_work <= 8'hff;
                terminal_own_work <= 0; terminal_opp_work <= 0;
                if (board_size_i < 5 || board_size_i > 13 ||
                    (side_i != 1 && side_i != 2)) begin
                    state <= S_IDLE; busy <= 0; done <= 1; error <= 1;
                end else begin
                    state <= S_VALIDATE_ADDR; busy <= 1;
                end
            end else begin
                if (valid && changed) valid <= 0;
                case (state)
                    S_VALIDATE_ADDR:state<=S_VALIDATE_WAIT;
                    S_VALIDATE_WAIT:state<=S_VALIDATE;
                    S_VALIDATE: begin
                        if (x < size_snap && y < size_snap && cell_value==3) begin
                            state <= S_IDLE; busy <= 0; done <= 1; error <= 1;
                        end else if (cell_index==168) begin
                            x <= 0; y <= 0; direction <= 0;
                            state <= S_WINDOW;
                        end else begin
                            cell_index <= cell_index + 1'b1;
                            if (x==12) begin x <= 0; y <= y+1'b1; end
                            else x <= x+1'b1;
                            state<=S_VALIDATE_ADDR;
                        end
                    end
                    S_WINDOW: begin
                        if (window_inside) begin
                            cell_index <= window_start;
                            read_number <= 0; black_n <= 0; white_n <= 0; empty_n <= 0;
                            window_line <= 0;
                            state <= S_READ_ADDR;
                        end else state <= S_ADVANCE;
                    end
                    S_READ_ADDR:state<=S_READ_WAIT;
                    S_READ_WAIT:state<=S_READ;
                    S_READ: begin
                        window_line[cell_index] <= 1;
                        if (cell_value==1) black_n <= black_n+1'b1;
                        else if (cell_value==2) white_n <= white_n+1'b1;
                        else begin empty_n <= empty_n+1'b1; empty_index <= cell_index; end
                        if (read_number==4) state <= S_EVAL;
                        else begin
                            cell_index <= cell_index + window_step;
                            read_number <= read_number+1'b1;
                            state<=S_READ_ADDR;
                        end
                    end
                    S_EVAL: begin
                        if (own_n==5) terminal_own_work <= 1;
                        if (opp_n==5) terminal_opp_work <= 1;
                        if (own_n==4 && empty_n==1) begin
                            own_work[empty_index] <= 1;
                            if (empty_index < own_first_work) begin
                                own_first_work <= empty_index;
                                own_line_work <= window_line;
                            end
                        end
                        if (opp_n==4 && empty_n==1) begin
                            opp_work[empty_index] <= 1;
                            if (empty_index < opp_first_work) begin
                                opp_first_work <= empty_index;
                                opp_line_work <= window_line;
                            end
                        end
                        state <= S_ADVANCE;
                    end
                    S_ADVANCE: begin
                        if (direction != 3) begin
                            direction <= direction+1'b1; state <= S_WINDOW;
                        end else if (x != 12) begin
                            direction <= 0; x <= x+1'b1; state <= S_WINDOW;
                        end else if (y != 12) begin
                            direction <= 0; x <= 0; y <= y+1'b1; state <= S_WINDOW;
                        end else begin cell_index <= 0; state <= S_COUNT_ADDR; end
                    end
                    S_COUNT_ADDR:state<=S_COUNT_WAIT;
                    S_COUNT_WAIT:state<=S_COUNT;
                    S_COUNT: begin
                        if (count_hits[0]) own_count_work <= own_count_work+1'b1;
                        if (count_hits[1]) opp_count_work <= opp_count_work+1'b1;
                        if (cell_index==168) state <= S_PUBLISH;
                        else begin cell_index <= cell_index+1'b1;state<=S_COUNT_ADDR;end
                    end
                    S_PUBLISH: begin
                        own_wins <= own_work; opp_wins <= opp_work;
                        own_count <= own_count_work; opp_count <= opp_count_work;
                        own_first <= own_first_work; opp_first <= opp_first_work;
                        own_line <= own_line_work; opp_line <= opp_line_work;
                        terminal_own <= terminal_own_work; terminal_opp <= terminal_opp_work;
                        result_version <= version_snap;
                        busy <= 0; done <= 1; valid <= 1; error <= 0;
                        state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
