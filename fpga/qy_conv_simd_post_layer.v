`timescale 1ns/1ps
`default_nettype none
// SIMD scheduler with overlapped parameter fetch, requantization and output acknowledgement.
// cancel resets this engine's child and MUST flush both external RAM responders.
module qy_conv_simd_post_layer #(parameter LUT_FILE="silu_banks.hex")(
    input wire clk,rst,cancel,
    output wire [479:0] req_extra_addr,output wire [14:0] req_extra_mask,input wire [119:0] rsp_extra_weight,output wire memory_reset,
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

    localparam IDLE=0,SHAPE=1,SIZE=2,EXTENT=3,BOUNDS=4,ORIGIN=5,
        OFFSET=6,BASE=7,ROW=8,START=9,STREAM=10,PARAM=11,PARAM_WAIT=12,
        POST_START=13,POST_WAIT=14,WRITE=15,ACK=16,DONE=17;
    reg [4:0] state;
    reg [69:0] params[0:255];reg [255:0] params_valid;reg [69:0] channel_params;
    reg [31:0] abase,wbase,obase,a_plane,o_plane,a_count,w_count,o_count;
    reg [31:0] out_block,out_cursor,spatial,weight_block;
    reg [9:0] width,height,ci,ow,oh,ox,oy,channel;
    reg [8:0] co,ocbase;reg [4:0] lane,output_lane;reg awaiting_ack;
    reg [1:0] kernel,stride,kx,ky;reg pad,use_lut;
    reg [7:0] iz,oz,result_byte;reg [6:0] bank;
    reg [11:0] terms,issued,received;
    reg signed [12:0] origin_x,origin_y,ix,iy;
    reg signed [22:0] row_offset;
    reg [31:0] row_base,a_cursor,row_start,channel_start;
    reg pending_padding;
    reg [31:0] w_cursor[0:15];reg signed [39:0] acc[0:15];
    wire [31:0] padded_w={22'd0,width}+{31'd0,pad}*2;
    wire [31:0] padded_h={22'd0,height}+{31'd0,pad}*2;
    wire [31:0] new_ow=(padded_w>=kernel)?((padded_w-kernel)>>(stride==2?1:0))+1:0;
    wire [31:0] new_oh=(padded_h>=kernel)?((padded_h-kernel)>>(stride==2?1:0))+1:0;
    wire [31:0] new_terms=kernel==3?({22'd0,ci}<<3)+ci:{22'd0,ci};
    wire bad_shape=width==0||width>640||height==0||height>640||ci==0||ci>512||co==0||co>256||
        (kernel!=1&&kernel!=3)||(stride!=1&&stride!=2)||new_terms>2304||new_ow==0||new_oh==0||new_ow>1023||new_oh>1023;
    wire [32:0] a_end={1'b0,abase}+{1'b0,a_count},w_end={1'b0,wbase}+{1'b0,w_count},o_end={1'b0,obase}+{1'b0,o_count};
    wire signed [12:0] sx=(stride==2)?$signed({2'd0,ox,1'b0}):$signed({3'd0,ox});
    wire signed [12:0] sy=(stride==2)?$signed({2'd0,oy,1'b0}):$signed({3'd0,oy});
    wire [8:0] active_oc=ocbase+lane;
    wire signed [39:0] biased=acc[lane]+{{8{channel_params[69]}},channel_params[69:38]};
    wire post_ready,post_valid;wire [31:0] post_tag;wire signed [39:0] post_sum;
    wire [7:0] post_pre,post_value;wire [2:0] post_error;
    assign memory_reset=rst||cancel;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign cfg_ready=!rst&&!cancel&&state==IDLE&&!cmd_valid;
    assign done_valid=!rst&&!cancel&&state==DONE;
    assign req_valid=!rst&&!cancel&&state==STREAM&&issued<terms;
    assign rsp_ready=!rst&&!cancel&&state==STREAM;
    assign req_padding=(iy<0||ix<0||iy>=$signed({3'd0,height})||ix>=$signed({3'd0,width}));
    assign req_activation_addr=req_padding?32'd0:a_cursor;
    assign req_weight_addr=w_cursor[0];
    wire post_phase=state==PARAM||state==PARAM_WAIT||state==POST_START||state==POST_WAIT;
    wire bad_param=state==PARAM&&!params_valid[active_oc[7:0]];
    wire post_bad=post_tag!=done_tag||post_error!=0;
    assign wr_valid=!memory_reset&&post_phase&&!bad_param&&!awaiting_ack&&post_valid&&!post_bad;
    assign wr_addr=out_cursor;assign wr_data=post_value;
    assign ack_ready=!memory_reset&&post_phase&&awaiting_ack;
    wire [127:0] weights={rsp_extra_weight,rsp_weight};
    wire signed [8:0] centered=pending_padding?9'sd0:($signed({1'b0,rsp_activation})-$signed({1'b0,iz}));
    genvar g;
    generate for(g=0;g<16;g=g+1) begin: mac_lanes
        wire signed [7:0] weight=weights[g*8+:8];
        wire signed [16:0] product=centered*weight;
        if(g>0) begin
            assign req_extra_addr[(g-1)*32+:32]=w_cursor[g];
            assign req_extra_mask[g-1]=(ocbase+g<co);
        end
        always @(posedge clk) begin
            if(rst||cancel||state==START) acc[g]<=0;
            else if(state==STREAM&&rsp_valid&&rsp_ready&&!rsp_error)
                acc[g]<=acc[g]+{{23{product[16]}},product};
            if(state==START) w_cursor[g]<=weight_block+g*terms;
            else if(req_valid&&req_ready) w_cursor[g]<=w_cursor[g]+1'b1;
        end
    end endgenerate
    // The pipeline may contain several channels. Its output remains stable
    // while the scatter RAM acknowledges the preceding write. Parameters and
    // accumulators remain unchanged until every channel has been acknowledged.
    qy_requant_pipeline #(.LUT_FILE(LUT_FILE)) post(
        .clk(clk),.rst(memory_reset||state==IDLE||state==DONE),
        .cmd_valid(state==POST_START&&!memory_reset),.cmd_ready(post_ready),
        .cmd_tag(done_tag),.cmd_terms(12'd1),.cmd_sum(biased),
        .cmd_multiplier(channel_params[37:6]),.cmd_shift(channel_params[5:0]),.cmd_output_zero(oz),.cmd_lut_bank(bank),.cmd_use_lut(use_lut),
        .m_valid(post_valid),.m_ready(wr_valid&&wr_ready),.m_tag(post_tag),.m_sum(post_sum),.m_pre(post_pre),.m_activation(post_value),.m_error(post_error));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;params_valid<=0;channel_params<=0;cfg_error<=0;done_tag<=0;done_written<=0;done_error<=0;
            abase<=0;wbase<=0;obase<=0;width<=0;height<=0;ci<=0;co<=0;ow<=0;oh<=0;ox<=0;oy<=0;
            kernel<=0;stride<=0;pad<=0;use_lut<=0;iz<=0;oz<=0;bank<=0;terms<=0;issued<=0;received<=0;
            ocbase<=0;lane<=0;output_lane<=0;awaiting_ack<=0;channel<=0;kx<=0;ky<=0;pending_padding<=0;result_byte<=0;
            a_plane<=0;o_plane<=0;a_count<=0;w_count<=0;o_count<=0;out_block<=0;out_cursor<=0;spatial<=0;weight_block<=0;
            origin_x<=0;origin_y<=0;ix<=0;iy<=0;row_offset<=0;row_base<=0;a_cursor<=0;row_start<=0;channel_start<=0;
        end else begin
            cfg_error<=0;
            if(cancel) begin if(state!=IDLE) begin done_error<=12'h400;state<=DONE;end end
            else begin
                if(cfg_valid&&cfg_ready) begin
                    if(cfg_channel>255) cfg_error<=1;
                    else begin params[cfg_channel[7:0]]<={cfg_bias,cfg_multiplier,cfg_shift};params_valid[cfg_channel[7:0]]<=1;end
                end
                case(state)
                    IDLE:if(cmd_valid) begin
                        done_tag<=cmd_tag;done_written<=0;done_error<=0;abase<=cmd_activation_base;wbase<=cmd_weight_base;obase<=cmd_output_base;
                        width<=cmd_width;height<=cmd_height;ci<=cmd_ci;co<=cmd_co;kernel<=cmd_kernel;stride<=cmd_stride;pad<=cmd_pad;
                        iz<=cmd_input_zero;oz<=cmd_output_zero;bank<=cmd_lut_bank;use_lut<=cmd_use_lut;
                        ox<=0;oy<=0;ocbase<=0;spatial<=0;out_block<=cmd_output_base;state<=SHAPE;
                    end
                    SHAPE:if(bad_shape) begin done_error<=12'h080;state<=DONE;end
                        else begin ow<=new_ow[9:0];oh<=new_oh[9:0];terms<=new_terms[11:0];state<=SIZE;end
                    SIZE:begin a_plane<=width*height;o_plane<=ow*oh;w_count<=co*terms;state<=EXTENT;end
                    EXTENT:begin a_count<=a_plane*ci;o_count<=o_plane*co;state<=BOUNDS;end
                    BOUNDS:if(a_end>33'h100000000||w_end>33'h100000000||o_end>33'h100000000||o_count==0) begin done_error<=12'h080;state<=DONE;end
                        else state<=ORIGIN;
                    ORIGIN:begin origin_x<=sx-$signed({12'd0,pad});origin_y<=sy-$signed({12'd0,pad});state<=OFFSET;end
                    OFFSET:begin row_offset<=origin_y*$signed({1'b0,width});weight_block<=wbase+ocbase*terms;state<=BASE;end
                    BASE:begin row_base<=abase+{{9{row_offset[22]}},row_offset};state<=ROW;end
                    ROW:begin a_cursor<=row_base+{{19{origin_x[12]}},origin_x};row_start<=row_base+{{19{origin_x[12]}},origin_x};channel_start<=row_base+{{19{origin_x[12]}},origin_x};state<=START;end
                    START:begin
                        ix<=origin_x;iy<=origin_y;kx<=0;ky<=0;channel<=0;issued<=0;received<=0;lane<=0;
                        out_cursor<=out_block+spatial;output_lane<=0;awaiting_ack<=0;state<=STREAM;
                    end
                    STREAM:begin
                        if(req_valid&&req_ready) begin
                            pending_padding<=req_padding;issued<=issued+1'b1;
                            if(kx==kernel-1) begin
                                kx<=0;ix<=origin_x;
                                if(ky==kernel-1) begin
                                    ky<=0;channel<=channel+1'b1;iy<=origin_y;
                                    channel_start<=channel_start+a_plane;row_start<=channel_start+a_plane;a_cursor<=channel_start+a_plane;
                                end else begin ky<=ky+1'b1;iy<=iy+13'sd1;row_start<=row_start+width;a_cursor<=row_start+width;end
                            end else begin kx<=kx+1'b1;ix<=ix+13'sd1;a_cursor<=a_cursor+1'b1;end
                        end
                        if(rsp_valid&&rsp_ready) begin
                            received<=received+1'b1;
                            if(rsp_error) begin done_error<=12'h040;state<=DONE;end
                            else if(received==terms-1) state<=PARAM;
                        end
                    end
                    PARAM:begin
                        if(!params_valid[active_oc[7:0]]) begin done_error<=12'h100;state<=DONE;end
                        else begin channel_params<=params[active_oc[7:0]];state<=PARAM_WAIT;end
                    end
                    PARAM_WAIT:state<=POST_START;
                    POST_START:if(post_ready) begin
                        if(lane<15&&active_oc+1<co) begin lane<=lane+1'b1;state<=PARAM;end
                        else state<=POST_WAIT;
                    end
                    POST_WAIT:begin end // Results and acknowledgements drain below.
                    DONE:if(done_ready) state<=IDLE;
                    default:begin done_error<=12'hfff;state<=DONE;end
                endcase
                if(post_phase&&!bad_param) begin
                    if(wr_valid&&wr_ready) awaiting_ack<=1;
                    if(post_valid&&!awaiting_ack&&post_bad) begin
                        done_error<=post_tag!=done_tag?12'h800:{9'd0,post_error};state<=DONE;
                    end else if(ack_valid&&ack_ready) begin
                        awaiting_ack<=0;
                        if(ack_error) begin done_error<=12'h200;state<=DONE;end
                        else begin
                            done_written<=done_written+1'b1;
                            if(output_lane<15&&ocbase+output_lane+1<co) begin
                                output_lane<=output_lane+1'b1;out_cursor<=out_cursor+o_plane;
                            end else if(spatial+1<o_plane) begin
                                spatial<=spatial+1'b1;
                                if(ox==ow-1) begin ox<=0;oy<=oy+1'b1;end else ox<=ox+1'b1;
                                state<=ORIGIN;
                            end else if(ocbase+16<co) begin
                                ocbase<=ocbase+9'd16;out_block<=out_block+(o_plane<<4);ox<=0;oy<=0;spatial<=0;state<=ORIGIN;
                            end else state<=DONE;
                        end
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
