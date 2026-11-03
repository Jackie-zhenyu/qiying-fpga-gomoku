`timescale 1ns/1ps
`default_nettype none
// Fetch a bounded sequence of 32-byte tile instructions from external memory.
// Only one instruction executes at a time. Instruction fetch and operand reads
// share the read bridge without overlap; every accepted response is drained.
// Software prepares memory offline. No host participates between start and done.
// Full YOLO graph lowering, model admission and physical DDR arbitration are
// separate obligations, not implied by this executor.
module qy_nn_program #(parameter LUT_FILE="silu_banks.hex",parameter EXP_FILE="softmax_exp.hex",parameter ENABLE_CONV_LUT=0)(
    input wire clk,rst,cancel,
    output wire [3:0] perf_program_phase,perf_opcode,
    input wire start_valid,output wire start_ready,input wire [31:0] start_tag,start_base,start_count,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,done_count,
    output reg [3:0] done_reason,output reg [15:0] done_error,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strobe,
    input wire ack_valid,output wire ack_ready,input wire ack_error
);
    localparam [3:0] IDLE=0,CHECK=1,CLEAR=2,FETCH=3,RECEIVE=4,ISSUE=5,EXECUTE=6,
        NEXT=7,DRAIN=8,FLUSH=9,DONE=10;
    reg [3:0] state;reg [31:0] base,count,address;reg [255:0] instruction;reg cancelled;
    assign perf_program_phase=state;assign perf_opcode=instruction[255:252];
    wire [37:0] program_end={6'd0,base}+{1'b0,count,5'd0};
    wire ex_ready,ex_done;wire [31:0] ex_tag,ex_count;wire [15:0] ex_error;
    wire ex_rd_valid,ex_rd_ready,ex_rsp_valid,ex_rsp_ready;wire [31:0] ex_rd_addr;
    wire local_reset=rst||state==CLEAR||state==FLUSH;
    assign start_ready=!rst&&!cancel&&state==IDLE;assign done_valid=!rst&&!cancel&&state==DONE;
    assign rd_valid=!rst&&((state==FETCH&&!cancel)||(state==EXECUTE&&ex_rd_valid));
    assign rd_addr=state==FETCH?address:ex_rd_addr;
    assign rsp_ready=!rst&&((state==RECEIVE||state==DRAIN)||(state==EXECUTE&&ex_rsp_ready));
    assign ex_rd_ready=state==EXECUTE&&rd_ready;assign ex_rsp_valid=state==EXECUTE&&rsp_valid;
    qy_nn_tile_executor_simd_strided #(.LUT_FILE(LUT_FILE),.EXP_FILE(EXP_FILE),.ENABLE_CONV_LUT(ENABLE_CONV_LUT)) executor(
        .clk(clk),.rst(local_reset),.cancel(cancel&&state==EXECUTE),
        .cmd_valid(!cancel&&state==ISSUE),.cmd_ready(ex_ready),.cmd_data(instruction),
        .done_valid(ex_done),.done_ready(state==EXECUTE),.done_tag(ex_tag),.done_count(ex_count),.done_error(ex_error),
        .rd_valid(ex_rd_valid),.rd_ready(ex_rd_ready),.rd_addr(ex_rd_addr),
        .rsp_valid(ex_rsp_valid),.rsp_ready(ex_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_addr(wr_addr),.wr_data(wr_data),.wr_strobe(wr_strobe),
        .ack_valid(ack_valid),.ack_ready(ack_ready),.ack_error(ack_error));
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;base<=0;count<=0;address<=0;instruction<=0;cancelled<=0;done_tag<=0;done_count<=0;done_reason<=0;done_error<=0;end
        else begin
            if(cancel&&state!=IDLE&&state!=DONE) cancelled<=1;
            if(cancel&&state!=IDLE&&state!=DONE&&state!=EXECUTE&&state!=DRAIN&&state!=FLUSH) begin
                done_reason<=4;done_error<=0;
                state<=state==RECEIVE&&!rsp_valid?DRAIN:FLUSH;
            end else case(state)
                IDLE: if(start_valid&&start_ready) begin
                    done_tag<=start_tag;base<=start_base;address<=start_base;count<=start_count;
                    done_count<=0;done_reason<=0;done_error<=0;cancelled<=0;state<=CHECK;
                end
                CHECK: if(base[4:0]!=0||count==0||count>1048576||program_end>38'h100000000) begin done_reason<=1;state<=FLUSH;end else state<=CLEAR;
                CLEAR: state<=FETCH;
                FETCH: if(rd_ready) state<=RECEIVE;
                RECEIVE: if(rsp_valid) begin
                    if(rsp_error) begin done_reason<=2;state<=FLUSH;end
                    else begin instruction<=rsp_data;state<=ISSUE;end
                end
                ISSUE: if(ex_ready) state<=EXECUTE;
                EXECUTE: if(ex_done) begin
                    if(cancelled||cancel) begin done_reason<=4;done_error<=ex_error;state<=FLUSH;end
                    else if(ex_tag!=instruction[251:220]) begin done_reason<=5;done_error<=ex_error;state<=FLUSH;end
                    else if(ex_error!=0) begin done_reason<=3;done_error<=ex_error;state<=FLUSH;end
                    else begin done_count<=done_count+1;state<=NEXT;end
                end
                NEXT: if(done_count==count) state<=DONE;else begin address<=address+32;state<=FETCH;end
                DRAIN: if(rsp_valid) state<=FLUSH;
                FLUSH: state<=DONE;
                DONE: if(done_ready&&!cancel) state<=IDLE;
                default: begin done_reason<=15;state<=FLUSH;end
            endcase
        end
    end
endmodule
`default_nettype wire
