`timescale 1ns/1ps
`default_nettype none
// Serial full-layer scheduler. Separate input/output address spaces required.
// cancel resets this engine's child and MUST flush both external RAM responders.
module qy_conv_simd_dispatch #(parameter LUT_FILE="silu_banks.hex")(
    input wire clk,rst,cancel,
    output wire [479:0] req_extra_addr,output wire [14:0] req_extra_mask,input wire [119:0] rsp_extra_weight,output wire memory_reset,
    input wire cfg_valid,output wire cfg_ready,input wire [8:0] cfg_channel,
    input wire signed [31:0] cfg_bias,input wire [31:0] cfg_multiplier,input wire [5:0] cfg_shift,output wire cfg_error,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,cmd_activation_base,cmd_weight_base,cmd_output_base,
    input wire [9:0] cmd_width,cmd_height,input wire [9:0] cmd_ci,input wire [8:0] cmd_co,
    input wire [1:0] cmd_kernel,cmd_stride,input wire cmd_pad,cmd_depthwise,
    input wire [7:0] cmd_input_zero,cmd_output_zero,input wire [6:0] cmd_lut_bank,input wire cmd_use_lut,
    output wire req_valid,input wire req_ready,output wire [31:0] req_activation_addr,req_weight_addr,output wire req_padding,
    input wire rsp_valid,output wire rsp_ready,input wire [7:0] rsp_activation,input wire signed [7:0] rsp_weight,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,output wire [7:0] wr_data,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire done_valid,input wire done_ready,output wire [31:0] done_tag,done_written,output wire [11:0] done_error
);

    reg use_depthwise;
    wire sel=cmd_valid?cmd_depthwise:use_depthwise;
    wire [14:0] new_extra_mask;assign req_extra_mask=sel?15'd0:new_extra_mask;
    always @(posedge clk) if(rst) use_depthwise<=0;else if(cmd_valid&&cmd_ready) use_depthwise<=cmd_depthwise;
    wire old_memory_reset,new_memory_reset;
    assign memory_reset=(old_memory_reset|new_memory_reset);
    wire old_cfg_ready,new_cfg_ready;
    assign cfg_ready=(old_cfg_ready&&new_cfg_ready);
    wire old_cfg_error,new_cfg_error;
    assign cfg_error=(old_cfg_error|new_cfg_error);
    wire old_cmd_ready,new_cmd_ready;
    assign cmd_ready=(sel?old_cmd_ready:new_cmd_ready);
    wire old_req_valid,new_req_valid;
    assign req_valid=(sel?old_req_valid:new_req_valid);
    wire [31:0] old_req_activation_addr,new_req_activation_addr;
    assign req_activation_addr=(sel?old_req_activation_addr:new_req_activation_addr);
    wire [31:0] old_req_weight_addr,new_req_weight_addr;
    assign req_weight_addr=(sel?old_req_weight_addr:new_req_weight_addr);
    wire old_req_padding,new_req_padding;
    assign req_padding=(sel?old_req_padding:new_req_padding);
    wire old_rsp_ready,new_rsp_ready;
    assign rsp_ready=(sel?old_rsp_ready:new_rsp_ready);
    wire old_wr_valid,new_wr_valid;
    assign wr_valid=(sel?old_wr_valid:new_wr_valid);
    wire [31:0] old_wr_addr,new_wr_addr;
    assign wr_addr=(sel?old_wr_addr:new_wr_addr);
    wire [7:0] old_wr_data,new_wr_data;
    assign wr_data=(sel?old_wr_data:new_wr_data);
    wire old_ack_ready,new_ack_ready;
    assign ack_ready=(sel?old_ack_ready:new_ack_ready);
    wire old_done_valid,new_done_valid;
    assign done_valid=(sel?old_done_valid:new_done_valid);
    wire [31:0] old_done_tag,new_done_tag;
    assign done_tag=(sel?old_done_tag:new_done_tag);
    wire [31:0] old_done_written,new_done_written;
    assign done_written=(sel?old_done_written:new_done_written);
    wire [11:0] old_done_error,new_done_error;
    assign done_error=(sel?old_done_error:new_done_error);
    qy_conv_cached_layer #(.LUT_FILE(LUT_FILE)) old_core(.clk(clk),
.rst(rst),
.cancel(cancel&&sel),
.memory_reset(old_memory_reset),
.cfg_valid(cfg_valid),
.cfg_ready(old_cfg_ready),
.cfg_channel(cfg_channel),
.cfg_bias(cfg_bias),
.cfg_multiplier(cfg_multiplier),
.cfg_shift(cfg_shift),
.cfg_error(old_cfg_error),
.cmd_valid(cmd_valid&&sel),
.cmd_ready(old_cmd_ready),
.cmd_tag(cmd_tag),
.cmd_activation_base(cmd_activation_base),
.cmd_weight_base(cmd_weight_base),
.cmd_output_base(cmd_output_base),
.cmd_width(cmd_width),
.cmd_height(cmd_height),
.cmd_ci(cmd_ci),
.cmd_co(cmd_co),
.cmd_kernel(cmd_kernel),
.cmd_stride(cmd_stride),
.cmd_pad(cmd_pad),
.cmd_depthwise(cmd_depthwise),
.cmd_input_zero(cmd_input_zero),
.cmd_output_zero(cmd_output_zero),
.cmd_lut_bank(cmd_lut_bank),
.cmd_use_lut(cmd_use_lut),
.req_valid(old_req_valid),
.req_ready(req_ready&&sel),
.req_activation_addr(old_req_activation_addr),
.req_weight_addr(old_req_weight_addr),
.req_padding(old_req_padding),
.rsp_valid(rsp_valid&&sel),
.rsp_ready(old_rsp_ready),
.rsp_activation(rsp_activation),
.rsp_weight(rsp_weight),
.rsp_error(rsp_error),
.wr_valid(old_wr_valid),
.wr_ready(wr_ready&&sel),
.wr_addr(old_wr_addr),
.wr_data(old_wr_data),
.ack_valid(ack_valid&&sel),
.ack_ready(old_ack_ready),
.ack_error(ack_error),
.done_valid(old_done_valid),
.done_ready(done_ready&&sel),
.done_tag(old_done_tag),
.done_written(old_done_written),
.done_error(old_done_error));
    qy_conv_simd_layer #(.LUT_FILE(LUT_FILE)) new_core(.clk(clk),
.rst(rst),
.cancel(cancel&&!sel),
.req_extra_addr(req_extra_addr),
.req_extra_mask(new_extra_mask),
.rsp_extra_weight(rsp_extra_weight),
.memory_reset(new_memory_reset),
.cfg_valid(cfg_valid),
.cfg_ready(new_cfg_ready),
.cfg_channel(cfg_channel),
.cfg_bias(cfg_bias),
.cfg_multiplier(cfg_multiplier),
.cfg_shift(cfg_shift),
.cfg_error(new_cfg_error),
.cmd_valid(cmd_valid&&!sel),
.cmd_ready(new_cmd_ready),
.cmd_tag(cmd_tag),
.cmd_activation_base(cmd_activation_base),
.cmd_weight_base(cmd_weight_base),
.cmd_output_base(cmd_output_base),
.cmd_width(cmd_width),
.cmd_height(cmd_height),
.cmd_ci(cmd_ci),
.cmd_co(cmd_co),
.cmd_kernel(cmd_kernel),
.cmd_stride(cmd_stride),
.cmd_pad(cmd_pad),
.cmd_depthwise(cmd_depthwise),
.cmd_input_zero(cmd_input_zero),
.cmd_output_zero(cmd_output_zero),
.cmd_lut_bank(cmd_lut_bank),
.cmd_use_lut(cmd_use_lut),
.req_valid(new_req_valid),
.req_ready(req_ready&&!sel),
.req_activation_addr(new_req_activation_addr),
.req_weight_addr(new_req_weight_addr),
.req_padding(new_req_padding),
.rsp_valid(rsp_valid&&!sel),
.rsp_ready(new_rsp_ready),
.rsp_activation(rsp_activation),
.rsp_weight(rsp_weight),
.rsp_error(rsp_error),
.wr_valid(new_wr_valid),
.wr_ready(wr_ready&&!sel),
.wr_addr(new_wr_addr),
.wr_data(new_wr_data),
.ack_valid(ack_valid&&!sel),
.ack_ready(new_ack_ready),
.ack_error(ack_error),
.done_valid(new_done_valid),
.done_ready(done_ready&&!sel),
.done_tag(new_done_tag),
.done_written(new_done_written),
.done_error(new_done_error));
endmodule
`default_nettype wire