`timescale 1ns/1ps
`default_nettype none
// Independent single-outstanding native read/write channels. Paired global
// reset, local synchronous release, and bundled-data constraints required.
module qy_native_ddr_cdc (
    input wire s_clk,input wire s_rst,input wire m_clk,input wire m_rst,
    input wire s_rd_valid,output wire s_rd_ready,input wire [31:0] s_rd_addr,
    output wire s_rsp_valid,input wire s_rsp_ready,output wire [255:0] s_rsp_data,output wire s_rsp_error,
    input wire s_wr_valid,output wire s_wr_ready,input wire [31:0] s_wr_addr,
    input wire [255:0] s_wr_data,input wire [31:0] s_wr_strb,
    output wire s_ack_valid,input wire s_ack_ready,output wire s_ack_error,
    output wire m_rd_valid,input wire m_rd_ready,output wire [31:0] m_rd_addr,
    input wire m_rsp_valid,output wire m_rsp_ready,input wire [255:0] m_rsp_data,input wire m_rsp_error,
    output wire m_wr_valid,input wire m_wr_ready,output wire [31:0] m_wr_addr,
    output wire [255:0] m_wr_data,output wire [31:0] m_wr_strb,
    input wire m_ack_valid,output wire m_ack_ready,input wire m_ack_error
);
    qy_cdc_request_response #(.REQUEST_BITS(32),.RESPONSE_BITS(257)) read_channel(
        .s_clk(s_clk),.s_rst(s_rst),.s_valid(s_rd_valid),.s_ready(s_rd_ready),.s_data(s_rd_addr),
        .s_response_valid(s_rsp_valid),.s_response_ready(s_rsp_ready),.s_response_data({s_rsp_error,s_rsp_data}),
        .m_clk(m_clk),.m_rst(m_rst),.m_valid(m_rd_valid),.m_ready(m_rd_ready),.m_data(m_rd_addr),
        .m_response_valid(m_rsp_valid),.m_response_ready(m_rsp_ready),.m_response_data({m_rsp_error,m_rsp_data}));
    qy_cdc_request_response #(.REQUEST_BITS(320),.RESPONSE_BITS(1)) write_channel(
        .s_clk(s_clk),.s_rst(s_rst),.s_valid(s_wr_valid),.s_ready(s_wr_ready),.s_data({s_wr_addr,s_wr_data,s_wr_strb}),
        .s_response_valid(s_ack_valid),.s_response_ready(s_ack_ready),.s_response_data(s_ack_error),
        .m_clk(m_clk),.m_rst(m_rst),.m_valid(m_wr_valid),.m_ready(m_wr_ready),.m_data({m_wr_addr,m_wr_data,m_wr_strb}),
        .m_response_valid(m_ack_valid),.m_response_ready(m_ack_ready),.m_response_data(m_ack_error));
endmodule
`default_nettype wire
