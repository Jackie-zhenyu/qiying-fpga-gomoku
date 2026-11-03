`timescale 1ns/1ps
`default_nettype none
module qy_yolo_board #(parameter ENABLE_PREVIEW=0,ENABLE_PERF=1)(
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
`include "qy_yolo_frozen_config.vh"
`include "qy_boot_frozen_config.vh"
wire nn_reset_n; wire nn_rst=!nn_reset_n,bus_rst=!bus_reset_n;
qy_reset_sync nr(.clk_i(nn_clk),
.arst_n_i(reset_n),
.rst_n_o(nn_reset_n));
qy_reset_sync br(.clk_i(bus_clk),
.arst_n_i(reset_n),
.rst_n_o(bus_reset_n));
wire [3:0] perf_program_phase,perf_opcode;wire [1:0] perf_mode;wire perf_display_ack;
wire [31:0] c_cap_start,c_cap_end,c_cap_ready;
wire c_rd_valid;
wire c_rd_ready;
wire [31:0] c_rd_addr;
wire c_rsp_valid;
wire c_rsp_ready;
wire [255:0] c_rsp_data;
wire c_rsp_error;
wire c_wr_valid;
wire c_wr_ready;
wire [31:0] c_wr_addr;
wire [255:0] c_wr_data;
wire [31:0] c_wr_strb;
wire c_ack_valid;
wire c_ack_ready;
wire c_ack_error;
wire m_rd_valid;
wire m_rd_ready;
wire [31:0] m_rd_addr;
wire m_rsp_valid;
wire m_rsp_ready;
wire [255:0] m_rsp_data;
wire m_rsp_error;
wire m_wr_valid;
wire m_wr_ready;
wire [31:0] m_wr_addr;
wire [255:0] m_wr_data;
wire [31:0] m_wr_strb;
wire m_ack_valid;
wire m_ack_ready;
wire m_ack_error;
wire c_lease_req_valid;
wire c_lease_req_ready;
wire [31:0] c_lease_req_tag;
wire c_lease_valid;
wire c_lease_ready;
wire [31:0] c_lease_tag;
wire [31:0] c_lease_frame;
wire [31:0] c_lease_base;
wire [7:0] c_lease_status;
wire c_release_valid;
wire c_release_ready;
wire [31:0] c_release_tag;
wire c_release_ack;
wire c_release_ack_ready;
wire c_result_valid;
wire c_result_ready;
wire [31:0] c_result_tag;
wire [8:0] c_result_index;
wire [191:0] c_result_data;
wire c_result_last;
wire c_job_start;
wire c_job_done;
wire c_job_success;
wire [31:0] c_job_frame;
wire [31:0] c_job_tag;
wire [3:0] c_phase;
wire [3:0] c_boot_phase;
wire [3:0] c_engine_phase;
wire [1:0] c_boot_asset;
wire c_model_ready;
wire [15:0] c_last_error;
wire [31:0] c_completed_jobs;
wire preview_begin_ready,preview_result_ready,telemetry_result_ready;
wire [7:0] preview_error;
wire raw_preview_valid;wire [9:0] raw_preview_x,raw_preview_y;wire [15:0] raw_preview_rgb565;
assign c_result_ready=telemetry_result_ready&&(perf_mode==1||preview_result_ready);
qy_yolo_runtime_fastrepeat #(.ENABLE_PREVIEW(ENABLE_PREVIEW),.INPUT_BASE(QY_INPUT_BASE),
.PROGRAM_BASE(QY_PROGRAM_BASE),
.PROGRAM_WORDS(QY_PROGRAM_WORDS),
.CLASS_BASES(QY_CLASS_BASES),
.BOX_BASES(QY_BOX_BASES),
.COORD_BASES(QY_COORD_BASES),
.HEADER_ADDRESS(QY_BOOT_HEADER_ADDRESS),
.FLASH_ADDRESSES(QY_BOOT_FLASH_ADDRESSES),
.DDR_ADDRESSES(QY_BOOT_DDR_ADDRESSES),
.LENGTHS(QY_BOOT_LENGTHS),
.CRCS(QY_BOOT_CRCS),
.DDR_LENGTHS(QY_BOOT_DDR_LENGTHS),
.DDR_CRCS(QY_BOOT_DDR_CRCS)) runtime(
.perf_program_phase(perf_program_phase),.perf_opcode(perf_opcode),.perf_mode(perf_mode),
.clk(nn_clk),
.rst(nn_rst),
.preview_ready(preview_begin_ready),.preview_valid(raw_preview_valid),.preview_x(raw_preview_x),.preview_y(raw_preview_y),.preview_rgb565(raw_preview_rgb565),
.rd_valid(c_rd_valid),
.rd_ready(c_rd_ready),
.rd_addr(c_rd_addr),
.rsp_valid(c_rsp_valid),
.rsp_ready(c_rsp_ready),
.rsp_data(c_rsp_data),
.rsp_error(c_rsp_error),
.wr_valid(c_wr_valid),
.wr_ready(c_wr_ready),
.wr_addr(c_wr_addr),
.wr_data(c_wr_data),
.wr_strb(c_wr_strb),
.ack_valid(c_ack_valid),
.ack_ready(c_ack_ready),
.ack_error(c_ack_error),
.lease_req_valid(c_lease_req_valid),
.lease_req_ready(c_lease_req_ready),
.lease_req_tag(c_lease_req_tag),
.lease_valid(c_lease_valid),
.lease_ready(c_lease_ready),
.lease_tag(c_lease_tag),
.lease_frame(c_lease_frame),
.lease_base(c_lease_base),
.lease_status(c_lease_status),
.release_valid(c_release_valid),
.release_ready(c_release_ready),
.release_tag(c_release_tag),
.release_ack(c_release_ack),
.release_ack_ready(c_release_ack_ready),
.result_valid(c_result_valid),
.result_ready(c_result_ready),
.result_tag(c_result_tag),
.result_index(c_result_index),
.result_data(c_result_data),
.result_last(c_result_last),
.job_start(c_job_start),
.job_done(c_job_done),
.job_success(c_job_success),
.job_frame(c_job_frame),
.job_tag(c_job_tag),
.phase(c_phase),
.boot_phase(c_boot_phase),
.engine_phase(c_engine_phase),
.boot_asset(c_boot_asset),
.model_ready(c_model_ready),
.last_error(c_last_error),
.completed_jobs(c_completed_jobs),
.spi_cs_n(spi_cs_n),
.spi_clk(spi_clk),
.spi_mosi(spi_mosi),
.spi_miso(spi_miso));
qy_native_ddr_cdc memory_cdc(.s_clk(nn_clk),
.s_rst(nn_rst),
.m_clk(bus_clk),
.m_rst(bus_rst),
.s_rd_valid(c_rd_valid),
.s_rd_ready(c_rd_ready),
.s_rd_addr(c_rd_addr),
.s_rsp_valid(c_rsp_valid),
.s_rsp_ready(c_rsp_ready),
.s_rsp_data(c_rsp_data),
.s_rsp_error(c_rsp_error),
.s_wr_valid(c_wr_valid),
.s_wr_ready(c_wr_ready),
.s_wr_addr(c_wr_addr),
.s_wr_data(c_wr_data),
.s_wr_strb(c_wr_strb),
.s_ack_valid(c_ack_valid),
.s_ack_ready(c_ack_ready),
.s_ack_error(c_ack_error),
.m_rd_valid(m_rd_valid),
.m_rd_ready(m_rd_ready),
.m_rd_addr(m_rd_addr),
.m_rsp_valid(m_rsp_valid),
.m_rsp_ready(m_rsp_ready),
.m_rsp_data(m_rsp_data),
.m_rsp_error(m_rsp_error),
.m_wr_valid(m_wr_valid),
.m_wr_ready(m_wr_ready),
.m_wr_addr(m_wr_addr),
.m_wr_data(m_wr_data),
.m_wr_strb(m_wr_strb),
.m_ack_valid(m_ack_valid),
.m_ack_ready(m_ack_ready),
.m_ack_error(m_ack_error));
qy_tile_axi_master master(.clk(bus_clk),
.rst(bus_rst),
.rd_valid(m_rd_valid),
.rd_ready(m_rd_ready),
.rd_addr(m_rd_addr),
.rsp_valid(m_rsp_valid),
.rsp_ready(m_rsp_ready),
.rsp_data(m_rsp_data),
.rsp_error(m_rsp_error),
.wr_valid(m_wr_valid),
.wr_ready(m_wr_ready),
.wr_addr(m_wr_addr),
.wr_data(m_wr_data),
.wr_strobe(m_wr_strb),
.ack_valid(m_ack_valid),
.ack_ready(m_ack_ready),
.ack_error(m_ack_error),
.awaddr(n_awaddr),
.awid(n_awid),
.awlen(n_awlen),
.awsize(n_awsize),
.awburst(n_awburst),
.awvalid(n_awvalid),
.wdata(n_wdata),
.wstrb(n_wstrb),
.wlast(n_wlast),
.wvalid(n_wvalid),
.araddr(n_araddr),
.arid(n_arid),
.arlen(n_arlen),
.arsize(n_arsize),
.arburst(n_arburst),
.arvalid(n_arvalid),
.rready(n_rready),
.bready(n_bready),
.awready(n_awready),
.wready(n_wready),
.arready(n_arready),
.rdata(n_rdata),
.rid(n_rid),
.rresp(n_rresp),
.rlast(n_rlast),
.rvalid(n_rvalid),
.bid(n_bid),
.bresp(n_bresp),
.bvalid(n_bvalid));
assign n_awlock=0;
assign n_awcache=0;
assign n_awprot=0;
assign n_awqos=0;
assign n_arlock=0;
assign n_arcache=0;
assign n_arprot=0;
assign n_arqos=0;
qy_cdc_request_response #(.REQUEST_BITS(32),
.RESPONSE_BITS(200)) lease_cdc(
.s_clk(nn_clk),
.s_rst(nn_rst),
.s_valid(c_lease_req_valid),
.s_ready(c_lease_req_ready),
.s_data(c_lease_req_tag),
.s_response_valid(c_lease_valid),
.s_response_ready(c_lease_ready),
.s_response_data({c_cap_start,c_cap_end,c_cap_ready,c_lease_status,c_lease_tag,c_lease_frame,c_lease_base}),
.m_clk(bus_clk),
.m_rst(bus_rst),
.m_valid(lease_req_valid),
.m_ready(lease_req_ready),
.m_data(lease_req_tag),
.m_response_valid(lease_valid),
.m_response_ready(lease_ready),
.m_response_data({perf_capture_start,perf_capture_end,perf_capture_ready,lease_status,lease_tag,lease_frame,lease_base}));
wire release_ignored_ready,release_ignored_data;
qy_cdc_request_response #(.REQUEST_BITS(32),
.RESPONSE_BITS(1)) release_cdc(
.s_clk(nn_clk),
.s_rst(nn_rst),
.s_valid(c_release_valid),
.s_ready(c_release_ready),
.s_data(c_release_tag),
.s_response_valid(c_release_ack),
.s_response_ready(c_release_ack_ready),
.s_response_data(release_ignored_data),
.m_clk(bus_clk),
.m_rst(bus_rst),
.m_valid(release_valid),
.m_ready(release_ready),
.m_data(release_tag),
.m_response_valid(1'b1),
.m_response_ready(release_ignored_ready),
.m_response_data(1'b0));
wire update_valid,update_ready;wire [639:0] update_data;
wire legacy_update_valid,legacy_update_ready;wire [639:0] legacy_update_data;
wire trace_valid,trace_ready;wire [639:0] trace_data;
reg mux_valid;reg [639:0] mux_data;
assign update_valid=mux_valid;assign update_data=mux_data;
assign trace_ready=(!mux_valid||update_ready);
assign legacy_update_ready=(!mux_valid||update_ready)&&!trace_valid;
always @(posedge nn_clk) begin
 if(nn_rst) begin mux_valid<=0;mux_data<=0;end
 else if(!mux_valid||update_ready) begin
  mux_valid<=trace_valid||legacy_update_valid;
  mux_data<=trace_valid?trace_data:legacy_update_data;
 end
end
qy_perf_trace #(.ENABLE(ENABLE_PERF)) perf(
 .clk(nn_clk),.rst(nn_rst),.phase(c_phase),.engine_phase(c_engine_phase),.program_phase(perf_program_phase),.opcode(perf_opcode),.mode(perf_mode),
 .model_ready(c_model_ready),.lease_request(c_lease_req_valid&&c_lease_req_ready),.lease_response(c_lease_valid&&c_lease_ready),
 .capture_start_count(c_cap_start),.capture_end_count(c_cap_end),.capture_ready_count(c_cap_ready),
 .job_start(c_job_start),.job_done(c_job_done),.job_success(c_job_success),.display_ack(perf_display_ack),.job_tag(c_job_tag),.job_frame(c_job_frame),
 .last_error(c_last_error),.preview_ready(preview_begin_ready),
 .rd_valid(c_rd_valid),.rd_ready(c_rd_ready),.rsp_valid(c_rsp_valid),.rsp_ready(c_rsp_ready),
 .wr_valid(c_wr_valid),.wr_ready(c_wr_ready),.ack_valid(c_ack_valid),.ack_ready(c_ack_ready),
 .result_valid(c_result_valid),.result_ready(c_result_ready),.result_last(c_result_last),
 .trace_valid(trace_valid),.trace_ready(trace_ready),.trace_data(trace_data));
qy_yolo_telemetry telemetry(.clk(nn_clk),.suppress_heartbeat(perf_mode==2),
.rst(nn_rst),
.result_valid(c_result_valid&&(perf_mode==1||preview_result_ready)),
.result_ready(telemetry_result_ready),
.result_tag(c_result_tag),
.result_index(c_result_index),
.result_data(c_result_data),
.result_last(c_result_last),
.job_start(c_job_start),
.job_done(c_job_done),
.job_success(c_job_success),
.job_frame(c_job_frame),
.job_tag(c_job_tag),
.phase(c_phase),
.boot_phase(c_boot_phase),
.engine_phase(c_engine_phase),
.boot_asset(c_boot_asset),
.model_ready(c_model_ready),
.last_error(c_last_error!=0?c_last_error:(preview_error!=0?{8'he0,preview_error}:16'd0)),
.completed_jobs(c_completed_jobs),
.update_valid(legacy_update_valid),
.update_ready(legacy_update_ready),
.update_data(legacy_update_data));
generate if(ENABLE_PREVIEW) begin: image_results
    wire video_reset_n,sample_valid,sample_complete,sample_error;
    wire [15:0] sample_index,sample_rgb565;
    qy_reset_sync vr(.clk_i(video_clk),.arst_n_i(reset_n),.rst_n_o(video_reset_n));
    qy_nn_preview_sampler sampler(.clk(nn_clk),.rst(nn_rst),.begin_frame(c_job_start&&perf_mode!=1),
        .raw_valid(raw_preview_valid),.raw_x(raw_preview_x),.raw_y(raw_preview_y),.raw_rgb565(raw_preview_rgb565),
        .sample_valid(sample_valid),.sample_index(sample_index),.sample_rgb565(sample_rgb565),.complete(sample_complete),.error_o(sample_error));
    qy_nn_preview_store store(.clk(nn_clk),.rst(nn_rst),.video_clk(video_clk),.video_rst(!video_reset_n),
        .perf_display_ack(perf_display_ack),.begin_valid(c_job_start&&perf_mode!=1),.begin_ready(preview_begin_ready),.begin_tag(c_job_tag),.begin_frame(c_job_frame),
        .sample_valid(sample_valid),.sample_index(sample_index),.sample_rgb565(sample_rgb565),
        .box_valid(c_result_valid&&telemetry_result_ready&&perf_mode!=1),.box_ready(preview_result_ready),.box_tag(c_result_tag),
        .box_index(c_result_index),.box_data(c_result_data),.box_last(c_result_last),
        .finish_valid(c_job_done&&perf_mode!=1),.finish_success(c_job_success&&sample_complete&&!sample_error),.finish_tag(c_job_tag),.error_o(preview_error),
        .video_blank(video_blank),.read_address(preview_read_address),.read_rgb565(preview_rgb565),.read_mask(preview_mask),.read_valid(preview_valid),
        .display_tag(preview_tag),.display_frame(preview_frame));
end else begin: no_image_results
    assign perf_display_ack=1'b0;assign preview_begin_ready=1'b1;assign preview_result_ready=1'b1;
    assign preview_error=0;
    assign preview_rgb565=0;assign preview_mask=0;assign preview_valid=0;assign preview_tag=0;assign preview_frame=0;
end endgenerate
wire diag_ack,diag_returned,diag_ignored;
qy_cdc_request_response #(.REQUEST_BITS(640),
.RESPONSE_BITS(1)) diag_cdc(
.s_clk(nn_clk),
.s_rst(nn_rst),
.s_valid(update_valid),
.s_ready(update_ready),
.s_data(update_data),
.s_response_valid(diag_ack),
.s_response_ready(1'b1),
.s_response_data(diag_returned),
.m_clk(bus_clk),
.m_rst(bus_rst),
.m_valid(diag_valid),
.m_ready(diag_ready),
.m_data(diag_data),
.m_response_valid(1'b1),
.m_response_ready(diag_ignored),
.m_response_data(1'b0));
endmodule
`default_nettype wire
