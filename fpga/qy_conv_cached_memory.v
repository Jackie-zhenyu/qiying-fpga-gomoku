`timescale 1ns/1ps
`default_nettype none
// One NCHW/OIHW window descriptor, one outstanding paired read, one response
// buffer, and the unchanged stage13 arithmetic engine. Normal or depthwise only.
// Memory responder must share reset and discard pending responses on reset.
module qy_conv_cached_memory #(
    parameter LUT_FILE="silu_banks.hex"
) (
    input wire clk,rst,input wire cmd_valid,output wire cmd_ready,
    input wire [31:0] cmd_tag,cmd_activation_base,cmd_weight_base,
    input wire [9:0] cmd_width,cmd_height,cmd_ox,cmd_oy,
    input wire [9:0] cmd_ci,input wire [8:0] cmd_co,cmd_oc,
    input wire [1:0] cmd_kernel,cmd_stride,input wire cmd_pad,cmd_depthwise,
    input wire signed [31:0] cmd_bias,input wire [7:0] cmd_input_zero,
    input wire [31:0] cmd_multiplier,input wire [5:0] cmd_shift,
    input wire [7:0] cmd_output_zero,input wire [6:0] cmd_lut_bank,input wire cmd_use_lut,
    output wire req_valid,input wire req_ready,
    output wire [31:0] req_activation_addr,req_weight_addr,output wire req_padding,
    input wire rsp_valid,output wire rsp_ready,
    input wire [7:0] rsp_activation,input wire signed [7:0] rsp_weight,input wire rsp_error,
    output wire m_valid,input wire m_ready,output wire [31:0] m_tag,
    output wire signed [39:0] m_sum,output wire [7:0] m_pre,m_activation,output wire [6:0] m_error
);
    localparam [3:0] IDLE=0,START=1,REQUEST=2,WAIT_READ=3,FEED=4,RESULT=5,ERROR_OUT=6,VALIDATE=7,
        PREP_PLANE=8,PREP_OFFSETS=9,PREP_BASE=10,PREP_ROW=11,PREP_START=12;
    reg [3:0] state;reg [6:0] error_code;
    reg [137:0] descriptor;
    reg [31:0] activation_base,weight_base;
    reg [9:0] width,height,ox,oy;
    reg [9:0] input_count,channel;reg [8:0] oc;
    reg [1:0] kernel,stride,kx,ky;reg pad,depthwise,pending_padding;
    reg [7:0] buffered_activation;reg signed [7:0] buffered_weight;
    wire [31:0] command_inputs=cmd_depthwise?32'd1:{22'd0,cmd_ci};
    // kernel is only two bits; preserve 0/2 invalid-command error arithmetic
    // without cascading two dynamic multipliers before the extent check.
    wire [31:0] command_terms=(cmd_kernel==3)?((command_inputs<<3)+command_inputs):
        (cmd_kernel==2)?(command_inputs<<2):(cmd_kernel==1)?command_inputs:32'd0;
    wire [63:0] activation_end={32'd0,cmd_activation_base}+({54'd0,cmd_width}*cmd_height*cmd_ci);
    wire [63:0] weight_end={32'd0,cmd_weight_base}+({55'd0,cmd_co}*command_terms);
    wire bad_shape=(cmd_width==0||cmd_width>640||cmd_height==0||cmd_height>640||cmd_ci==0||cmd_ci>512||cmd_co==0||cmd_co>256||
        (cmd_kernel!=1&&cmd_kernel!=3)||(cmd_stride!=1&&cmd_stride!=2)||(cmd_depthwise&&cmd_ci!=cmd_co));
    wire bad_position=cmd_oc>=cmd_co||({22'd0,cmd_ox}*cmd_stride+cmd_kernel>{22'd0,cmd_width}+{31'd0,cmd_pad}*2)||
        ({22'd0,cmd_oy}*cmd_stride+cmd_kernel>{22'd0,cmd_height}+{31'd0,cmd_pad}*2);
    wire [6:0] command_error={1'b0,(activation_end>64'h100000000||weight_end>64'h100000000),bad_position,bad_shape,
        (cmd_use_lut&&1'b0),(cmd_multiplier==0||cmd_multiplier[31]||cmd_shift==63),(command_terms==0||command_terms>2304)};

    // Coordinate counters and addresses advance together. Compute the first
    // address once per window, then only add 1, width, or plane at boundaries.
    // Signed origins may be -1 for padding; no padded address reaches RAM.
    reg signed [12:0] origin_x,origin_y,ix,iy;
    reg [19:0] plane;
    reg [31:0] channel_offset,weight_offset,address_base,row_base;
    reg signed [22:0] row_offset;
    reg [31:0] activation_cursor,weight_cursor,row_start,channel_start;
    wire signed [12:0] sx=(stride==2)?$signed({2'd0,ox,1'b0}):$signed({3'd0,ox});
    wire signed [12:0] sy=(stride==2)?$signed({2'd0,oy,1'b0}):$signed({3'd0,oy});
    assign req_padding=(iy<0||ix<0||iy>=$signed({3'd0,height})||ix>=$signed({3'd0,width}));
    assign req_activation_addr=req_padding?32'd0:activation_cursor;
    assign req_weight_addr=weight_cursor;
    assign cmd_ready=!rst&&(state==IDLE);assign req_valid=!rst&&(state==REQUEST);
    assign rsp_ready=!rst&&(state==WAIT_READ);
    wire core_cmd_ready,core_s_ready,core_valid;wire [31:0] core_tag;
    wire signed [39:0] core_sum;wire [7:0] core_pre,core_activation;wire [2:0] core_error;
    wire core_reset=rst||(state==ERROR_OUT);
    qy_conv_long_window #(.LUT_FILE(LUT_FILE)) core(
        .clk(clk),.rst(core_reset),.cmd_valid(!rst&&state==START),.cmd_ready(core_cmd_ready),
        .cmd_tag(descriptor[137:106]),.cmd_terms(descriptor[105:94]),.cmd_bias(descriptor[93:62]),
        .cmd_input_zero(descriptor[61:54]),.cmd_multiplier(descriptor[53:22]),.cmd_shift(descriptor[21:16]),
        .cmd_output_zero(descriptor[15:8]),.cmd_lut_bank(descriptor[7:1]),.cmd_use_lut(descriptor[0]),
        .s_valid(!rst&&state==FEED),.s_ready(core_s_ready),.s_activation(buffered_activation),.s_weight(buffered_weight),
        .m_valid(core_valid),.m_ready(!rst&&state==RESULT&&m_ready),.m_tag(core_tag),.m_sum(core_sum),
        .m_pre(core_pre),.m_activation(core_activation),.m_error(core_error));
    assign m_valid=!rst&&((state==ERROR_OUT)||(state==RESULT&&core_valid));
    assign m_tag=(state==ERROR_OUT)?descriptor[137:106]:core_tag;
    assign m_sum=(state==ERROR_OUT)?40'sd0:core_sum;
    assign m_pre=(state==ERROR_OUT)?8'd0:core_pre;
    assign m_activation=(state==ERROR_OUT)?8'd0:core_activation;
    assign m_error=(state==ERROR_OUT)?error_code:{4'd0,core_error};
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;error_code<=0;descriptor<=0;activation_base<=0;weight_base<=0;
            width<=0;height<=0;ox<=0;oy<=0;input_count<=0;oc<=0;channel<=0;
            kernel<=0;stride<=0;kx<=0;ky<=0;pad<=0;depthwise<=0;pending_padding<=0;
            buffered_activation<=0;buffered_weight<=0;
            origin_x<=0;origin_y<=0;ix<=0;iy<=0;plane<=0;channel_offset<=0;weight_offset<=0;
            address_base<=0;row_base<=0;row_offset<=0;activation_cursor<=0;weight_cursor<=0;row_start<=0;channel_start<=0;
        end else case(state)
            IDLE: if(cmd_valid&&cmd_ready) begin
                descriptor<={cmd_tag,command_terms[11:0],cmd_bias,cmd_input_zero,cmd_multiplier,cmd_shift,cmd_output_zero,cmd_lut_bank,cmd_use_lut};
                error_code<=command_error;
                // Capture first; the registered error chooses the next state.
                // This removes the wide bounds calculation from every FF enable.
                activation_base<=cmd_activation_base;weight_base<=cmd_weight_base;
                width<=cmd_width;height<=cmd_height;ox<=cmd_ox;oy<=cmd_oy;oc<=cmd_oc;
                input_count<=command_inputs[9:0];kernel<=cmd_kernel;stride<=cmd_stride;
                pad<=cmd_pad;depthwise<=cmd_depthwise;channel<=0;kx<=0;ky<=0;state<=VALIDATE;
            end
            VALIDATE: state<=(error_code!=0)?ERROR_OUT:PREP_PLANE;
            PREP_PLANE: begin
                plane<=width*height;origin_x<=sx-$signed({12'd0,pad});origin_y<=sy-$signed({12'd0,pad});state<=PREP_OFFSETS;
            end
            PREP_OFFSETS: begin
                channel_offset<=depthwise?oc*plane:32'd0;
                row_offset<=origin_y*$signed({1'b0,width});weight_offset<=oc*descriptor[105:94];state<=PREP_BASE;
            end
            PREP_BASE: begin address_base<=activation_base+channel_offset;weight_cursor<=weight_base+weight_offset;state<=PREP_ROW;end
            PREP_ROW: begin row_base<=address_base+{{9{row_offset[22]}},row_offset};state<=PREP_START;end
            PREP_START: begin
                activation_cursor<=row_base+{{19{origin_x[12]}},origin_x};
                row_start<=row_base+{{19{origin_x[12]}},origin_x};channel_start<=row_base+{{19{origin_x[12]}},origin_x};
                ix<=origin_x;iy<=origin_y;state<=START;
            end
            START: if(core_cmd_ready) state<=REQUEST;
            REQUEST: if(req_valid&&req_ready) begin pending_padding<=req_padding;state<=WAIT_READ;end
            WAIT_READ: if(rsp_valid&&rsp_ready) begin
                if(rsp_error) begin error_code<=7'h40;state<=ERROR_OUT;end
                else begin buffered_activation<=pending_padding?descriptor[61:54]:rsp_activation;buffered_weight<=rsp_weight;state<=FEED;end
            end
            FEED: if(core_s_ready) begin
                if(kx==kernel-1&&ky==kernel-1&&channel==input_count-1) state<=RESULT;
                else begin
                    weight_cursor<=weight_cursor+32'd1;
                    if(kx==kernel-1) begin
                        kx<=0;ix<=origin_x;
                        if(ky==kernel-1) begin
                            ky<=0;channel<=channel+10'd1;iy<=origin_y;
                            channel_start<=channel_start+plane;row_start<=channel_start+plane;activation_cursor<=channel_start+plane;
                        end else begin
                            ky<=ky+2'd1;iy<=iy+13'sd1;row_start<=row_start+width;activation_cursor<=row_start+width;
                        end
                    end else begin kx<=kx+2'd1;ix<=ix+13'sd1;activation_cursor<=activation_cursor+32'd1;end
                    state<=REQUEST;
                end
            end
            RESULT: if(core_valid&&m_ready) state<=IDLE;
            ERROR_OUT: if(m_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
`default_nettype wire
