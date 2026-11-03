`timescale 1ns/1ps
`default_nettype none
module qy_clip_nn_idle #(parameter ENABLE_PREVIEW=0,ENABLE_PERF=1)(
input wire nn_clk,bus_clk,reset_n,
input wire [31:0] perf_capture_start,perf_capture_end,perf_capture_ready,
input wire video_clk,video_blank,input wire [15:0] preview_read_address,
output wire [15:0] preview_rgb565,output wire [1:0] preview_mask,output wire preview_valid,
output wire [31:0] preview_tag,preview_frame,
output wire bus_reset_n,
output wire lease_req_valid,input wire lease_req_ready,output wire [31:0] lease_req_tag,
input wire lease_valid,output wire lease_ready,input wire [31:0] lease_tag,lease_frame,lease_base,input wire [7:0] lease_status,
output wire release_valid,input wire release_ready,output wire [31:0] release_tag,
output wire diag_valid,input wire diag_ready,output wire [639:0] diag_data,
output wire spi_cs_n,spi_clk,spi_mosi,input wire spi_miso,
output wire [31:0] n_awaddr,
output wire [3:0] n_awid,
output wire [7:0] n_awlen,
output wire [2:0] n_awsize,
output wire [1:0] n_awburst,
output wire n_awlock,
output wire [3:0] n_awcache,
output wire [2:0] n_awprot,
output wire [3:0] n_awqos,
output wire n_awvalid,
output wire [255:0] n_wdata,
output wire [31:0] n_wstrb,
output wire n_wlast,
output wire n_wvalid,
output wire [31:0] n_araddr,
output wire [3:0] n_arid,
output wire [7:0] n_arlen,
output wire [2:0] n_arsize,
output wire [1:0] n_arburst,
output wire n_arlock,
output wire [3:0] n_arcache,
output wire [2:0] n_arprot,
output wire [3:0] n_arqos,
output wire n_arvalid,
output wire n_rready,
output wire n_bready,
input wire n_awready,
input wire n_wready,
input wire n_arready,
input wire [255:0] n_rdata,
input wire [3:0] n_rid,
input wire [1:0] n_rresp,
input wire n_rlast,
input wire n_rvalid,
input wire [3:0] n_bid,
input wire [1:0] n_bresp,
input wire n_bvalid
);
// Diagnostic capture only. Original NN implementation is not instantiated.
assign preview_rgb565 = 'd0;
assign preview_mask = 'd0;
assign preview_valid = 'd0;
assign preview_tag = 'd0;
assign preview_frame = 'd0;
assign lease_req_valid = 'd0;
assign lease_req_tag = 'd0;
assign lease_ready = 'd1;
assign release_valid = 'd0;
assign release_tag = 'd0;
assign diag_valid = 'd0;
assign diag_data = 'd0;
assign spi_cs_n = 'd1;
assign spi_clk = 'd0;
assign spi_mosi = 'd0;
assign n_awaddr = 'd0;
assign n_awid = 'd0;
assign n_awlen = 'd0;
assign n_awsize = 'd0;
assign n_awburst = 'd0;
assign n_awlock = 'd0;
assign n_awcache = 'd0;
assign n_awprot = 'd0;
assign n_awqos = 'd0;
assign n_awvalid = 'd0;
assign n_wdata = 'd0;
assign n_wstrb = 'd0;
assign n_wlast = 'd0;
assign n_wvalid = 'd0;
assign n_araddr = 'd0;
assign n_arid = 'd0;
assign n_arlen = 'd0;
assign n_arsize = 'd0;
assign n_arburst = 'd0;
assign n_arlock = 'd0;
assign n_arcache = 'd0;
assign n_arprot = 'd0;
assign n_arqos = 'd0;
assign n_arvalid = 'd0;
assign n_rready = 'd1;
assign n_bready = 'd1;
qy_reset_sync br(.clk_i(bus_clk),.arst_n_i(reset_n),.rst_n_o(bus_reset_n));
endmodule
`default_nettype wire
