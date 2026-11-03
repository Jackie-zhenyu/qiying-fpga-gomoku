`timescale 1ns/1ps
`default_nettype none
// Shared neural operator executor. Opcodes 1..6 retain the Conv-only layout.
// Additional typed descriptors reuse the same physical caches and DMA engines.
// 256-bit words: opcode[255:252], tag[251:220], payload[219:0].
// The instruction producer must prove complete feature/weight load coverage.
// A published output is immutable until RELEASE. STORE may scatter it in rows.
// Cancellation drains external responses before invalidating local caches.
module qy_nn_tile_executor_simd #(parameter LUT_FILE="silu_banks.hex",parameter EXP_FILE="softmax_exp.hex",parameter ENABLE_CONV_LUT=1)(
    input wire clk,rst,cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [255:0] cmd_data,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,done_count,
    output reg [15:0] done_error,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strobe,
    input wire ack_valid,output wire ack_ready,input wire ack_error
);
    localparam [3:0] LOAD_A=1,LOAD_W=2,PARAM=3,CONV=4,STORE=5,RELEASE=6,MATPARM=7,MATRIX=8,LOOKUP=9,SOFTPARM=10,SOFTMAX=11,POOL=12;
    localparam [4:0] IDLE=0,CHECK=1,LOAD_START=2,LOAD_WAIT=3,CFG_START=4,CFG_CHECK=5,
        BEGIN_OUT=6,BEGIN_ACK=7,CONV_START=8,CONV_WAIT=9,PUBLISH=10,PUBLISH_ACK=11,
        STORE_START=12,STORE_WAIT=13,FREE=14,ABORT=15,DONE=16;
    reg [4:0] state;reg [3:0] op;reg [219:0] payload;reg cancelled,have_a,have_w;
    reg [31:0] output_tag;
    wire [31:0] dma_source=payload[128:97],dma_stride=payload[96:65],dma_base=payload[64:33];
    wire [15:0] dma_rows=payload[32:17];wire [16:0] dma_bytes=payload[16:0];
    wire [31:0] abase,wbase,obase;wire [9:0] width,height,ci;wire [8:0] co;
    wire [1:0] kernel,stride;wire pad,dw,use_lut;wire [7:0] iz,oz;wire [6:0] bank;
    assign {abase,wbase,obase,width,height,ci,co,kernel,stride,pad,dw,iz,oz,bank,use_lut}=payload[164:0];
    wire [31:0] output_length=op==CONV?payload[196:165]:op==MATRIX?payload[189:158]:
        op==LOOKUP?{15'd0,payload[18:2]}:op==SOFTMAX?{23'd0,payload[8:0]}:payload[92:61];
    reg mat_configured,soft_configured;reg [31:0] mat_tag,soft_tag;
    reg [31:0] mat_multiplier,soft_multiplier;reg [5:0] mat_shift,soft_shift;
    reg [7:0] mat_az,mat_bz,mat_oz,soft_oz;reg soft_bank;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;assign done_valid=!rst&&!cancel&&state==DONE;
    wire feature_reset,conv_memory_reset;
    assign feature_reset=rst||conv_memory_reset||state==ABORT;
    wire out_cancel=state==FREE||state==ABORT||(cancel&&state==CONV_WAIT);
    wire load_valid,load_ready,load_error;wire [31:0] load_addr;wire [7:0] load_data;
    wire ld_cmd_ready,ld_done;wire [31:0] ld_tag,ld_count;wire [3:0] ld_error;
    qy_tile_read_pipeline loader(
        .clk(clk),.rst(rst),.cancel(cancel&&state==LOAD_WAIT),
        .cmd_valid(!cancel&&state==LOAD_START),.cmd_ready(ld_cmd_ready),.cmd_tag(done_tag),
        .cmd_source(dma_source),.cmd_row_stride(dma_stride),.cmd_cache_base(dma_base),.cmd_row_bytes(dma_bytes),.cmd_rows(dma_rows),
        .cmd_fill(payload[129]),.cmd_fill_byte(payload[137:130]),
        .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_addr(rd_addr),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .load_valid(load_valid),.load_ready(load_ready),.load_addr(load_addr),.load_data(load_data),.load_error(load_error),
        .done_valid(ld_done),.done_ready(state==LOAD_WAIT),.done_tag(ld_tag),.done_written(ld_count),.done_error(ld_error));
    wire req_valid,req_ready,req_padding,frsp_valid,frsp_ready,frsp_error;
    wire [31:0] req_a,req_w;wire [7:0] frsp_a;wire signed [7:0] frsp_w;
    wire [479:0] extra_addr;wire [14:0] extra_mask;wire [119:0] extra_weight;
    qy_feature_pair_simd features(
        .req_extra_addr(extra_addr),.req_extra_mask(op==CONV?extra_mask:15'd0),.rsp_extra_weight(extra_weight),
        .clk(clk),.rst(feature_reset),.load_valid(load_valid),.load_ready(load_ready),.load_weight(op==LOAD_W),
        .load_addr(load_addr),.load_data(load_data),.load_error(load_error),
        .req_valid(req_valid),.req_ready(req_ready),.req_activation_addr(req_a),.req_weight_addr(req_w),.req_padding(req_padding),
        .rsp_valid(frsp_valid),.rsp_ready(frsp_ready),.rsp_activation(frsp_a),.rsp_weight(frsp_w),.rsp_error(frsp_error));
    wire cfg_ready,cfg_error,conv_ready,conv_done;wire [31:0] conv_tag,conv_count;wire [11:0] conv_error;
    wire out_wr_valid,out_wr_ready,out_ack_valid,out_ack_ready,out_ack_error;
    wire [31:0] out_wr_addr;wire [7:0] out_wr_data;
    qy_nn_compute_simd #(.LUT_FILE(LUT_FILE),.EXP_FILE(EXP_FILE),.ENABLE_CONV_LUT(ENABLE_CONV_LUT)) compute(
        .req_extra_addr(extra_addr),.req_extra_mask(extra_mask),.rsp_extra_weight(extra_weight),
        .clk(clk),.rst(rst),.cancel(cancel&&state==CONV_WAIT),.memory_reset(conv_memory_reset),.op(op),.payload(payload),
        .cfg_valid(!cancel&&state==CFG_START),.cfg_ready(cfg_ready),.cfg_error(cfg_error),
        .cmd_valid(!cancel&&state==CONV_START),.cmd_ready(conv_ready),.cmd_tag(done_tag),
        .mat_multiplier(mat_multiplier),.mat_shift(mat_shift),.mat_az(mat_az),.mat_bz(mat_bz),.mat_oz(mat_oz),
        .soft_multiplier(soft_multiplier),.soft_shift(soft_shift),.soft_oz(soft_oz),.soft_bank(soft_bank),
        .req_valid(req_valid),.req_ready(req_ready),.req_a(req_a),.req_w(req_w),.req_padding(req_padding),
        .rsp_valid(frsp_valid),.rsp_ready(frsp_ready),.rsp_a(frsp_a),.rsp_w(frsp_w),.rsp_error(frsp_error),
        .wr_valid(out_wr_valid),.wr_ready(out_wr_ready),.wr_addr(out_wr_addr),.wr_data(out_wr_data),
        .ack_valid(out_ack_valid),.ack_ready(out_ack_ready),.ack_error(out_ack_error),
        .done_valid(conv_done),.done_ready(state==CONV_WAIT),.done_tag(conv_tag),.done_written(conv_count),.done_error(conv_error));
    wire begin_ready,begin_error,publish_ready,publish_error,published;wire [31:0] written_count;
    wire cache_valid,cache_ready,cache_rsp_valid,cache_rsp_ready,cache_rsp_error;
    wire [31:0] cache_tag,cache_addr,cache_rsp_tag;wire [7:0] cache_rsp_data;
    qy_result_scatter_ram results(
        .begin_scatter(op==CONV&&!dw),
        .clk(clk),.rst(rst),.cancel(out_cancel),
        .begin_valid(!cancel&&state==BEGIN_OUT),.begin_ready(begin_ready),.begin_tag(done_tag),.begin_length(output_length),.begin_error(begin_error),
        .wr_valid(out_wr_valid),.wr_ready(out_wr_ready),.wr_addr(out_wr_addr),.wr_data(out_wr_data),
        .ack_valid(out_ack_valid),.ack_ready(out_ack_ready),.ack_error(out_ack_error),
        .publish_valid(!cancel&&state==PUBLISH),.publish_ready(publish_ready),.publish_tag(done_tag),.publish_error(publish_error),
        .published(published),.written_count(written_count),
        .rd_valid(cache_valid),.rd_ready(cache_ready),.rd_tag(cache_tag),.rd_addr(cache_addr),
        .rsp_valid(cache_rsp_valid),.rsp_ready(cache_rsp_ready),.rsp_tag(cache_rsp_tag),.rsp_data(cache_rsp_data),.rsp_error(cache_rsp_error));
    wire store_ready,store_done;wire [31:0] store_tag,store_count;wire [3:0] store_error;
    qy_tile_write_pipeline drain(
        .clk(clk),.rst(rst),.cancel(cancel&&state==STORE_WAIT),
        .cmd_valid(!cancel&&state==STORE_START),.cmd_ready(store_ready),.cmd_tag(done_tag),
        .cmd_destination(dma_source),.cmd_row_stride(dma_stride),.cmd_cache_base(dma_base),.cmd_row_bytes(dma_bytes),.cmd_rows(dma_rows),
        .cache_valid(cache_valid),.cache_ready(cache_ready),.cache_tag(cache_tag),.cache_addr(cache_addr),
        .cache_rsp_valid(cache_rsp_valid),.cache_rsp_ready(cache_rsp_ready),.cache_rsp_tag(cache_rsp_tag),.cache_rsp_data(cache_rsp_data),.cache_rsp_error(cache_rsp_error),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data),.wr_strobe(wr_strobe),
        .ack_valid(ack_valid),.ack_ready(ack_ready),.ack_error(ack_error),
        .done_valid(store_done),.done_ready(state==STORE_WAIT),.done_tag(store_tag),.done_written(store_count),.done_error(store_error));
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;op<=0;payload<=0;cancelled<=0;have_a<=0;have_w<=0;output_tag<=0;done_tag<=0;done_count<=0;done_error<=0;
            mat_configured<=0;soft_configured<=0;mat_tag<=0;soft_tag<=0;mat_multiplier<=0;soft_multiplier<=0;
            mat_shift<=0;soft_shift<=0;mat_az<=0;mat_bz<=0;mat_oz<=0;soft_oz<=0;soft_bank<=0;
        end
        else begin
            if(cancel&&state!=IDLE&&state!=DONE) cancelled<=1;
            // Active child transfers must finish draining before ABORT clears caches.
            if(cancel&&state!=IDLE&&state!=DONE&&state!=LOAD_WAIT&&state!=CONV_WAIT&&state!=STORE_WAIT&&state!=ABORT) begin
                done_error<=16'h8000;state<=ABORT;
            end else case(state)
                IDLE: if(cmd_valid&&cmd_ready) begin
                    op<=cmd_data[255:252];done_tag<=cmd_data[251:220];payload<=cmd_data[219:0];
                    done_count<=0;done_error<=0;cancelled<=0;state<=CHECK;
                end
                CHECK: begin
                    if((op==LOAD_A||op==LOAD_W||op==STORE)&&payload[219:138]!=0 ||
                       op==PARAM&&payload[219:79]!=0 || op==CONV&&payload[219:197]!=0 ||
                       op==STORE&&payload[137:129]!=0 || op==RELEASE&&payload!=0 ||
                       op==MATPARM&&payload[219:62]!=0 || op==MATRIX&&payload[219:190]!=0 ||
                       op==LOOKUP&&payload[219:115]!=0 || op==SOFTPARM&&payload[219:47]!=0 ||
                       op==SOFTMAX&&payload[219:41]!=0 || op==POOL&&payload[219:93]!=0 || op==CONV&&!ENABLE_CONV_LUT&&payload[0] || op<LOAD_A||op>POOL) begin done_error<=1;state<=DONE;end
                    else case(op)
                        LOAD_A,LOAD_W: state<=LOAD_START;
                        PARAM: state<=CFG_START;
                        CONV,MATRIX,LOOKUP,SOFTMAX,POOL: if(published) begin done_error<=2;state<=DONE;end
                            else if(!have_a||((op==CONV||op==MATRIX||op==LOOKUP)&&!have_w)||
                                (op==MATRIX&&(!mat_configured||mat_tag!=done_tag))||
                                (op==SOFTMAX&&(!soft_configured||soft_tag!=done_tag))) begin done_error<=4;state<=DONE;end
                            else state<=BEGIN_OUT;
                        STORE: if(!published||done_tag!=output_tag) begin done_error<=3;state<=DONE;end else state<=STORE_START;
                        RELEASE: state<=FREE;
                        MATPARM:begin
                            if(payload[61:30]==0||payload[61]||payload[29:24]>62) begin mat_configured<=0;done_error<=16'h0010;end
                            else begin {mat_multiplier,mat_shift,mat_az,mat_bz,mat_oz}<=payload[61:0];mat_tag<=done_tag;mat_configured<=1;end
                            state<=DONE;
                        end
                        SOFTPARM:begin
                            if(payload[46:15]==0||payload[46]||payload[14:9]>31) begin soft_configured<=0;done_error<=16'h0010;end
                            else begin {soft_multiplier,soft_shift,soft_oz,soft_bank}<=payload[46:0];soft_tag<=done_tag;soft_configured<=1;end
                            state<=DONE;
                        end
                        default: begin done_error<=1;state<=DONE;end
                    endcase
                end
                LOAD_START: if(ld_cmd_ready) state<=LOAD_WAIT;
                LOAD_WAIT: if(ld_done) begin
                    done_count<=ld_count;
                    if(cancelled||cancel||ld_error!=0||ld_tag!=done_tag) begin
                        done_error<=cancelled||cancel?16'h8000:ld_tag!=done_tag?16'h4000:{8'd0,ld_error,4'd0};state<=ABORT;
                    end else begin if(op==LOAD_A) have_a<=1;else have_w<=1;state<=DONE;end
                end
                CFG_START: if(cfg_ready) state<=CFG_CHECK;
                CFG_CHECK: begin done_error<=cfg_error?16'h0010:16'd0;state<=DONE;end
                BEGIN_OUT: if(begin_ready) state<=BEGIN_ACK;
                BEGIN_ACK: if(begin_error) begin done_error<=16'h0010;state<=ABORT;end else state<=CONV_START;
                CONV_START: if(conv_ready) state<=CONV_WAIT;
                CONV_WAIT: if(conv_done) begin
                    done_count<=conv_count;
                    if(cancelled||cancel||conv_error!=0||conv_tag!=done_tag||conv_count!=output_length) begin
                        done_error<=cancelled||cancel?16'h8000:conv_tag!=done_tag?16'h4000:conv_error!=0?{conv_error,4'd0}:16'h2000;state<=ABORT;
                    end else state<=PUBLISH;
                end
                PUBLISH: if(publish_ready) state<=PUBLISH_ACK;
                PUBLISH_ACK: if(publish_error||!published) begin done_error<=16'h0020;state<=ABORT;end
                    else begin output_tag<=done_tag;state<=DONE;end
                STORE_START: if(store_ready) state<=STORE_WAIT;
                STORE_WAIT: if(store_done) begin
                    done_count<=store_count;
                    if(cancelled||cancel||store_error!=0||store_tag!=done_tag) begin
                        done_error<=cancelled||cancel?16'h8000:store_tag!=done_tag?16'h4000:{8'd0,store_error,4'd0};state<=ABORT;
                    end else state<=DONE;
                end
                FREE: begin output_tag<=0;state<=DONE;end
                ABORT: begin output_tag<=0;have_a<=0;have_w<=0;mat_configured<=0;soft_configured<=0;state<=DONE;end
                DONE: if(done_ready&&!cancel) state<=IDLE;
                default: begin done_error<=16'hffff;state<=ABORT;end
            endcase
        end
    end
endmodule
`default_nettype wire
