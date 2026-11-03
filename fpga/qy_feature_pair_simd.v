`timescale 1ns/1ps
`default_nettype none
// SIMD_MEMORY_DUAL_READ: eight copies, two read ports per weight copy.
// Port A is shared by exclusive loading/inference. Its read during a load is
// unobservable: no response is published until an accepted inference read.
module qy_feature_pair_simd #(
    parameter integer ACT_AW=16,parameter integer WEIGHT_AW=14
)(
    input wire clk,rst,
    input wire [479:0] req_extra_addr,input wire [14:0] req_extra_mask,output wire [119:0] rsp_extra_weight,
    input wire load_valid,output wire load_ready,
    input wire load_weight,input wire [31:0] load_addr,input wire [7:0] load_data,output reg load_error,
    input wire req_valid,output wire req_ready,
    input wire [31:0] req_activation_addr,req_weight_addr,input wire req_padding,
    output reg rsp_valid,input wire rsp_ready,
    output wire [7:0] rsp_activation,output wire signed [7:0] rsp_weight,output reg rsp_error
);
    localparam ACT_DEPTH=1<<ACT_AW,WEIGHT_DEPTH=1<<WEIGHT_AW;
    (* ram_style="bram" *) reg [7:0] activation_mem[0:ACT_DEPTH-1];
    reg [7:0] activation_q;reg padding_q;reg [14:0] enabled;
    assign load_ready=!rst&&!rsp_valid;
    assign req_ready=!rst&&!load_valid&&(!rsp_valid||rsp_ready);
    wire load_fire=load_valid&&load_ready,read_fire=req_valid&&req_ready;
    wire load_w=load_fire&&load_weight&&load_addr<WEIGHT_DEPTH;
    wire [14:0] extra_bad;
    wire bad_read=req_weight_addr>=WEIGHT_DEPTH||(!req_padding&&req_activation_addr>=ACT_DEPTH)||(|extra_bad);
    wire [127:0] raw_weights;
    assign rsp_activation=(rsp_error||padding_q)?8'd0:activation_q;
    assign rsp_weight=rsp_error?8'd0:raw_weights[7:0];
    genvar g;
    generate for(g=0;g<15;g=g+1) begin: output_lanes
        assign extra_bad[g]=req_extra_mask[g]&&(req_extra_addr[g*32+:32]>=WEIGHT_DEPTH);
        assign rsp_extra_weight[g*8+:8]=(rsp_error||!enabled[g])?8'd0:raw_weights[(g+1)*8+:8];
    end
    for(g=0;g<8;g=g+1) begin: copies
        (* ram_style="bram" *) reg [7:0] weights[0:WEIGHT_DEPTH-1];
        reg [7:0] qa,qb;
        wire [31:0] read_a;wire ena;
        if(g==0) begin
            assign read_a=req_weight_addr;assign ena=1'b1;
        end else begin
            assign read_a=req_extra_addr[(g-1)*32+:32];assign ena=req_extra_mask[g-1];
        end
        wire [31:0] read_b=req_extra_addr[(g+7)*32+:32];
        wire [WEIGHT_AW-1:0] addr_a=load_w?load_addr[WEIGHT_AW-1:0]:read_a[WEIGHT_AW-1:0];
        wire en_a=load_w||(read_fire&&!bad_read&&ena);
        always @(posedge clk) begin
            if(en_a) begin
                if(load_w) weights[addr_a]<=load_data;
                qa<=weights[addr_a];
            end
        end
        always @(posedge clk) if(read_fire&&!bad_read&&req_extra_mask[g+7]) qb<=weights[read_b[WEIGHT_AW-1:0]];
        assign raw_weights[g*8+:8]=qa;
        assign raw_weights[(g+8)*8+:8]=qb;
    end endgenerate
    always @(posedge clk) begin
        if(load_fire&&!load_weight&&load_addr<ACT_DEPTH) activation_mem[load_addr[ACT_AW-1:0]]<=load_data;
        if(read_fire&&!bad_read&&!req_padding) activation_q<=activation_mem[req_activation_addr[ACT_AW-1:0]];
    end
    always @(posedge clk) begin
        if(rst) begin rsp_valid<=0;rsp_error<=0;padding_q<=0;enabled<=0;load_error<=0;end
        else begin
            load_error<=load_fire&&(load_weight?(load_addr>=WEIGHT_DEPTH):(load_addr>=ACT_DEPTH));
            if(rsp_valid&&rsp_ready) rsp_valid<=0;
            if(read_fire) begin rsp_valid<=1;rsp_error<=bad_read;padding_q<=req_padding;enabled<=req_extra_mask;end
        end
    end
endmodule
`default_nettype wire
