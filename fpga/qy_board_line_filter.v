`timescale 1ns/1ps
// Camera-derived local ink/edge extraction, not board localization or YOLO.
// Input: complete raster rows, arbitrary blank clocks, (0,0) starts a frame.
// Output: the 3x3 centre (x_i-1,y_i-1), when x_i>=2 and y_i>=2.
// A pixel sampled at edge N produces its output at edge N+3. No flush pixels
// are needed; allow three clock edges after the final input to drain the pipe.
// Three row banks are used so no result relies on a RAM read/write collision.
module qy_board_line_filter #(
    parameter WIDTH = 640,
    parameter HEIGHT = 360
)(
    input wire clk_i,
    input wire rst_n_i,                 // synchronous, active-low reset
    input wire valid_i,
    input wire [9:0] x_i,
    input wire [8:0] y_i,
    input wire [23:0] rgb_i,
    output reg valid_o,
    output reg [9:0] x_o,
    output reg [8:0] y_o,
    output reg ink_o
);
    reg [7:0] row0 [0:WIDTH-1];
    reg [7:0] row1 [0:WIDTH-1];
    reg [7:0] row2 [0:WIDTH-1];
    reg [7:0] rd0, rd1, rd2;
    reg [1:0] next_bank;

    // Keep explicit synchronous FF boundaries on every RAM address/data/WE
    // fan-in. Do not merge these with a board-level asynchronous reset FF.
    (* keep = "true" *) reg req_valid;
    (* keep = "true" *) reg [9:0] req_addr;
    (* keep = "true" *) reg [7:0] req_gray;
    (* keep = "true" *) reg [1:0] req_bank;
    reg [8:0] req_y;
    reg mem_valid;
    reg [9:0] mem_x;
    reg [8:0] mem_y;
    reg [7:0] mem_gray;
    reg [1:0] mem_bank;

    wire [9:0] gray_sum = {2'b0,rgb_i[23:16]} +
                           {1'b0,rgb_i[15:8],1'b0} +
                           {2'b0,rgb_i[7:0]};
    wire [1:0] current_bank = (x_i == 0 && y_i == 0) ? 2'd0 : next_bank;

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            next_bank <= 0;
            req_valid <= 0;
            req_addr <= 0;
            req_gray <= 0;
            req_bank <= 0;
            req_y <= 0;
            mem_valid <= 0;
            mem_x <= 0;
            mem_y <= 0;
            mem_gray <= 0;
            mem_bank <= 0;
        end else begin
            req_valid <= valid_i && x_i < WIDTH && y_i < HEIGHT;
            if (valid_i && x_i < WIDTH && y_i < HEIGHT) begin
                req_addr <= x_i;
                req_gray <= gray_sum[9:2];
                req_bank <= current_bank;
                req_y <= y_i;
                if (x_i == WIDTH-1)
                    next_bank <= (current_bank == 2) ? 0 : current_bank + 1'b1;
                else if (x_i == 0 && y_i == 0)
                    next_bank <= 0;
            end
            mem_valid <= req_valid;
            mem_x <= req_addr;
            mem_y <= req_y;
            mem_gray <= req_gray;
            mem_bank <= req_bank;
        end
    end

    // No reset on RAM or its read data. Control validity masks stale contents
    // until both preceding rows of the current frame have been written.
    always @(posedge clk_i) begin
        if (req_valid) begin
            rd0 <= row0[req_addr];
            rd1 <= row1[req_addr];
            rd2 <= row2[req_addr];
            case (req_bank)
                2'd0: row0[req_addr] <= req_gray;
                2'd1: row1[req_addr] <= req_gray;
                2'd2: row2[req_addr] <= req_gray;
                default: begin end
            endcase
        end
    end

    reg [7:0] top_right, middle_right;
    always @* begin
        case (mem_bank)
            2'd0: begin top_right = rd1; middle_right = rd2; end
            2'd1: begin top_right = rd2; middle_right = rd0; end
            default: begin top_right = rd0; middle_right = rd1; end
        endcase
    end
    reg [7:0] tl, tc, ml, mc, bl, bc;
    // Stage N+2 computes bounded three-pixel sums only. Registering the
    // three row sums prevents a nine-term chain across the RAM read path.
    wire [9:0] top_sum = {2'b0,tl} + {2'b0,tc} + {2'b0,top_right};
    wire [9:0] middle_sum = {2'b0,ml} + {2'b0,mc} + {2'b0,middle_right};
    wire [9:0] bottom_sum = {2'b0,bl} + {2'b0,bc} + {2'b0,mem_gray};
    // For a b c / d e f / g h i, Gx+Gy=2(A-B), Gx-Gy=2(C-D).
    // |Gx|+|Gy| = max(|Gx+Gy|,|Gx-Gy|), so threshold 160 is exactly
    // |A-B|>=80 or |C-D|>=80. Parallel biased comparisons remove the
    // subtract -> absolute-value mux -> add critical path.
    // Each sum <=765; adding 80 <=845 fits all ten-bit comparisons.
    wire [9:0] sobel_a = {2'b0,middle_right} + {2'b0,mem_gray} + {2'b0,bc};
    wire [9:0] sobel_b = {2'b0,tl} + {2'b0,ml} + {2'b0,tc};
    wire [9:0] sobel_c = {2'b0,top_right} + {2'b0,middle_right} + {2'b0,tc};
    wire [9:0] sobel_d = {2'b0,ml} + {2'b0,bl} + {2'b0,bc};
    reg features_valid;
    reg [9:0] features_x;
    reg [8:0] features_y;
    reg [7:0] centre_q;
    reg [9:0] top_sum_q,middle_sum_q,bottom_sum_q;
    reg [9:0] sobel_a_q,sobel_b_q,sobel_c_q,sobel_d_q;
    // Stage N+3 combines three row sums and classifies the same centre.
    wire [11:0] sum9 = {2'b0,top_sum_q} + {2'b0,middle_sum_q} + {2'b0,bottom_sum_q};
    wire [11:0] centre9_bias = {1'b0,centre_q,3'b0} + {4'b0,centre_q} + 12'd72;
    wire sobel_edge = (sobel_a_q >= sobel_b_q + 10'd80) ||
                      (sobel_b_q >= sobel_a_q + 10'd80) ||
                      (sobel_c_q >= sobel_d_q + 10'd80) ||
                      (sobel_d_q >= sobel_c_q + 10'd80);
    wire detected_ink = (centre_q < 80) ||
                        ((centre_q <= 235) && (centre9_bias < sum9)) ||
                        ((centre_q <= 200) && sobel_edge);

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            features_valid <= 0; features_x <= 0; features_y <= 0;
            centre_q <= 0;
            top_sum_q <= 0; middle_sum_q <= 0; bottom_sum_q <= 0;
            sobel_a_q <= 0; sobel_b_q <= 0; sobel_c_q <= 0; sobel_d_q <= 0;
            tl <= 0; tc <= 0; ml <= 0; mc <= 0; bl <= 0; bc <= 0;
        end else begin
            features_valid <= mem_valid && mem_x >= 2 && mem_y >= 2;
            if (mem_valid) begin
                features_x <= mem_x - 1'b1;
                features_y <= mem_y - 1'b1;
                centre_q <= mc;
                top_sum_q <= top_sum; middle_sum_q <= middle_sum; bottom_sum_q <= bottom_sum;
                sobel_a_q <= sobel_a; sobel_b_q <= sobel_b; sobel_c_q <= sobel_c; sobel_d_q <= sobel_d;
                // New line clears horizontal history, independently of blank
                // length. At x=2 all nine samples belong to the current frame.
                tl <= (mem_x == 0) ? 0 : tc;
                ml <= (mem_x == 0) ? 0 : mc;
                bl <= (mem_x == 0) ? 0 : bc;
                tc <= top_right;
                mc <= middle_right;
                bc <= mem_gray;
            end
        end
    end

    always @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_o <= 0; x_o <= 0; y_o <= 0; ink_o <= 0;
        end else begin
            valid_o <= features_valid;
            if (features_valid) begin
                x_o <= features_x;
                y_o <= features_y;
                ink_o <= detected_ink;
            end
        end
    end
endmodule
