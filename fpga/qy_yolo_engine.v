`timescale 1ns/1ps
`default_nettype none
// Sequenced immutable camera frame -> preprocessing -> complete NN program
// -> DDR-backed YOLO decode. One inference at a time; all native transactions
// drain before changing memory owner. Full frozen configuration is supplied
// by the generated board wrapper; model_ready requires validated loaded assets.
// Detection records are PROVISIONAL: commit only after successful done with
// matching boot/frame context. UI never writes the official Gomoku position.
module qy_yolo_engine #(
    parameter [31:0] INPUT_BASE=32'h08000000,PROGRAM_BASE=32'h0b000000,PROGRAM_WORDS=840259,
    parameter [95:0] CLASS_BASES=0,BOX_BASES=0,
    parameter [191:0] COORD_BASES=0,
    parameter INPUT_FILE="yolo_input.hex",SCORE_FILE="yolo_scores.hex",EXP_FILE="softmax_exp.hex"
)(
    input wire clk,input wire rst,input wire cancel,input wire model_ready,
    input wire reuse_input,output wire [3:0] perf_program_phase,perf_opcode,
    input wire start_valid,output wire start_ready,input wire [31:0] start_tag,input wire [31:0] start_frame_base,
    output wire frame_release_valid,input wire frame_release_ready,output wire [31:0] frame_release_tag,
    output wire result_valid,input wire result_ready,output wire [31:0] result_tag,
    output wire [8:0] result_index,output wire [191:0] result_data,output wire result_last,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,
    output reg [3:0] done_stage,output reg [15:0] done_error,output wire [3:0] progress,
    output wire preview_valid,output wire [9:0] preview_x,preview_y,output wire [15:0] preview_rgb565,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strb,
    input wire ack_valid,output wire ack_ready,input wire ack_error
);
    localparam [3:0] IDLE=0,PRE_START=1,PRE_RUN=2,RELEASE=3,NN_START=4,NN_RUN=5,POST_START=6,POST_RUN=7,DONE=8;
    reg [3:0] state;reg [31:0] frame_base;reg cancelled;
    wire abort_request=cancel||!model_ready;
    wire child_cancel=abort_request&&!cancelled;
    wire pre_ready,pre_done;wire [31:0] pre_tag;wire [7:0] pre_error;
    wire pre_rd,pre_rsp_ready,pre_wr,pre_ack_ready;wire [31:0] pre_addr,pre_waddr,pre_strb;wire [255:0] pre_data;
    qy_camera_preprocess #(.INPUT_FILE(INPUT_FILE)) preprocess(
        .clk(clk),.rst(rst),.cancel(child_cancel&&state==PRE_RUN),
        .cmd_valid(state==PRE_START&&!abort_request),.cmd_ready(pre_ready),.cmd_tag(done_tag),.cmd_frame_base(frame_base),.cmd_output_base(INPUT_BASE),
        .done_valid(pre_done),.done_ready(state==PRE_RUN),.done_tag(pre_tag),.done_error(pre_error),
        .preview_valid(preview_valid),.preview_x(preview_x),.preview_y(preview_y),.preview_rgb565(preview_rgb565),
        .rd_valid(pre_rd),.rd_ready(state==PRE_RUN&&rd_ready),.rd_addr(pre_addr),
        .rsp_valid(state==PRE_RUN&&rsp_valid),.rsp_ready(pre_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .wr_valid(pre_wr),.wr_ready(state==PRE_RUN&&wr_ready),.wr_addr(pre_waddr),.wr_data(pre_data),.wr_strb(pre_strb),
        .b_valid(state==PRE_RUN&&ack_valid),.b_ready(pre_ack_ready),.b_error(ack_error));
    wire nn_ready,nn_done;wire [31:0] nn_tag,nn_count;wire [3:0] nn_reason;wire [15:0] nn_error;
    wire nn_rd,nn_rsp_ready,nn_wr,nn_ack_ready;wire [31:0] nn_addr,nn_waddr,nn_strb;wire [255:0] nn_data;
    qy_nn_program #(.EXP_FILE(EXP_FILE),.ENABLE_CONV_LUT(0)) program_core(
        .clk(clk),.rst(rst),.cancel(child_cancel&&state==NN_RUN),.perf_program_phase(perf_program_phase),.perf_opcode(perf_opcode),
        .start_valid(state==NN_START&&!abort_request),.start_ready(nn_ready),.start_tag(done_tag),.start_base(PROGRAM_BASE),.start_count(PROGRAM_WORDS),
        .done_valid(nn_done),.done_ready(state==NN_RUN),.done_tag(nn_tag),.done_count(nn_count),.done_reason(nn_reason),.done_error(nn_error),
        .rd_valid(nn_rd),.rd_ready(state==NN_RUN&&rd_ready),.rd_addr(nn_addr),
        .rsp_valid(state==NN_RUN&&rsp_valid),.rsp_ready(nn_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .wr_valid(nn_wr),.wr_ready(state==NN_RUN&&wr_ready),.wr_addr(nn_waddr),.wr_data(nn_data),.wr_strobe(nn_strb),
        .ack_valid(state==NN_RUN&&ack_valid),.ack_ready(nn_ack_ready),.ack_error(ack_error));
    wire post_ready,post_valid,post_last;wire [31:0] post_tag;wire [8:0] post_index;wire [191:0] post_data;wire [7:0] post_error;
    wire post_rd,post_rsp_ready;wire [31:0] post_addr;
    wire discard=cancelled||abort_request;
    wire post_consume=state==POST_RUN&&(discard||post_error!=0||result_ready);
    qy_yolo_postprocess #(.SCORE_FILE(SCORE_FILE)) postprocess(
        .clk(clk),.rst(rst),.cancel(child_cancel&&state==POST_RUN),
        .cmd_valid(state==POST_START&&!abort_request),.cmd_ready(post_ready),.cmd_tag(done_tag),
        .cmd_class_bases(CLASS_BASES),.cmd_box_bases(BOX_BASES),.cmd_coord_bases(COORD_BASES),
        .m_valid(post_valid),.m_ready(post_consume),.m_tag(post_tag),.m_index(post_index),.m_data(post_data),.m_last(post_last),.m_error(post_error),
        .rd_valid(post_rd),.rd_ready(state==POST_RUN&&rd_ready),.rd_addr(post_addr),
        .rsp_valid(state==POST_RUN&&rsp_valid),.rsp_ready(post_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error));
    assign start_ready=!rst&&!cancel&&model_ready&&state==IDLE;
    assign frame_release_valid=!rst&&state==RELEASE;assign frame_release_tag=done_tag;
    assign result_valid=!rst&&state==POST_RUN&&post_valid&&post_error==0&&!discard;
    assign result_tag=post_tag;assign result_index=post_index;assign result_data=post_data;assign result_last=post_last;
    assign done_valid=!rst&&!cancel&&state==DONE;assign progress=state;
    assign rd_valid=!rst&&((state==PRE_RUN&&pre_rd)||(state==NN_RUN&&nn_rd)||(state==POST_RUN&&post_rd));
    assign rd_addr=state==PRE_RUN?pre_addr:state==NN_RUN?nn_addr:post_addr;
    assign rsp_ready=!rst&&((state==PRE_RUN&&pre_rsp_ready)||(state==NN_RUN&&nn_rsp_ready)||(state==POST_RUN&&post_rsp_ready));
    assign wr_valid=!rst&&((state==PRE_RUN&&pre_wr)||(state==NN_RUN&&nn_wr));
    assign wr_addr=state==PRE_RUN?pre_waddr:nn_waddr;assign wr_data=state==PRE_RUN?pre_data:nn_data;assign wr_strb=state==PRE_RUN?pre_strb:nn_strb;
    assign ack_ready=!rst&&((state==PRE_RUN&&pre_ack_ready)||(state==NN_RUN&&nn_ack_ready));
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;frame_base<=0;cancelled<=0;done_tag<=0;done_stage<=0;done_error<=0;end
        else begin
            if(abort_request&&state!=IDLE&&state!=DONE) cancelled<=1;
            case(state)
                IDLE:if(start_valid&&start_ready) begin done_tag<=start_tag;frame_base<=start_frame_base;cancelled<=0;done_stage<=0;done_error<=0;state<=reuse_input?NN_START:PRE_START;end
                PRE_START:if(abort_request) begin done_stage<=1;done_error<=16'h8000;state<=RELEASE;end else if(pre_ready) state<=PRE_RUN;
                PRE_RUN:if(pre_done) begin
                    if(cancelled||abort_request) begin done_stage<=1;done_error<=16'h8000;end
                    else if(pre_tag!=done_tag||pre_error!=0) begin done_stage<=2;done_error<=pre_tag!=done_tag?16'h4000:{8'd0,pre_error};end
                    state<=RELEASE;
                end
                RELEASE:if(frame_release_ready) begin
                    if(cancelled||abort_request) begin done_stage<=1;done_error<=16'h8000;state<=DONE;end
                    else state<=done_error==0?NN_START:DONE;
                end
                NN_START:if(abort_request) begin done_stage<=1;done_error<=16'h8000;state<=DONE;end else if(nn_ready) state<=NN_RUN;
                NN_RUN:if(nn_done) begin
                    if(cancelled||abort_request) begin done_stage<=1;done_error<=16'h8000;state<=DONE;end
                    else if(nn_tag!=done_tag||nn_reason!=0||nn_error!=0||nn_count!=PROGRAM_WORDS) begin done_stage<=3;done_error<=nn_tag!=done_tag?16'h4000:nn_error!=0?nn_error:{8'd0,nn_reason,4'h1};state<=DONE;end
                    else state<=POST_START;
                end
                POST_START:if(abort_request) begin done_stage<=1;done_error<=16'h8000;state<=DONE;end else if(post_ready) state<=POST_RUN;
                POST_RUN:if(post_valid&&post_consume&&post_last) begin
                    if(cancelled||abort_request) begin done_stage<=1;done_error<=16'h8000;end
                    else if(post_tag!=done_tag||post_error!=0||post_index!=255) begin done_stage<=4;done_error<=post_tag!=done_tag?16'h4000:post_error!=0?{8'd0,post_error}:16'h2000;end
                    state<=DONE;
                end
                DONE:if(done_ready&&!cancel) state<=IDLE;
                default:begin done_stage<=15;done_error<=16'hffff;state<=DONE;end
            endcase
        end
    end
endmodule
`default_nettype wire
