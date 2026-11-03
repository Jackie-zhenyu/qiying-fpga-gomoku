`timescale 1ns / 1ps
`default_nettype none
// Bring-up overlay for an ALREADY ALIGNED 1920x1080 RGB/DE/HS/VS stream.
// Camera viewport shows the original pixels at that position (a live crop,
// not a scaled full frame). No camera, DDR or output clock is regenerated.
module qy_camera_overlay(
    input wire clk_i, rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i, hs_i, vs_i,
    output wire [23:0] rgb_o,
    output wire de_o, hs_o, vs_o
);
    reg [11:0] x, y;
    reg de_d, vs_d, frame_bad;
    wire frame_edge = vs_i && !vs_d;
    wire frame_good = y == 1080 && !frame_bad;
    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            x<=0; y<=0; de_d<=0; vs_d<=0; frame_bad<=0;
        end else begin
            de_d<=de_i; vs_d<=vs_i;
            if (frame_edge) begin
                x<=0; y<=0; frame_bad<=0;
            end else if (de_i) begin
                if (x<4095) x<=x+1'b1;
                if (x>=1920 || y>=1080) frame_bad<=1;
            end else begin
                x<=0;
                if (de_d) begin
                    if (x!=1920) frame_bad<=1;
                    if (y<4095) y<=y+1'b1;
                end
            end
        end
    end
    qy_ui_renderer render(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.x_i(x),.y_i(y),
        .de_i(de_i),.hs_i(hs_i),.vs_i(vs_i),.frame_commit_i(frame_edge),
        .page_i(2'd0),.selected_i(2'd0),.board_i(162'd0),
        .last_index_i(7'd0),.black_index_i(7'd0),.white_index_i(7'd0),
        .last_valid_i(1'b0),.black_valid_i(1'b0),.white_valid_i(1'b0),
        .next_color_i(2'd0),.camera_ready_i(frame_good),
        .calibrated_i(1'b0),.ai_ready_i(1'b0),.paused_i(1'b0),.demo_i(1'b1),
        .camera_rgb_i(rgb_i),.camera_pixel_valid_i(de_i),
        .rgb_o(rgb_o),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o),.x_o(),.y_o()
    );
endmodule
`default_nettype wire
