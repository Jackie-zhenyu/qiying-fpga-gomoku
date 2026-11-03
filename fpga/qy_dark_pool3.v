`timescale 1ns/1ps
`default_nettype none
// Preserve thin dark marks when reducing an RGB888 raster by exactly 3.
// Input: a complete row-major raster, arbitrary valid-low bubbles/blanking.
// (0,0) starts/restarts capture; after reset other coordinates are ignored.
// Output: min((R+2G+B)>>2) over each non-overlapping 3x3 source block.
// A block's right-bottom input is accepted at edge E; its output is valid
// just after E+2. Older completed blocks may drain across a new (0,0).
// Synchronous reset flushes validity without clearing either line RAM.
module qy_dark_pool3 #(
    parameter WIDTH = 1920,
    parameter HEIGHT = 1080
)(
    input wire clk_i,
    input wire rst_n_i,
    input wire valid_i,
    input wire [11:0] x_i,
    input wire [11:0] y_i,
    input wire [23:0] rgb_i,
    output reg valid_o,
    output reg [9:0] x_o,
    output reg [8:0] y_o,
    output reg [7:0] gray_o
);
    localparam TW = WIDTH / 3;
    localparam TH = HEIGHT / 3;
    (* ram_style = "bram" *) reg [7:0] line0 [0:TW-1];
    (* ram_style = "bram" *) reg [7:0] line1 [0:TW-1];
    reg [7:0] read0, read1;

    reg armed;
    reg [1:0] col_phase, row_phase;
    reg [9:0] block_x;
    reg [8:0] block_y;
    reg [7:0] horizontal_min;

    // PH1A ERAM controls must remain physical synchronous FF boundaries.
    // Nothing asynchronous (including reset) fans directly into RAM ports.
    (* keep = "true" *) reg [9:0] ram_addr_q;
    (* keep = "true" *) reg [7:0] ram_data_q;
    (* keep = "true" *) reg row0_we_q, row1_we_q, read_en_q;
    reg [8:0] ram_y_q;
    reg row_ready_q;
    reg [7:0] bottom_min_q;
    reg [9:0] result_x_q;
    reg [8:0] result_y_q;

    wire [9:0] gray_sum = {2'b00,rgb_i[23:16]} +
                           {1'b0,rgb_i[15:8],1'b0} +
                           {2'b00,rgb_i[7:0]};
    wire [7:0] gray_now = gray_sum[9:2];
    wire [7:0] row_min = horizontal_min < gray_now ? horizontal_min : gray_now;
    wire [7:0] top_min = read0 < read1 ? read0 : read1;
    wire source_valid = valid_i && x_i < WIDTH && y_i < HEIGHT;
    wire frame_start = source_valid && x_i == 0 && y_i == 0;

    always @(posedge clk_i) begin
        if(row0_we_q) line0[ram_addr_q] <= ram_data_q;
        if(row1_we_q) line1[ram_addr_q] <= ram_data_q;
        // No output consumes a RAM read on a write cycle. Thus inference may
        // choose any read-during-write mode without changing valid results.
        if(read_en_q) begin
            read0 <= line0[ram_addr_q];
            read1 <= line1[ram_addr_q];
        end
    end

    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            armed <= 0;
            col_phase <= 0; row_phase <= 0;
            block_x <= 0; block_y <= 0; horizontal_min <= 0;
            ram_addr_q <= 0; ram_data_q <= 0; ram_y_q <= 0;
            row0_we_q <= 0; row1_we_q <= 0; read_en_q <= 0;
            row_ready_q <= 0; bottom_min_q <= 0;
            result_x_q <= 0; result_y_q <= 0;
            valid_o <= 0; x_o <= 0; y_o <= 0; gray_o <= 0;
        end else begin
            row0_we_q <= 0; row1_we_q <= 0; read_en_q <= 0;
            row_ready_q <= read_en_q;
            if(read_en_q) begin
                bottom_min_q <= ram_data_q;
                result_x_q <= ram_addr_q;
                result_y_q <= ram_y_q;
            end
            valid_o <= row_ready_q;
            if(row_ready_q) begin
                x_o <= result_x_q; y_o <= result_y_q;
                gray_o <= top_min < bottom_min_q ? top_min : bottom_min_q;
            end

            if(frame_start) begin
                armed <= 1;
                row_phase <= 0; block_y <= 0;
                col_phase <= 1; block_x <= 0;
                horizontal_min <= gray_now;
            end else if(source_valid && armed) begin
                if(x_i == 0) begin
                    col_phase <= 1; block_x <= 0;
                    horizontal_min <= gray_now;
                end else if(col_phase == 0) begin
                    col_phase <= 1;
                    horizontal_min <= gray_now;
                end else if(col_phase == 1) begin
                    col_phase <= 2;
                    horizontal_min <= row_min;
                end else begin
                    col_phase <= 0;
                    ram_addr_q <= block_x;
                    ram_data_q <= row_min;
                    ram_y_q <= block_y;
                    row0_we_q <= row_phase == 0;
                    row1_we_q <= row_phase == 1;
                    read_en_q <= row_phase == 2;
                    block_x <= block_x + 1'b1;
                end
                if(x_i == WIDTH-1) begin
                    if(row_phase == 2) begin
                        row_phase <= 0;
                        block_y <= block_y + 1'b1;
                    end else row_phase <= row_phase + 1'b1;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if(WIDTH < 3 || HEIGHT < 3 || WIDTH > 3072 || HEIGHT > 1536 ||
           WIDTH % 3 != 0 || HEIGHT % 3 != 0 || TW > 1024 || TH > 512)
            $fatal(1,"CONFIG_ERROR dark_pool3 dimensions");
    end
    // synthesis translate_on
endmodule
`default_nettype wire
