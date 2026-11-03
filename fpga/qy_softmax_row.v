`timescale 1ns/1ps
`default_nettype none
// Bounded row Softmax for the frozen two-bank Q24 exponential tables.
// Row storage is reused for the summation and output passes; no feature-map
// exponential buffer is allocated. ROM and row RAM have synchronous reads.
// Input zero point cancels in (max-code). The output is unsigned affine U8.
// Shared reset flushes a job; cancel is a separate integration concern.
module qy_softmax_row #(
    parameter EXP_FILE="softmax_exp.hex"
)(
    input wire clk, input wire rst,
    input wire cmd_valid, output wire cmd_ready,
    input wire [31:0] cmd_tag, input wire [8:0] cmd_length,
    input wire cmd_bank, input wire [31:0] cmd_multiplier,
    input wire [5:0] cmd_shift, input wire [7:0] cmd_output_zero,
    input wire s_valid, output wire s_ready, input wire [7:0] s_data,
    output wire m_valid, input wire m_ready,
    output reg [31:0] m_tag, output reg [8:0] m_index,
    output reg [7:0] m_data, output reg m_last, output reg [2:0] m_error
);
    localparam [4:0] IDLE=0, LOAD=1, READ=2, DIFF=3, TABLE=4, USE=5,
        DEN=6, DIV_INIT=7, DIVIDE=8, ROUND=9, SAT=10, OUTPUT=11;
    reg [4:0] state;
    reg [7:0] row_mem[0:511];
    reg [24:0] exp_rom[0:511];
    initial $readmemh(EXP_FILE,exp_rom);
    reg [7:0] row_q,maximum,delta,output_zero;
    reg [24:0] exp_q;
    reg [8:0] length,index;
    reg bank,emit_pass;
    reg [31:0] tag,multiplier;
    reg [5:0] shift;
    reg [32:0] sum_exp;
    reg [63:0] denominator;
    reg [55:0] numerator;
    reg [71:0] remainder,shifted_den;
    reg [7:0] quotient;
    reg [2:0] digit;
    reg [8:0] rounded;
    wire [2:0] command_error={1'b0,
        (cmd_multiplier==0 || cmd_multiplier[31] || cmd_shift>31),
        (cmd_length==0 || cmd_length>400)};
    wire [72:0] twice_remainder={remainder,1'b0};
    wire increment=(twice_remainder>{9'd0,denominator}) ||
        ((twice_remainder=={9'd0,denominator}) && quotient[0]);
    wire [9:0] with_zero={1'b0,rounded}+{2'd0,output_zero};
    assign cmd_ready=!rst && state==IDLE;
    assign s_ready=!rst && state==LOAD;
    assign m_valid=!rst && state==OUTPUT;
    always @(posedge clk) begin
        if(s_valid && s_ready) row_mem[index]<=s_data;
        if(state==READ) row_q<=row_mem[index];
        if(state==TABLE) exp_q<=exp_rom[{bank,delta}];
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;length<=0;index<=0;maximum<=0;sum_exp<=0;emit_pass<=0;
            tag<=0;bank<=0;multiplier<=0;shift<=0;output_zero<=0;
            m_tag<=0;m_index<=0;m_data<=0;m_last<=0;m_error<=0;
        end else case(state)
            IDLE: if(cmd_valid) begin
                if(command_error!=0) begin
                    m_tag<=cmd_tag;m_index<=0;m_data<=0;m_last<=1;m_error<=command_error;state<=OUTPUT;
                end else begin
                    tag<=cmd_tag;length<=cmd_length;bank<=cmd_bank;multiplier<=cmd_multiplier;
                    shift<=cmd_shift;output_zero<=cmd_output_zero;index<=0;maximum<=0;
                    sum_exp<=0;emit_pass<=0;state<=LOAD;
                end
            end
            LOAD: if(s_valid) begin
                if(s_data>maximum) maximum<=s_data;
                if(index==length-1) begin index<=0;state<=READ;end
                else index<=index+1'b1;
            end
            READ: state<=DIFF;
            DIFF: begin delta<=maximum-row_q;state<=TABLE;end
            TABLE: state<=USE;
            USE: if(!emit_pass) begin
                sum_exp<=sum_exp+{8'd0,exp_q};
                if(index==length-1) begin index<=0;emit_pass<=1;state<=DEN;end
                else begin index<=index+1'b1;state<=READ;end
            end else begin
                numerator<=exp_q*multiplier;state<=DIV_INIT;
            end
            DEN: begin
                denominator<={31'd0,sum_exp}<<shift;
                if(sum_exp==0) begin
                    m_tag<=tag;m_index<=0;m_data<=0;m_last<=1;m_error<=4;state<=OUTPUT;
                end else state<=READ;
            end
            DIV_INIT: begin
                remainder<={16'd0,numerator};shifted_den<={8'd0,denominator}<<7;
                quotient<=0;digit<=7;
                if({16'd0,numerator}>=({8'd0,denominator}<<8)) begin
                    rounded<=255;state<=SAT;
                end else state<=DIVIDE;
            end
            DIVIDE: begin
                if(remainder>=shifted_den) begin remainder<=remainder-shifted_den;quotient[digit]<=1;end
                shifted_den<=shifted_den>>1;
                if(digit==0) state<=ROUND;else digit<=digit-1'b1;
            end
            ROUND: begin rounded<={1'b0,quotient}+{8'd0,increment};state<=SAT;end
            SAT: begin
                m_tag<=tag;m_index<=index;m_data<=(with_zero>255)?8'd255:with_zero[7:0];
                m_last<=(index==length-1);m_error<=0;state<=OUTPUT;
            end
            OUTPUT: if(m_ready) begin
                if(m_last) state<=IDLE;
                else begin index<=index+1'b1;state<=READ;end
            end
            default:state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
