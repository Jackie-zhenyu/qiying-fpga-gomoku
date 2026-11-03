`timescale 1ns/1ps
`default_nettype none
// Preserve the accepted 13x13 game, UI and four-stage renderer. Only the
// camera pixels are replaced by an atomically published full-frame thumbnail.
module qy_gomoku13_fit_overlay #(parameter HOLD_FRAMES=90,END_FRAMES=180)(
    input wire clk_i,rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,
    input wire camera_ready_i,
    input wire [20:0] status_i,
    output wire frame_tick_o,
    output wire [23:0] rgb_o,
    output wire de_o,hs_o,vs_o
);
    wire [23:0] thumbnail_rgb;
    wire thumbnail_de,thumbnail_hs,thumbnail_vs,thumbnail_ready;
    reg [20:0] status_d,status_dd;
    always @(posedge clk_i)
        if(!rst_n_i)begin status_d<=0;status_dd<=0;end
        else begin status_d<=status_i;status_dd<=status_d;end
    qy_camera_thumbnail fit(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.rgb_i(rgb_i),
        .de_i(de_i),.hs_i(hs_i),.vs_i(vs_i),.camera_ready_i(camera_ready_i),
        .rgb_o(thumbnail_rgb),.de_o(thumbnail_de),.hs_o(thumbnail_hs),.vs_o(thumbnail_vs),
        .frame_valid_o(thumbnail_ready));
    qy_gomoku13_overlay #(.HOLD_FRAMES(HOLD_FRAMES),.END_FRAMES(END_FRAMES)) overlay(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.rgb_i(thumbnail_rgb),
        .de_i(thumbnail_de),.hs_i(thumbnail_hs),.vs_i(thumbnail_vs),
        .camera_ready_i(thumbnail_ready),.status_i(status_dd),
        .frame_tick_o(frame_tick_o),.rgb_o(rgb_o),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o));
endmodule
`default_nettype wire
