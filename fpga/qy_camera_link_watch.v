`timescale 1ns/1ps
`default_nettype none
// Camera frame activity crosses through a toggle, not a narrow pulse.
// The free-running display frame tick supplies the watchdog timebase.
// DDR step/error bytes are diagnostic only; accept two equal samples before
// displaying them. They are not used as a coherent functional control word.
module qy_camera_link_watch #(
    parameter integer TIMEOUT_FRAMES=8
)(
    input wire pixel_clk_i, rst_n_i, frame_tick_i,
    input wire camera_clk_i, camera_frame_end_i,
    input wire ddr_pll_i, ddr_done_i, buffer_ready_i, camera_configured_i,
    input wire [7:0] ddr_error_i, ddr_step_i,
    output wire camera_ready_o,
    output wire [20:0] status_o
);
    wire camera_rst_n;
    qy_reset_sync source_reset(.clk_i(camera_clk_i),.arst_n_i(rst_n_i),.rst_n_o(camera_rst_n));
    reg frame_d, frame_toggle;
    always @(posedge camera_clk_i or negedge camera_rst_n) begin
        if(!camera_rst_n) begin frame_d<=0; frame_toggle<=0; end
        else begin
            frame_d<=camera_frame_end_i;
            if(camera_frame_end_i && !frame_d) frame_toggle<=~frame_toggle;
        end
    end
    (* ASYNC_REG="TRUE" *) reg [1:0] toggle_sync;
    (* ASYNC_REG="TRUE" *) reg [3:0] ready_meta,ready_sync;
    (* ASYNC_REG="TRUE" *) reg [15:0] detail_meta,detail_sync;
    reg [15:0] detail_previous,detail_stable;
    reg toggle_seen;
    reg [3:0] alive_count;
    always @(posedge pixel_clk_i or negedge rst_n_i) begin
        if(!rst_n_i) begin
            toggle_sync<=0; toggle_seen<=0; alive_count<=0;
            ready_meta<=0; ready_sync<=0;
            detail_meta<=0; detail_sync<=0; detail_previous<=0; detail_stable<=0;
        end else begin
            toggle_sync<={toggle_sync[0],frame_toggle};
            toggle_seen<=toggle_sync[1];
            ready_meta<={ddr_pll_i,ddr_done_i,buffer_ready_i,camera_configured_i};
            ready_sync<=ready_meta;
            detail_meta<={ddr_error_i,ddr_step_i};
            detail_sync<=detail_meta; detail_previous<=detail_sync;
            if(detail_sync==detail_previous) detail_stable<=detail_sync;
            if(toggle_sync[1]!=toggle_seen) alive_count<=TIMEOUT_FRAMES;
            else if(frame_tick_i && alive_count!=0) alive_count<=alive_count-1'b1;
        end
    end
    assign camera_ready_o=(&ready_sync) && (alive_count!=0);
    assign status_o={alive_count!=0,ready_sync,detail_stable};
endmodule
`default_nettype wire
