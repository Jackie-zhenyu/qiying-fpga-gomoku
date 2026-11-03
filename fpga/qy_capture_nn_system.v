`timescale 1ns/1ps
`default_nettype none
// Diagnostic acquisition only. Camera/ISP and game logic continue on the FPGA.
// This wrapper does not receive or modify any official game state.
module qy_capture_nn_system #(
    parameter integer ADDR_WIDTH=32,
    parameter integer WIDTH=1920, HEIGHT=1080
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
    wire bus_reset_n, uart_reset_n;
    qy_reset_sync bus_reset(.clk_i(bus_clk),.arst_n_i(reset_n),.rst_n_o(bus_reset_n));
    qy_reset_sync uart_reset(.clk_i(uart_clk),.arst_n_i(reset_n),.rst_n_o(uart_reset_n));
    wire req_valid, req_ready;
    wire [63:0] req_nonce;
    wire begin_valid, begin_ready;
    wire [63:0] begin_nonce;
    wire [31:0] begin_frame_id;
    wire [7:0] begin_status;
    wire rgb_byte_valid, rgb_byte_ready;
    wire [7:0] rgb_byte;
    wire frame_error, packet_done;
    wire tx_byte_valid, tx_byte_ready;
    wire [7:0] tx_byte;

    wire packet_tx_valid,packet_tx_ready,diag_byte_valid,diag_byte_ready,diag_busy,diag_start_ready;
    wire [7:0] packet_tx_data,diag_byte;
    qy_capture_uart_bridge serial_bridge(
        .bus_clk(bus_clk),.bus_reset_n(bus_reset_n),
        .uart_clk(uart_clk),.uart_reset_n(uart_reset_n),
        .uart_rx(uart_rx),.uart_tx(uart_tx),
        .req_valid(req_valid),.req_ready(req_ready),.req_nonce(req_nonce),
        .tx_byte_valid(tx_byte_valid),.tx_byte_ready(tx_byte_ready),.tx_byte(tx_byte)
    );
    qy_capture_packet #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),
        .SOURCE_WIDTH(WIDTH),.SOURCE_HEIGHT(HEIGHT)) packet(
        .bus_clk(bus_clk),.bus_reset_n(bus_reset_n),
        .begin_valid(begin_valid),.begin_ready(begin_ready),
        .begin_nonce(begin_nonce),.begin_frame_id(begin_frame_id),.begin_status(begin_status),
        .rgb_byte_valid(rgb_byte_valid),.rgb_byte_ready(rgb_byte_ready),.rgb_byte(rgb_byte),
        .frame_error(frame_error),.tx_byte_valid(packet_tx_valid),
        .tx_byte_ready(packet_tx_ready),.tx_byte(packet_tx_data),.packet_done(packet_done)
    );
    reg nn_owner,request_active,response_accepted;
    reg [31:0] owner_tag;
    wire snap_req_ready,snap_begin_valid,snap_packet_done;
    wire [31:0] snap_frame_base;
    wire diag_grant=(!request_active||nn_owner)&&!req_valid;
    assign diag_ready=diag_grant&&diag_start_ready;
    qy_diagnostic_packet diagnostic(.clk(bus_clk),.rst_n(bus_reset_n),
        .start_valid(diag_valid&&diag_grant),.start_ready(diag_start_ready),.start_data(diag_data),
        .byte_valid(diag_byte_valid),.byte_ready(diag_byte_ready),.byte_data(diag_byte),.busy(diag_busy));
    assign tx_byte_valid=diag_busy?diag_byte_valid:packet_tx_valid;
    assign tx_byte=diag_busy?diag_byte:packet_tx_data;
    assign diag_byte_ready=diag_busy&&tx_byte_ready;
    assign packet_tx_ready=!diag_busy&&tx_byte_ready;
    wire snap_request=(req_valid||lease_req_valid)&&!diag_busy;
    assign req_ready=snap_req_ready&&!request_active&&!diag_busy;
    assign lease_req_ready=snap_req_ready&&!request_active&&!req_valid&&!diag_busy;
    assign begin_valid=snap_begin_valid&&!nn_owner;
    assign lease_valid=snap_begin_valid&&nn_owner;
    assign lease_tag=owner_tag;assign lease_frame=begin_frame_id;assign lease_base=snap_frame_base;assign lease_status=begin_status;
    assign release_ready=request_active&&nn_owner&&response_accepted&&(release_tag==owner_tag);
    assign snap_packet_done=nn_owner?(release_valid&&release_ready):packet_done;
    always @(posedge bus_clk) begin
        if(!bus_reset_n) begin nn_owner<=0;request_active<=0;response_accepted<=0;owner_tag<=0;end
        else begin
            if(snap_request&&snap_req_ready&&!request_active) begin
                nn_owner<=!req_valid;request_active<=1;response_accepted<=0;owner_tag<=lease_req_tag;
            end
            if(snap_begin_valid&&(nn_owner?lease_ready:begin_ready)) response_accepted<=1;
            if(snap_packet_done) begin request_active<=0;response_accepted<=0;end
        end
    end
    qy_capture_lease_memory #(.ADDR_WIDTH(ADDR_WIDTH),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) snapshot(
        .clk(bus_clk),.rst_n(bus_reset_n),
        .req_valid(snap_request&&!request_active),.req_ready(snap_req_ready),.req_nonce(req_valid?req_nonce:{32'd0,lease_req_tag}),
        .req_export(req_valid),.begin_frame_base(snap_frame_base),
        .perf_capture_start(perf_capture_start),.perf_capture_end(perf_capture_end),.perf_capture_ready(perf_capture_ready),
        .begin_valid(snap_begin_valid),.begin_ready(nn_owner?lease_ready:begin_ready),
        .begin_nonce(begin_nonce),.begin_frame_id(begin_frame_id),.begin_status(begin_status),
        .rgb_byte_valid(rgb_byte_valid),.rgb_byte_ready(rgb_byte_ready),.rgb_byte(rgb_byte),
        .frame_error(frame_error),.packet_done(snap_packet_done),
        .dbuf_waddr(dbuf_waddr),.dbuf_wreq(dbuf_wreq),.dbuf_wsize(dbuf_wsize),
        .fdma_wbusy(fdma_wbusy),.fdma_wvalid(fdma_wvalid),.mapped_waddr(mapped_waddr),
        .axi_aw_fire(axi_aw_fire),.axi_b_fire(axi_b_fire),.axi_b_error(axi_b_error),
        .dbuf_raddr(dbuf_raddr),.dbuf_rreq(dbuf_rreq),.dbuf_rsize(dbuf_rsize),
        .dbuf_rbusy(dbuf_rbusy),.dbuf_rvalid(dbuf_rvalid),.dbuf_rdata(dbuf_rdata),
        .fdma_raddr(fdma_raddr),.fdma_rreq(fdma_rreq),.fdma_rsize(fdma_rsize),
        .fdma_rready(fdma_rready),.fdma_rbusy(fdma_rbusy),
        .fdma_rvalid(fdma_rvalid),.fdma_rdata(fdma_rdata),.axi_r_error(axi_r_error)
    );
endmodule
`default_nettype wire
