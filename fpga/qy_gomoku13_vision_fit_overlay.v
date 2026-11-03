`timescale 1ns/1ps
`default_nettype none
// Add a physical camera image branch; search and accepted preview are unchanged.
module qy_gomoku13_vision_fit_overlay #(parameter HOLD_FRAMES=90,END_FRAMES=180)(
    input wire clk_i,rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,camera_ready_i,
    input wire [20:0] status_i,
    output wire frame_tick_o,
    output wire [23:0] rgb_o,
    output wire de_o,hs_o,vs_o
);
    wire [23:0] ui_rgb;
    wire ui_de,ui_hs,ui_vs;
    wire [17:0] mask_addr;
    wire mask_ink,mask_valid;
    qy_gomoku13_search_fit_overlay #(.HOLD_FRAMES(HOLD_FRAMES),.END_FRAMES(END_FRAMES)) base(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.rgb_i(rgb_i),.de_i(de_i),.hs_i(hs_i),.vs_i(vs_i),
        .camera_ready_i(camera_ready_i),.status_i(status_i),.frame_tick_o(frame_tick_o),
        .rgb_o(ui_rgb),.de_o(ui_de),.hs_o(ui_hs),.vs_o(ui_vs));
    qy_board_capture capture(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.rgb_i(rgb_i),.de_i(de_i),.vs_i(vs_i),
        .camera_ready_i(camera_ready_i),.read_addr_i(mask_addr),.ink_o(mask_ink),.image_valid_o(mask_valid));
    qy_vision_panel panel(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.rgb_i(ui_rgb),.de_i(ui_de),.hs_i(ui_hs),.vs_i(ui_vs),
        .image_valid_i(mask_valid),.ink_i(mask_ink),.read_addr_o(mask_addr),
        .rgb_o(rgb_o),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o));
endmodule
`default_nettype wire
