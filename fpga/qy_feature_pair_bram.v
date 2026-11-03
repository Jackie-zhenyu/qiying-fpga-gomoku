`timescale 1ns/1ps
`default_nettype none
// Compatible request/response adapter. Loader owns the banks between jobs.
// RAM read registers have no reset/data mux, allowing synchronous ERAM inference.
module qy_feature_pair_bram #(
    parameter integer ACT_AW=16, parameter integer WEIGHT_AW=14
)(
    input wire clk,rst,
    input wire load_valid,output wire load_ready,
    input wire load_weight,input wire [31:0] load_addr,input wire [7:0] load_data,
    output reg load_error,
    input wire req_valid,output wire req_ready,
    input wire [31:0] req_activation_addr,req_weight_addr,input wire req_padding,
    output reg rsp_valid,input wire rsp_ready,
    output wire [7:0] rsp_activation,output wire signed [7:0] rsp_weight,
    output reg rsp_error
);
    localparam integer ACT_DEPTH=1<<ACT_AW, WEIGHT_DEPTH=1<<WEIGHT_AW;
    (* ram_style="bram" *) reg [7:0] activation_mem[0:ACT_DEPTH-1],weight_mem[0:WEIGHT_DEPTH-1];
    reg [7:0] activation_q,weight_q;reg padding_q;
    assign load_ready=!rst&&!rsp_valid;
    assign req_ready=!rst&&!load_valid&&(!rsp_valid||rsp_ready);
    wire load_fire=load_valid&&load_ready,read_fire=req_valid&&req_ready;
    wire bad_read=(req_weight_addr>=WEIGHT_DEPTH)||(!req_padding&&(req_activation_addr>=ACT_DEPTH));
    assign rsp_activation=(rsp_error||padding_q)?8'd0:activation_q;
    assign rsp_weight=rsp_error?8'd0:weight_q;
    always @(posedge clk) begin
        if(load_fire&&!load_weight&&load_addr<ACT_DEPTH) activation_mem[load_addr[ACT_AW-1:0]]<=load_data;
        if(load_fire&&load_weight&&load_addr<WEIGHT_DEPTH) weight_mem[load_addr[WEIGHT_AW-1:0]]<=load_data;
        if(read_fire&&!bad_read&&!req_padding) activation_q<=activation_mem[req_activation_addr[ACT_AW-1:0]];
        if(read_fire&&!bad_read) weight_q<=weight_mem[req_weight_addr[WEIGHT_AW-1:0]];
    end
    always @(posedge clk) begin
        if(rst) begin rsp_valid<=0;rsp_error<=0;padding_q<=0;load_error<=0;end
        else begin
            load_error<=load_fire&&(load_weight?(load_addr>=WEIGHT_DEPTH):(load_addr>=ACT_DEPTH));
            if(rsp_valid&&rsp_ready) rsp_valid<=0;
            if(read_fire) begin rsp_valid<=1;rsp_error<=bad_read;padding_q<=req_padding;end
        end
    end
endmodule
`default_nettype wire
