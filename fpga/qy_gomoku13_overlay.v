`timescale 1ns/1ps
`default_nettype none
// Free-running display timing is independent of camera/DDR readiness.
// The camera viewport remains a crop, not a full-frame scaler.
module qy_gomoku13_overlay #(parameter HOLD_FRAMES=90, END_FRAMES=180)(
    input wire clk_i,rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i,hs_i,vs_i,
    input wire camera_ready_i,
    input wire [20:0] status_i,
    output wire frame_tick_o,
    output wire [23:0] rgb_o,
    output wire de_o,hs_o,vs_o
);
    reg [11:0] x,y;
    reg de_d,vs_d,frame_bad,ready_frame;
    reg [20:0] status_frame;
    wire frame_edge=vs_i&&!vs_d;
    wire frame_good=y==1080&&!frame_bad;
    assign frame_tick_o=frame_edge;
    always @(posedge clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            x<=0;y<=0;de_d<=0;vs_d<=0;frame_bad<=0;
            ready_frame<=0;status_frame<=0;
        end else begin
            de_d<=de_i;vs_d<=vs_i;
            if(frame_edge) begin
                x<=0;y<=0;frame_bad<=0;
                ready_frame<=frame_good&&camera_ready_i;status_frame<=status_i;
            end else if(de_i) begin
                if(x<4095)x<=x+1'b1;
                if(x>=1920||y>=1080)frame_bad<=1;
            end else begin
                x<=0;
                if(de_d) begin
                    if(x!=1920)frame_bad<=1;
                    if(y<4095)y<=y+1'b1;
                end
            end
        end
    end
    wire [23:0] render_rgb;
    wire [11:0] render_x,render_y;
    wire [337:0] game_board;
    wire [7:0] last_index,black_index,white_index;
    wire last_valid,recommendations_valid,game_over,draw,fault;
    wire [1:0] next_color,winner,black_reason,white_reason;
    wire [7:0] move_count;
    wire [2:0] phase;
    qy_gomoku13_demo #(.HOLD_FRAMES(HOLD_FRAMES),.END_FRAMES(END_FRAMES)) game(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.frame_tick_i(frame_edge),
        .board_o(game_board),.last_index_o(last_index),.last_valid_o(last_valid),
        .next_color_o(next_color),.winner_o(winner),.game_over_o(game_over),.draw_o(draw),.move_count_o(move_count),
        .black_index_o(black_index),.white_index_o(white_index),.recommendations_valid_o(recommendations_valid),
        .black_reason_o(black_reason),.white_reason_o(white_reason),.phase_o(phase),.fault_o(fault));
    qy_gomoku13_renderer render(
        .clk_i(clk_i),.rst_n_i(rst_n_i),.x_i(x),.y_i(y),
        .de_i(de_i),.hs_i(hs_i),.vs_i(vs_i),.frame_commit_i(frame_edge),
        .page_i(2'd0),.selected_i(2'd0),.board_i(game_board),
        .last_index_i(last_index),.black_index_i(black_index),.white_index_i(white_index),
        .last_valid_i(last_valid),.black_valid_i(recommendations_valid),.white_valid_i(recommendations_valid),
        .next_color_i(next_color),.camera_ready_i(frame_good&&camera_ready_i),
        .calibrated_i(1'b0),.ai_ready_i(recommendations_valid),.paused_i(game_over),.demo_i(1'b1),
        .phase_i(phase),.winner_i(winner),.draw_i(draw),.move_count_i(move_count),
        .black_reason_i(black_reason),.white_reason_i(white_reason),
        .camera_rgb_i(rgb_i),.camera_pixel_valid_i(de_i),
        .rgb_o(render_rgb),.de_o(de_o),.hs_o(hs_o),.vs_o(vs_o),.x_o(render_x),.y_o(render_y)
    );
    wire status_ink;
    qy_camera_startup_text debug_line(.x_i(render_x),.y_i(render_y),.status_i(status_frame),
        .visible_i(!ready_frame),.ink_o(status_ink));
    assign rgb_o=(de_o&&status_ink)?24'hf4b65d:render_rgb;
endmodule
`default_nettype wire
