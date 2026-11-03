`timescale 1ns/1ps
`default_nettype none
// Serial full-layer scheduler. Separate input/output address spaces required.
// cancel resets this engine's child and MUST flush both external RAM responders.
module qy_conv_cached_layer #(parameter LUT_FILE="silu_banks.hex")(
    input wire clk,rst,cancel,output wire memory_reset,
    input wire cfg_valid,output wire cfg_ready,input wire [8:0] cfg_channel,
    input wire signed [31:0] cfg_bias,input wire [31:0] cfg_multiplier,input wire [5:0] cfg_shift,output reg cfg_error,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,cmd_activation_base,cmd_weight_base,cmd_output_base,
    input wire [9:0] cmd_width,cmd_height,input wire [9:0] cmd_ci,input wire [8:0] cmd_co,
    input wire [1:0] cmd_kernel,cmd_stride,input wire cmd_pad,cmd_depthwise,
    input wire [7:0] cmd_input_zero,cmd_output_zero,input wire [6:0] cmd_lut_bank,input wire cmd_use_lut,
    output wire req_valid,input wire req_ready,output wire [31:0] req_activation_addr,req_weight_addr,output wire req_padding,
    input wire rsp_valid,output wire rsp_ready,input wire [7:0] rsp_activation,input wire signed [7:0] rsp_weight,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,output wire [7:0] wr_data,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,done_written,output reg [11:0] done_error
);
    localparam [3:0] IDLE=0,PARAM=1,ISSUE=2,COMPUTE=3,WRITE=4,WAIT_ACK=5,DONE=6,SHAPE=7,SIZE=8,EXTENT=9,BOUNDS=10;
    reg [3:0] state;
    reg [31:0] a_plane,o_plane,w_count,a_count,o_count;
    reg [12:0] latched_terms;
    reg [69:0] params[0:255];reg [255:0] params_valid;
    reg [69:0] channel_params;
    reg [31:0] abase,wbase,obase,total,index;
    reg [9:0] width,height,ow,oh,ox,oy;reg [9:0] ci;reg [8:0] co,oc;
    reg [1:0] kernel,stride;reg pad,depthwise,use_lut;
    reg [7:0] iz,oz,result_byte;reg [6:0] bank;
    // Validate and calculate extents after latching the command, one
    // multiplication per registered stage. Valid shape bounds keep counts u32.
    wire [31:0] padded_w={22'd0,width}+{31'd0,pad}*2;
    wire [31:0] padded_h={22'd0,height}+{31'd0,pad}*2;
    wire [31:0] command_ow=(padded_w>=kernel)?((padded_w-kernel)>>(stride==2?1:0))+1:0;
    wire [31:0] command_oh=(padded_h>=kernel)?((padded_h-kernel)>>(stride==2?1:0))+1:0;
    wire [31:0] term_inputs=depthwise?32'd1:{22'd0,ci};
    wire [31:0] terms=(kernel==3)?((term_inputs<<3)+term_inputs):
        (kernel==2)?(term_inputs<<2):(kernel==1)?term_inputs:32'd0;
    wire bad_shape=width==0||width>640||height==0||height>640||ci==0||ci>512||co==0||co>256||
        (kernel!=1&&kernel!=3)||(stride!=1&&stride!=2)||(depthwise&&ci!=co)||terms==0||terms>2304||
        command_ow==0||command_ow>1023||command_oh==0||command_oh>1023;
    wire [32:0] a_end={1'b0,abase}+{1'b0,a_count};
    wire [32:0] w_end={1'b0,wbase}+{1'b0,w_count};
    wire [32:0] o_end={1'b0,obase}+{1'b0,o_count};
    assign memory_reset=rst||cancel;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign cfg_ready=!rst&&!cancel&&state==IDLE&&!cmd_valid;
    assign done_valid=!rst&&!cancel&&state==DONE;
    assign wr_valid=!rst&&!cancel&&state==WRITE;
    assign wr_addr=obase+index;assign wr_data=result_byte;
    assign ack_ready=!rst&&!cancel&&state==WAIT_ACK;
    wire child_ready,child_valid;wire [31:0] child_tag;wire signed [39:0] child_sum;
    wire [7:0] child_pre,child_activation;wire [6:0] child_error;
    qy_conv_cached_memory #(.LUT_FILE(LUT_FILE)) window_core(
        .clk(clk),.rst(memory_reset),.cmd_valid(!memory_reset&&state==ISSUE),.cmd_ready(child_ready),
        .cmd_tag(done_tag),.cmd_activation_base(abase),.cmd_weight_base(wbase),.cmd_width(width),.cmd_height(height),.cmd_ox(ox),.cmd_oy(oy),
        .cmd_ci(ci),.cmd_co(co),.cmd_oc(oc),.cmd_kernel(kernel),.cmd_stride(stride),.cmd_pad(pad),.cmd_depthwise(depthwise),
        .cmd_bias(channel_params[69:38]),.cmd_multiplier(channel_params[37:6]),.cmd_shift(channel_params[5:0]),
        .cmd_input_zero(iz),.cmd_output_zero(oz),.cmd_lut_bank(bank),.cmd_use_lut(use_lut),
        .req_valid(req_valid),.req_ready(req_ready),.req_activation_addr(req_activation_addr),.req_weight_addr(req_weight_addr),.req_padding(req_padding),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_activation(rsp_activation),.rsp_weight(rsp_weight),.rsp_error(rsp_error),
        .m_valid(child_valid),.m_ready(!memory_reset&&state==COMPUTE),.m_tag(child_tag),.m_sum(child_sum),.m_pre(child_pre),.m_activation(child_activation),.m_error(child_error));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;params_valid<=0;channel_params<=0;cfg_error<=0;done_tag<=0;done_written<=0;done_error<=0;
            abase<=0;wbase<=0;obase<=0;total<=0;index<=0;width<=0;height<=0;ow<=0;oh<=0;ox<=0;oy<=0;ci<=0;co<=0;oc<=0;
            kernel<=0;stride<=0;pad<=0;depthwise<=0;use_lut<=0;iz<=0;oz<=0;result_byte<=0;bank<=0;
        end else begin
            cfg_error<=0;
            if(cancel) begin
                if(state!=IDLE) begin done_error<=12'h400;state<=DONE;end
            end else begin
                if(cfg_valid&&cfg_ready) begin
                    if(cfg_channel>255) cfg_error<=1;
                    else begin params[cfg_channel[7:0]]<={cfg_bias,cfg_multiplier,cfg_shift};params_valid[cfg_channel[7:0]]<=1;end
                end
                case(state)
                    IDLE: if(cmd_valid&&cmd_ready) begin
                        done_tag<=cmd_tag;done_written<=0;done_error<=0;index<=0;oc<=0;ox<=0;oy<=0;
                        abase<=cmd_activation_base;wbase<=cmd_weight_base;obase<=cmd_output_base;
                        width<=cmd_width;height<=cmd_height;ci<=cmd_ci;co<=cmd_co;kernel<=cmd_kernel;stride<=cmd_stride;pad<=cmd_pad;depthwise<=cmd_depthwise;
                        iz<=cmd_input_zero;oz<=cmd_output_zero;bank<=cmd_lut_bank;use_lut<=cmd_use_lut;state<=SHAPE;
                    end
                    SHAPE: begin
                        if(bad_shape) begin done_error<=12'h080;state<=DONE;end
                        else begin ow<=command_ow[9:0];oh<=command_oh[9:0];latched_terms<=terms[12:0];state<=SIZE;end
                    end
                    SIZE: begin
                        a_plane<=width*height; o_plane<=ow*oh; w_count<=co*latched_terms;state<=EXTENT;
                    end
                    EXTENT: begin a_count<=a_plane*ci; o_count<=o_plane*co;state<=BOUNDS;end
                    BOUNDS: begin
                        if(a_end>33'h100000000||w_end>33'h100000000||o_end>33'h100000000||o_count==0) begin done_error<=12'h080;state<=DONE;end
                        else begin total<=o_count;state<=PARAM;end
                    end
                    PARAM: begin
                        if(!params_valid[oc[7:0]]) begin done_error<=12'h100;state<=DONE;end
                        else begin channel_params<=params[oc[7:0]];state<=ISSUE;end
                    end
                    ISSUE: if(child_ready) state<=COMPUTE;
                    COMPUTE: if(child_valid) begin
                        if(child_tag!=done_tag) begin done_error<=12'h800;state<=DONE;end
                        else if(child_error!=0) begin done_error<={5'd0,child_error};state<=DONE;end
                        else begin result_byte<=child_activation;state<=WRITE;end
                    end
                    WRITE: if(wr_ready) state<=WAIT_ACK;
                    WAIT_ACK: if(ack_valid) begin
                        if(ack_error) begin done_error<=12'h200;state<=DONE;end
                        else begin
                            done_written<=done_written+32'd1;
                            if(index==total-1) state<=DONE;
                            else begin
                                index<=index+32'd1;
                                if(ox==ow-1) begin
                                    ox<=0;
                                    if(oy==oh-1) begin oy<=0;oc<=oc+9'd1;state<=PARAM;end
                                    else begin oy<=oy+10'd1;state<=ISSUE;end
                                end else begin ox<=ox+10'd1;state<=ISSUE;end
                            end
                        end
                    end
                    DONE: if(done_ready) state<=IDLE;
                    default: state<=IDLE;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
