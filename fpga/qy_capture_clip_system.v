`timescale 1ns/1ps
`default_nettype none
// Diagnostic acquisition only. Camera/ISP and game logic continue on the FPGA.
// This wrapper does not receive or modify any official game state.
module qy_capture_clip_system #(
    parameter integer ADDR_WIDTH=32,
    parameter integer WIDTH=1920, HEIGHT=1080,
    parameter [31:0] BUS_HZ=233372000,
    parameter [63:0] CLIP_PERIOD_TICKS=46674400,CLIP_DELAY_TICKS=466744000
)(
    input wire bus_clk, uart_clk, reset_n,
    output wire [31:0] perf_capture_start,perf_capture_end,perf_capture_ready,
    input wire uart_rx, output wire uart_tx,
    input wire lease_req_valid, output wire lease_req_ready, input wire [31:0] lease_req_tag,
    output wire lease_valid, input wire lease_ready, output wire [31:0] lease_tag, lease_frame, lease_base,
    output wire [7:0] lease_status,
    input wire release_valid, output wire release_ready, input wire [31:0] release_tag,
    input wire diag_valid, output wire diag_ready, input wire [639:0] diag_data,
    input wire [ADDR_WIDTH-1:0] dbuf_waddr,
    input wire dbuf_wreq, input wire [15:0] dbuf_wsize,
    input wire fdma_wbusy, fdma_wvalid,
    output wire [ADDR_WIDTH-1:0] mapped_waddr,
    input wire axi_aw_fire, axi_b_fire, axi_b_error,
    input wire [ADDR_WIDTH-1:0] dbuf_raddr,
    input wire dbuf_rreq, input wire [15:0] dbuf_rsize,
    output wire dbuf_rbusy, dbuf_rvalid,
    output wire [255:0] dbuf_rdata,
    output wire [ADDR_WIDTH-1:0] fdma_raddr,
    output wire fdma_rreq, output wire [15:0] fdma_rsize,
    output wire fdma_rready,
    input wire fdma_rbusy, fdma_rvalid,
    input wire [255:0] fdma_rdata,
    input wire axi_r_error
);

    wire bus_reset_n,uart_reset_n;
    qy_reset_sync br(.clk_i(bus_clk),.arst_n_i(reset_n),.rst_n_o(bus_reset_n));
    qy_reset_sync ur(.clk_i(uart_clk),.arst_n_i(reset_n),.rst_n_o(uart_reset_n));
    wire req_valid,req_ready;wire [63:0] req_nonce;
    wire tx_valid,tx_ready;wire [7:0] tx_byte;
    qy_capture_uart_bridge serial_bridge(.bus_clk(bus_clk),.bus_reset_n(bus_reset_n),
        .uart_clk(uart_clk),.uart_reset_n(uart_reset_n),.uart_rx(uart_rx),.uart_tx(uart_tx),
        .req_valid(req_valid),.req_ready(req_ready),.req_nonce(req_nonce),
        .tx_byte_valid(tx_valid),.tx_byte_ready(tx_ready),.tx_byte(tx_byte));
    wire clip_command=req_nonce[63:48]==16'h434c;
    wire ctrl_cmd_ready,ctrl_reply_valid,ctrl_reply_ready,ctrl_lock,ctrl_clear;
    wire [639:0] ctrl_reply_data;
    wire ctrl_req_valid,ctrl_req_ready,ctrl_retain,ctrl_replay,ctrl_export,ctrl_subsample;
    wire [63:0] ctrl_nonce,current_tick,retained_slots;
    wire [5:0] ctrl_slot,clip_count;wire [31:0] ctrl_frame,clip_epoch;
    wire [7:0] clip_error;wire recording;
    wire ctrl_response_ready,ctrl_release;
    wire snap_req_ready,snap_begin_valid,snap_begin_ready,snap_done;
    wire [63:0] snap_nonce,frame_start_tick,frame_end_tick,frame_ready_tick;
    wire [31:0] snap_frame,snap_base;wire [7:0] snap_status;
    wire pixel_valid,pixel_ready,frame_error;wire [7:0] pixel;
    wire full_valid,full_ready,full_begin_ready,full_pixel_ready,full_done;
    wire small_valid,small_ready,small_begin_ready,small_pixel_ready,small_done;
    wire [7:0] full_byte,small_byte;
    wire diag_valid_wire,diag_ready_wire,diag_busy,diag_start_ready;wire [7:0] diag_byte;
    localparam HOST=0,NN=1,CLIP_RECORD=2,CLIP_READ=3;
    reg [1:0] owner;
    reg request_active,response_accepted;reg [31:0] owner_tag;
    wire admission=!request_active&&!diag_busy;
    wire host_request=req_valid&&!clip_command&&!ctrl_lock;
    wire nn_request=lease_req_valid&&!ctrl_lock&&!req_valid;
    wire snap_request=admission&&(ctrl_req_valid||host_request||nn_request);
    wire chosen_clip=ctrl_req_valid;
    wire chosen_host=!chosen_clip&&host_request;
    assign ctrl_req_ready=snap_req_ready&&admission;
    assign req_ready=clip_command?ctrl_cmd_ready:(snap_req_ready&&admission&&!ctrl_lock&&!ctrl_req_valid);
    assign lease_req_ready=snap_req_ready&&admission&&!ctrl_lock&&!req_valid&&!ctrl_req_valid;
    assign lease_valid=snap_begin_valid&&owner==NN;
    assign lease_tag=owner_tag;assign lease_frame=snap_frame;assign lease_base=snap_base;assign lease_status=snap_status;
    assign release_ready=request_active&&owner==NN&&response_accepted&&release_tag==owner_tag;
    assign snap_done=owner==NN?(release_valid&&release_ready):owner==CLIP_RECORD?ctrl_release:owner==CLIP_READ?small_done:full_done;
    assign snap_begin_ready=owner==NN?lease_ready:owner==CLIP_RECORD?ctrl_response_ready:owner==CLIP_READ?small_begin_ready:full_begin_ready;
    assign pixel_ready=owner==CLIP_READ?small_pixel_ready:full_pixel_ready;
    qy_clip_controller #(.BUS_HZ(BUS_HZ),.PERIOD_TICKS(CLIP_PERIOD_TICKS),.DELAY_TICKS(CLIP_DELAY_TICKS)) controller(
        .clk(bus_clk),.rst(!bus_reset_n),.cmd_valid(req_valid&&clip_command),.cmd_ready(ctrl_cmd_ready),.cmd_nonce(req_nonce),
        .reply_valid(ctrl_reply_valid),.reply_ready(ctrl_reply_ready),.reply_data(ctrl_reply_data),.current_tick(current_tick),
        .lock_new_clients(ctrl_lock),.clear_clip(ctrl_clear),.memory_idle(snap_req_ready&&!request_active&&!diag_busy),
        .request_valid(ctrl_req_valid),.request_ready(ctrl_req_ready),.request_retain(ctrl_retain),.request_replay(ctrl_replay),
        .request_export(ctrl_export),.request_subsample(ctrl_subsample),.request_nonce(ctrl_nonce),.request_slot(ctrl_slot),.request_frame(ctrl_frame),
        .response_valid(snap_begin_valid&&(owner==CLIP_RECORD||owner==CLIP_READ)),.response_ready(ctrl_response_ready),
        .response_status(snap_status),.response_frame(snap_frame),.response_base(snap_base),
        .response_start_tick(frame_start_tick),.response_end_tick(frame_end_tick),.response_ready_tick(frame_ready_tick),
        .release_frame(ctrl_release),.replay_packet_done(small_done),.captured_count(clip_count),.clip_epoch(clip_epoch),.clip_error(clip_error),.recording(recording));
    always @(posedge bus_clk) begin
        if(!bus_reset_n)begin owner<=HOST;request_active<=0;response_accepted<=0;owner_tag<=0;end
        else begin
            if(snap_request&&snap_req_ready)begin
                owner<=chosen_clip?(ctrl_replay?CLIP_READ:CLIP_RECORD):chosen_host?HOST:NN;
                request_active<=1;response_accepted<=0;owner_tag<=lease_req_tag;
            end
            if(snap_begin_valid&&snap_begin_ready)response_accepted<=1;
            if(snap_done)begin request_active<=0;response_accepted<=0;end
        end
    end
    qy_capture_packet #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.SOURCE_WIDTH(WIDTH),.SOURCE_HEIGHT(HEIGHT)) full_packet(
        .bus_clk(bus_clk),.bus_reset_n(bus_reset_n),.begin_valid(snap_begin_valid&&owner==HOST),.begin_ready(full_begin_ready),
        .begin_nonce(snap_nonce),.begin_frame_id(snap_frame),.begin_status(snap_status),
        .rgb_byte_valid(pixel_valid&&owner==HOST),.rgb_byte_ready(full_pixel_ready),.rgb_byte(pixel),.frame_error(frame_error),
        .tx_byte_valid(full_valid),.tx_byte_ready(full_ready),.tx_byte(full_byte),.packet_done(full_done));
    qy_capture_packet #(.WIDTH(WIDTH/3),.HEIGHT(HEIGHT/3),.SOURCE_WIDTH(WIDTH),.SOURCE_HEIGHT(HEIGHT)) small_packet(
        .bus_clk(bus_clk),.bus_reset_n(bus_reset_n),.begin_valid(snap_begin_valid&&owner==CLIP_READ),.begin_ready(small_begin_ready),
        .begin_nonce(snap_nonce),.begin_frame_id(snap_frame),.begin_status(snap_status),
        .rgb_byte_valid(pixel_valid&&owner==CLIP_READ),.rgb_byte_ready(small_pixel_ready),.rgb_byte(pixel),.frame_error(frame_error),
        .tx_byte_valid(small_valid),.tx_byte_ready(small_ready),.tx_byte(small_byte),.packet_done(small_done));
    wire diag_grant=(!request_active||owner==NN||owner==CLIP_RECORD);
    assign ctrl_reply_ready=diag_grant&&diag_start_ready;
    assign diag_ready=diag_grant&&diag_start_ready&&!ctrl_reply_valid;
    qy_diagnostic_packet diagnostic(.clk(bus_clk),.rst_n(bus_reset_n),
        .start_valid(diag_grant&&(ctrl_reply_valid||diag_valid)),.start_ready(diag_start_ready),
        .start_data(ctrl_reply_valid?ctrl_reply_data:diag_data),.byte_valid(diag_valid_wire),.byte_ready(diag_ready_wire),.byte_data(diag_byte),.busy(diag_busy));
    assign tx_valid=diag_busy?diag_valid_wire:owner==CLIP_READ?small_valid:full_valid;
    assign tx_byte=diag_busy?diag_byte:owner==CLIP_READ?small_byte:full_byte;
    assign diag_ready_wire=diag_busy&&tx_ready;
    assign full_ready=!diag_busy&&owner==HOST&&tx_ready;
    assign small_ready=!diag_busy&&owner==CLIP_READ&&tx_ready;
    qy_capture_clip_memory #(.ADDR_WIDTH(ADDR_WIDTH),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) snapshot(
        .clk(bus_clk),.rst_n(bus_reset_n),.req_valid(snap_request),.req_ready(snap_req_ready),
        .req_nonce(chosen_clip?ctrl_nonce:chosen_host?req_nonce:{32'd0,lease_req_tag}),
        .req_export(chosen_clip?ctrl_export:chosen_host),.begin_frame_base(snap_base),
        .clip_clear(ctrl_clear),.req_retain(chosen_clip&&ctrl_retain),.req_replay(chosen_clip&&ctrl_replay),
        .req_subsample(chosen_clip&&ctrl_subsample),.req_replay_slot(ctrl_slot),.req_replay_frame(ctrl_frame),
        .frame_start_tick(frame_start_tick),.frame_end_tick(frame_end_tick),.frame_ready_tick(frame_ready_tick),
        .current_tick(current_tick),.retained_slots(retained_slots),
        .perf_capture_start(perf_capture_start),.perf_capture_end(perf_capture_end),.perf_capture_ready(perf_capture_ready),
        .begin_valid(snap_begin_valid),.begin_ready(snap_begin_ready),.begin_nonce(snap_nonce),.begin_frame_id(snap_frame),.begin_status(snap_status),
        .rgb_byte_valid(pixel_valid),.rgb_byte_ready(pixel_ready),.rgb_byte(pixel),.frame_error(frame_error),.packet_done(snap_done),
        .dbuf_waddr(dbuf_waddr),.dbuf_wreq(dbuf_wreq),.dbuf_wsize(dbuf_wsize),.fdma_wbusy(fdma_wbusy),.fdma_wvalid(fdma_wvalid),
        .mapped_waddr(mapped_waddr),.axi_aw_fire(axi_aw_fire),.axi_b_fire(axi_b_fire),.axi_b_error(axi_b_error),
        .dbuf_raddr(dbuf_raddr),.dbuf_rreq(dbuf_rreq),.dbuf_rsize(dbuf_rsize),.dbuf_rbusy(dbuf_rbusy),.dbuf_rvalid(dbuf_rvalid),.dbuf_rdata(dbuf_rdata),
        .fdma_raddr(fdma_raddr),.fdma_rreq(fdma_rreq),.fdma_rsize(fdma_rsize),.fdma_rready(fdma_rready),
        .fdma_rbusy(fdma_rbusy),.fdma_rvalid(fdma_rvalid),.fdma_rdata(fdma_rdata),.axi_r_error(axi_r_error));
endmodule
`default_nettype wire
