`timescale 1ns/1ps
`default_nettype none
// Autonomous boot -> immutable frame lease -> full frozen NN -> repeat.
// Runs at 100MHz; all DDR/lease interfaces below share this clock. The board
// wrapper supplies paired-reset mailboxes to the DDR UI clock. No PC service.
module qy_yolo_runtime #(
    parameter [31:0] INPUT_BASE=32'h08000000,PROGRAM_BASE=32'h0b000000,PROGRAM_WORDS=840259,
    parameter [95:0] CLASS_BASES=0,BOX_BASES=0,parameter [191:0] COORD_BASES=0,
    parameter [31:0] HEADER_ADDRESS=32'h00a00000,
    parameter [127:0] FLASH_ADDRESSES=0,DDR_ADDRESSES=0,LENGTHS=0,CRCS=0,
    parameter [127:0] DDR_LENGTHS=0,DDR_CRCS=0,
    parameter integer RETRY_CYCLES=100000000,ENABLE_PREVIEW=0
)(
    input wire clk,input wire rst,
    output wire lease_req_valid,input wire lease_req_ready,output wire [31:0] lease_req_tag,
    input wire lease_valid,output wire lease_ready,input wire [31:0] lease_tag,lease_frame,lease_base,input wire [7:0] lease_status,
    output wire release_valid,input wire release_ready,output wire [31:0] release_tag,
    input wire release_ack,output wire release_ack_ready,
    output wire result_valid,input wire result_ready,output wire [31:0] result_tag,
    output wire [8:0] result_index,output wire [191:0] result_data,output wire result_last,
    output wire job_start,output wire job_done,output wire job_success,output wire [31:0] job_frame,job_tag,
    output wire [3:0] phase,boot_phase,engine_phase,output wire [1:0] boot_asset,
    output wire model_ready,output reg [15:0] last_error,output reg [31:0] completed_jobs,
    input wire preview_ready,output wire preview_valid,output wire [9:0] preview_x,preview_y,output wire [15:0] preview_rgb565,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strb,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire spi_cs_n,spi_clk,spi_mosi,input wire spi_miso
);
    localparam [3:0] BOOT_START=0,BOOT_WAIT=1,REQUEST=2,RESPONSE=3,START=4,RUN=5,
        BAD_RELEASE=6,RELEASE_ACK=7,RETRY=8,BOOT_FAILED=9,VERIFY_START=10,VERIFY_WAIT=11;
    reg [3:0] state;reg [31:0] tag,frame,base,retry_count;reg release_sent;
    wire boot_start_ready,boot_done,boot_wr,boot_ack_ready;
    wire [31:0] boot_tag,boot_addr,boot_strb;wire [15:0] boot_error;wire [255:0] boot_data;
    wire boot_owner=state==BOOT_START||state==BOOT_WAIT;
    wire boot_model_ready;reg verified_model;
    assign model_ready=verified_model;
    qy_model_boot #(.HEADER_ADDRESS(HEADER_ADDRESS),.FLASH_ADDRESSES(FLASH_ADDRESSES),.DDR_ADDRESSES(DDR_ADDRESSES),.LENGTHS(LENGTHS),.CRCS(CRCS)) boot(
        .clk(clk),.rst(rst),.cancel(1'b0),.start_valid(state==BOOT_START),.start_ready(boot_start_ready),.start_tag(32'h594e0001),
        .done_valid(boot_done),.done_ready(state==BOOT_WAIT),.done_tag(boot_tag),.done_error(boot_error),
        .model_ready(boot_model_ready),.progress(boot_phase),.asset_index(boot_asset),
        .wr_valid(boot_wr),.wr_ready(boot_owner&&wr_ready),.wr_addr(boot_addr),.wr_data(boot_data),.wr_strb(boot_strb),
        .ack_valid(boot_owner&&ack_valid),.ack_ready(boot_ack_ready),.ack_error(ack_error),
        .spi_cs_n(spi_cs_n),.spi_clk(spi_clk),.spi_mosi(spi_mosi),.spi_miso(spi_miso));
    wire engine_ready,engine_done,engine_release,engine_wr,engine_ack_ready;
    wire start_allowed=ENABLE_PREVIEW?preview_ready:1'b1;
    wire engine_rd,engine_rsp_ready,verify_start_ready,verify_done,verify_rd,verify_rsp_ready;
    wire [31:0] engine_rd_addr,verify_rd_addr;wire [7:0] verify_error;wire [1:0] verify_asset;
    wire verify_owner=state==VERIFY_START||state==VERIFY_WAIT;
    qy_ddr_asset_verify #(.BASES(DDR_ADDRESSES),.LENGTHS(DDR_LENGTHS),.CRCS(DDR_CRCS)) verify_assets(
        .clk(clk),.rst(rst),.start_valid(state==VERIFY_START),.start_ready(verify_start_ready),
        .done_valid(verify_done),.done_ready(state==VERIFY_WAIT),.done_error(verify_error),.asset_index(verify_asset),
        .rd_valid(verify_rd),.rd_ready(verify_owner&&rd_ready),.rd_addr(verify_rd_addr),
        .rsp_valid(verify_owner&&rsp_valid),.rsp_ready(verify_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error));
    wire [31:0] engine_tag,engine_release_tag,engine_addr,engine_strb;wire [15:0] engine_error;wire [3:0] engine_stage;wire [255:0] engine_data;
    qy_yolo_engine #(.INPUT_BASE(INPUT_BASE),.PROGRAM_BASE(PROGRAM_BASE),.PROGRAM_WORDS(PROGRAM_WORDS),.CLASS_BASES(CLASS_BASES),.BOX_BASES(BOX_BASES),.COORD_BASES(COORD_BASES)) engine(
        .clk(clk),.rst(rst),.cancel(1'b0),.model_ready(model_ready),.start_valid(state==START&&start_allowed),.start_ready(engine_ready),.start_tag(tag),.start_frame_base(base),
        .preview_valid(preview_valid),.preview_x(preview_x),.preview_y(preview_y),.preview_rgb565(preview_rgb565),
        .frame_release_valid(engine_release),.frame_release_ready(release_sent&&release_ack),.frame_release_tag(engine_release_tag),
        .result_valid(result_valid),.result_ready(result_ready),.result_tag(result_tag),.result_index(result_index),.result_data(result_data),.result_last(result_last),
        .done_valid(engine_done),.done_ready(state==RUN),.done_tag(engine_tag),.done_stage(engine_stage),.done_error(engine_error),.progress(engine_phase),
        .rd_valid(engine_rd),.rd_ready(!verify_owner&&rd_ready),.rd_addr(engine_rd_addr),.rsp_valid(!verify_owner&&rsp_valid),.rsp_ready(engine_rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),
        .wr_valid(engine_wr),.wr_ready(!boot_owner&&wr_ready),.wr_addr(engine_addr),.wr_data(engine_data),.wr_strb(engine_strb),
        .ack_valid(!boot_owner&&ack_valid),.ack_ready(engine_ack_ready),.ack_error(ack_error));
    assign phase=state;assign job_frame=frame;assign job_tag=tag;
    assign rd_valid=verify_owner?verify_rd:engine_rd;assign rd_addr=verify_owner?verify_rd_addr:engine_rd_addr;
    assign rsp_ready=verify_owner?verify_rsp_ready:engine_rsp_ready;
    assign job_start=state==START&&engine_ready&&start_allowed;
    assign job_done=state==RUN&&engine_done;
    assign job_success=job_done&&engine_error==0&&engine_tag==tag&&engine_stage==0;
    assign lease_req_valid=!rst&&state==REQUEST;assign lease_req_tag=tag;assign lease_ready=!rst&&state==RESPONSE;
    assign release_valid=!rst&&!release_sent&&(state==BAD_RELEASE||(state==RUN&&engine_release));
    assign release_tag=tag;assign release_ack_ready=!rst&&release_sent&&(state==RUN||state==RELEASE_ACK);
    assign wr_valid=!rst&&(boot_owner?boot_wr:engine_wr);assign wr_addr=boot_owner?boot_addr:engine_addr;
    assign wr_data=boot_owner?boot_data:engine_data;assign wr_strb=boot_owner?boot_strb:engine_strb;assign ack_ready=boot_owner?boot_ack_ready:engine_ack_ready;
    always @(posedge clk) begin
        if(rst) begin state<=BOOT_START;tag<=1;frame<=0;base<=0;retry_count<=0;release_sent<=0;last_error<=0;completed_jobs<=0;verified_model<=0;end
        else begin
            if(release_valid&&release_ready) release_sent<=1;
            case(state)
                BOOT_START:if(boot_start_ready) state<=BOOT_WAIT;
                BOOT_WAIT:if(boot_done) begin
                    if(boot_error!=0||boot_tag!=32'h594e0001||!boot_model_ready) begin last_error<=boot_error!=0?boot_error:16'h4000;state<=BOOT_FAILED;end
                    else state<=VERIFY_START;
                end
                VERIFY_START:if(verify_start_ready) state<=VERIFY_WAIT;
                VERIFY_WAIT:if(verify_done) begin
                    if(verify_error!=0) begin last_error<={6'b001100,verify_asset,verify_error};state<=BOOT_FAILED;end
                    else begin verified_model<=1;state<=REQUEST;end
                end
                REQUEST:if(lease_req_ready) state<=RESPONSE;
                RESPONSE:if(lease_valid) begin
                    frame<=lease_frame;base<=lease_base;release_sent<=0;
                    if(lease_status!=0||lease_tag!=tag) begin last_error<=lease_tag!=tag?16'h4000:{8'h10,lease_status};state<=BAD_RELEASE;end
                    else state<=START;
                end
                START:if(engine_ready&&start_allowed) state<=RUN;
                RUN:if(engine_done) begin
                    last_error<=engine_tag!=tag?16'h4000:engine_error;
                    if(job_success) completed_jobs<=completed_jobs+1'b1;
                    retry_count<=0;state<=RETRY;
                end
                BAD_RELEASE:if(release_valid&&release_ready) state<=RELEASE_ACK;
                RELEASE_ACK:if(release_ack) begin retry_count<=0;state<=RETRY;end
                RETRY:if(retry_count==RETRY_CYCLES-1) begin
                    if(tag==32'hffffffff) begin last_error<=16'h2000;state<=BOOT_FAILED;end
                    else begin tag<=tag+1'b1;state<=REQUEST;end
                end else retry_count<=retry_count+1'b1;
                BOOT_FAILED:state<=BOOT_FAILED;
                default:begin last_error<=16'h8000;state<=BOOT_FAILED;end
            endcase
        end
    end
endmodule
`default_nettype wire
