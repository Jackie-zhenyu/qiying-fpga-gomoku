`timescale 1ns/1ps
`default_nettype none
// Diagnostic acquisition only. Camera/ISP and game logic continue on the FPGA.
// This wrapper does not receive or modify any official game state.
module qy_capture_system #(
    parameter integer ADDR_WIDTH=32,
    parameter integer WIDTH=1920, HEIGHT=1080
)(
    input wire bus_clk, uart_clk, reset_n,
    input wire uart_rx, output wire uart_tx,
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
        .frame_error(frame_error),.tx_byte_valid(tx_byte_valid),
        .tx_byte_ready(tx_byte_ready),.tx_byte(tx_byte),.packet_done(packet_done)
    );
    qy_capture_memory #(.ADDR_WIDTH(ADDR_WIDTH),.WIDTH(WIDTH),.HEIGHT(HEIGHT)) snapshot(
        .clk(bus_clk),.rst_n(bus_reset_n),
        .req_valid(req_valid),.req_ready(req_ready),.req_nonce(req_nonce),
        .begin_valid(begin_valid),.begin_ready(begin_ready),
        .begin_nonce(begin_nonce),.begin_frame_id(begin_frame_id),.begin_status(begin_status),
        .rgb_byte_valid(rgb_byte_valid),.rgb_byte_ready(rgb_byte_ready),.rgb_byte(rgb_byte),
        .frame_error(frame_error),.packet_done(packet_done),
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
