`timescale 1ns/1ps
`default_nettype none
// Five sequential operators share one A/W/output cache set. Selection is held
// by the parent executor until completion; inactive cores cannot consume any
// response or acknowledgement. This wrapper allocates no feature RAM.
module qy_nn_compute_simd_post #(parameter LUT_FILE="silu_banks.hex",parameter EXP_FILE="softmax_exp.hex",parameter ENABLE_CONV_LUT=1) (
    input wire clk,rst,cancel,
    output wire [479:0] req_extra_addr,output wire [14:0] req_extra_mask,input wire [119:0] rsp_extra_weight,input wire [3:0] op,input wire [219:0] payload,
    output wire memory_reset,
    input wire cfg_valid,output wire cfg_ready,output wire cfg_error,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] mat_multiplier,input wire [5:0] mat_shift,
    input wire [7:0] mat_az,mat_bz,mat_oz,
    input wire [31:0] soft_multiplier,input wire [5:0] soft_shift,
    input wire [7:0] soft_oz,input wire soft_bank,
    output wire req_valid,input wire req_ready,output wire [31:0] req_a,req_w,output wire req_padding,
    input wire rsp_valid,output wire rsp_ready,input wire [7:0] rsp_a,rsp_w,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,output wire [7:0] wr_data,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire done_valid,input wire done_ready,output wire [31:0] done_tag,done_written,output wire [11:0] done_error
);
    wire [31:0] abase,wbase,obase;wire [9:0] width,height,ci;wire [8:0] co;
    wire [1:0] kernel,stride;wire pad,dw,use_lut;wire [7:0] iz,oz;wire [6:0] bank;
    assign {abase,wbase,obase,width,height,ci,co,kernel,stride,pad,dw,iz,oz,bank,use_lut}=payload[164:0];
    wire [31:0] mm_a_descriptor,mm_b_descriptor,mm_as,mm_bs;wire [8:0] mm_rows,mm_cols;wire [11:0] mm_terms;
    assign {mm_a_descriptor,mm_b_descriptor,mm_as,mm_bs,mm_rows,mm_cols,mm_terms}=payload[157:0];
    wire [31:0] lk_table,lk_a_descriptor,lk_b_descriptor;wire [16:0] lk_count_descriptor;wire lk_binary,lk_repeat;
    assign {lk_table,lk_a_descriptor,lk_b_descriptor,lk_count_descriptor,lk_binary,lk_repeat}=payload[114:0];
    wire [31:0] sm_a_descriptor;wire [8:0] sm_length;assign {sm_a_descriptor,sm_length}=payload[40:0];
    wire [31:0] mp_a_descriptor;wire [9:0] mp_width,mp_height;wire [8:0] mp_channels;
    assign {mp_a_descriptor,mp_width,mp_height,mp_channels}=payload[60:0];

wire cv_sel=op==4'd4;
wire cv_reset,cv_ready,cv_req,cv_rsp_ready,cv_wr,cv_ack_ready,cv_done;
wire [31:0] cv_a,cv_b,cv_addr,cv_tag,cv_count;wire [7:0] cv_data;wire [11:0] cv_error;
wire cv_padding;
qy_conv_simd_post_dispatch #(.LUT_FILE(LUT_FILE)) cv_core(
        .req_extra_addr(req_extra_addr),.req_extra_mask(req_extra_mask),.rsp_extra_weight(rsp_extra_weight),
        .clk(clk),.rst(rst),.cancel(cancel&&cv_sel),.memory_reset(cv_reset),
        .cmd_valid(cmd_valid&&cv_sel),.cmd_ready(cv_ready),.cmd_tag(cmd_tag),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_channel(payload[78:70]),.cfg_bias(payload[69:38]),.cfg_multiplier(payload[37:6]),.cfg_shift(payload[5:0]),.cfg_error(cfg_error),
.cmd_activation_base(abase),.cmd_weight_base(wbase),.cmd_output_base(obase),.cmd_width(width),.cmd_height(height),.cmd_ci(ci),.cmd_co(co),.cmd_kernel(kernel),.cmd_stride(stride),.cmd_pad(pad),.cmd_depthwise(dw),.cmd_input_zero(iz),.cmd_output_zero(oz),.cmd_lut_bank(bank),.cmd_use_lut(ENABLE_CONV_LUT&&use_lut),
        .req_valid(cv_req),.req_ready(req_ready&&cv_sel),.req_activation_addr(cv_a),.req_weight_addr(cv_b),.req_padding(cv_padding),
        .rsp_valid(rsp_valid&&cv_sel),.rsp_ready(cv_rsp_ready),.rsp_activation(rsp_a),.rsp_weight(rsp_w),.rsp_error(rsp_error),
        .wr_valid(cv_wr),.wr_ready(wr_ready&&cv_sel),.wr_addr(cv_addr),.wr_data(cv_data),
        .ack_valid(ack_valid&&cv_sel),.ack_ready(cv_ack_ready),.ack_error(ack_error),
        .done_valid(cv_done),.done_ready(done_ready&&cv_sel),.done_tag(cv_tag),.done_written(cv_count),.done_error(cv_error));
wire mm_sel=op==4'd8;
wire mm_reset,mm_ready,mm_req,mm_rsp_ready,mm_wr,mm_ack_ready,mm_done;
wire [31:0] mm_a,mm_b,mm_addr,mm_tag,mm_count;wire [7:0] mm_data;wire [7:0] mm_error;

qy_matmul_tile mm_core(
        .clk(clk),.rst(rst),.cancel(cancel&&mm_sel),.memory_reset(mm_reset),
        .cmd_valid(cmd_valid&&mm_sel),.cmd_ready(mm_ready),.cmd_tag(cmd_tag),.cmd_a_base(mm_a_descriptor),.cmd_b_base(mm_b_descriptor),.cmd_a_stride(mm_as),.cmd_b_stride(mm_bs),.cmd_rows(mm_rows),.cmd_cols(mm_cols),.cmd_terms(mm_terms),.cmd_a_zero(mat_az),.cmd_b_zero(mat_bz),.cmd_output_zero(mat_oz),.cmd_multiplier(mat_multiplier),.cmd_shift(mat_shift),
        .req_valid(mm_req),.req_ready(req_ready&&mm_sel),.req_a(mm_a),.req_b(mm_b),
        .rsp_valid(rsp_valid&&mm_sel),.rsp_ready(mm_rsp_ready),.rsp_a(rsp_a),.rsp_b(rsp_w),.rsp_error(rsp_error),
        .wr_valid(mm_wr),.wr_ready(wr_ready&&mm_sel),.wr_addr(mm_addr),.wr_data(mm_data),
        .ack_valid(ack_valid&&mm_sel),.ack_ready(mm_ack_ready),.ack_error(ack_error),
        .done_valid(mm_done),.done_ready(done_ready&&mm_sel),.done_tag(mm_tag),.done_written(mm_count),.done_error(mm_error));
wire lk_sel=op==4'd9;
wire lk_reset,lk_ready,lk_req,lk_rsp_ready,lk_wr,lk_ack_ready,lk_done;
wire [31:0] lk_a,lk_b,lk_addr,lk_tag,lk_count;wire [7:0] lk_data;wire [7:0] lk_error;

qy_lookup_tile lk_core(
        .clk(clk),.rst(rst),.cancel(cancel&&lk_sel),.memory_reset(lk_reset),
        .cmd_valid(cmd_valid&&lk_sel),.cmd_ready(lk_ready),.cmd_tag(cmd_tag),.cmd_table_base(lk_table),.cmd_a_base(lk_a_descriptor),.cmd_b_base(lk_b_descriptor),.cmd_count(lk_count_descriptor),.cmd_binary(lk_binary),.cmd_repeat2(lk_repeat),
        .req_valid(lk_req),.req_ready(req_ready&&lk_sel),.req_a(lk_a),.req_b(lk_b),
        .rsp_valid(rsp_valid&&lk_sel),.rsp_ready(lk_rsp_ready),.rsp_a(rsp_a),.rsp_b(rsp_w),.rsp_error(rsp_error),
        .wr_valid(lk_wr),.wr_ready(wr_ready&&lk_sel),.wr_addr(lk_addr),.wr_data(lk_data),
        .ack_valid(ack_valid&&lk_sel),.ack_ready(lk_ack_ready),.ack_error(ack_error),
        .done_valid(lk_done),.done_ready(done_ready&&lk_sel),.done_tag(lk_tag),.done_written(lk_count),.done_error(lk_error));
wire sm_sel=op==4'd11;
wire sm_reset,sm_ready,sm_req,sm_rsp_ready,sm_wr,sm_ack_ready,sm_done;
wire [31:0] sm_a,sm_b,sm_addr,sm_tag,sm_count;wire [7:0] sm_data;wire [7:0] sm_error;

qy_softmax_tile #(.EXP_FILE(EXP_FILE)) sm_core(
        .clk(clk),.rst(rst),.cancel(cancel&&sm_sel),.memory_reset(sm_reset),
        .cmd_valid(cmd_valid&&sm_sel),.cmd_ready(sm_ready),.cmd_tag(cmd_tag),.cmd_a_base(sm_a_descriptor),.cmd_length(sm_length),.cmd_bank(soft_bank),.cmd_multiplier(soft_multiplier),.cmd_shift(soft_shift),.cmd_output_zero(soft_oz),
        .req_valid(sm_req),.req_ready(req_ready&&sm_sel),.req_a(sm_a),.req_b(sm_b),
        .rsp_valid(rsp_valid&&sm_sel),.rsp_ready(sm_rsp_ready),.rsp_a(rsp_a),.rsp_b(rsp_w),.rsp_error(rsp_error),
        .wr_valid(sm_wr),.wr_ready(wr_ready&&sm_sel),.wr_addr(sm_addr),.wr_data(sm_data),
        .ack_valid(ack_valid&&sm_sel),.ack_ready(sm_ack_ready),.ack_error(ack_error),
        .done_valid(sm_done),.done_ready(done_ready&&sm_sel),.done_tag(sm_tag),.done_written(sm_count),.done_error(sm_error));
wire mp_sel=op==4'd12;
wire mp_reset,mp_ready,mp_req,mp_rsp_ready,mp_wr,mp_ack_ready,mp_done;
wire [31:0] mp_a,mp_b,mp_addr,mp_tag,mp_count;wire [7:0] mp_data;wire [7:0] mp_error;

qy_maxpool_tile mp_core(
        .clk(clk),.rst(rst),.cancel(cancel&&mp_sel),.memory_reset(mp_reset),
        .cmd_valid(cmd_valid&&mp_sel),.cmd_ready(mp_ready),.cmd_tag(cmd_tag),.cmd_a_base(mp_a_descriptor),.cmd_width(mp_width),.cmd_height(mp_height),.cmd_channels(mp_channels),
        .req_valid(mp_req),.req_ready(req_ready&&mp_sel),.req_a(mp_a),.req_b(mp_b),
        .rsp_valid(rsp_valid&&mp_sel),.rsp_ready(mp_rsp_ready),.rsp_a(rsp_a),.rsp_b(rsp_w),.rsp_error(rsp_error),
        .wr_valid(mp_wr),.wr_ready(wr_ready&&mp_sel),.wr_addr(mp_addr),.wr_data(mp_data),
        .ack_valid(ack_valid&&mp_sel),.ack_ready(mp_ack_ready),.ack_error(ack_error),
        .done_valid(mp_done),.done_ready(done_ready&&mp_sel),.done_tag(mp_tag),.done_written(mp_count),.done_error(mp_error));
assign memory_reset=cv_reset|mm_reset|lk_reset|sm_reset|mp_reset;
assign cmd_ready=cv_sel?cv_ready: mm_sel?mm_ready: lk_sel?lk_ready: sm_sel?sm_ready: mp_sel?mp_ready:'d0;
assign req_valid=cv_sel?cv_req: mm_sel?mm_req: lk_sel?lk_req: sm_sel?sm_req: mp_sel?mp_req:'d0;
assign req_a=cv_sel?cv_a: mm_sel?mm_a: lk_sel?lk_a: sm_sel?sm_a: mp_sel?mp_a:'d0;
assign req_w=cv_sel?cv_b: mm_sel?mm_b: lk_sel?lk_b: sm_sel?sm_b: mp_sel?mp_b:'d0;
assign rsp_ready=cv_sel?cv_rsp_ready: mm_sel?mm_rsp_ready: lk_sel?lk_rsp_ready: sm_sel?sm_rsp_ready: mp_sel?mp_rsp_ready:'d0;
assign wr_valid=cv_sel?cv_wr: mm_sel?mm_wr: lk_sel?lk_wr: sm_sel?sm_wr: mp_sel?mp_wr:'d0;
assign wr_addr=cv_sel?(cv_addr-obase): mm_sel?mm_addr: lk_sel?lk_addr: sm_sel?sm_addr: mp_sel?mp_addr:'d0;
assign wr_data=cv_sel?cv_data: mm_sel?mm_data: lk_sel?lk_data: sm_sel?sm_data: mp_sel?mp_data:'d0;
assign ack_ready=cv_sel?cv_ack_ready: mm_sel?mm_ack_ready: lk_sel?lk_ack_ready: sm_sel?sm_ack_ready: mp_sel?mp_ack_ready:'d0;
assign done_valid=cv_sel?cv_done: mm_sel?mm_done: lk_sel?lk_done: sm_sel?sm_done: mp_sel?mp_done:'d0;
assign done_tag=cv_sel?cv_tag: mm_sel?mm_tag: lk_sel?lk_tag: sm_sel?sm_tag: mp_sel?mp_tag:'d0;
assign done_written=cv_sel?cv_count: mm_sel?mm_count: lk_sel?lk_count: sm_sel?sm_count: mp_sel?mp_count:'d0;
assign done_error=cv_sel?cv_error: mm_sel?{4'd0,mm_error}: lk_sel?{4'd0,lk_error}: sm_sel?{4'd0,sm_error}: mp_sel?{4'd0,mp_error}:'d0;
assign req_padding=cv_sel&&cv_padding;
endmodule
`default_nettype wire
