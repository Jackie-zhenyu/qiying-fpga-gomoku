`timescale 1ns/1ps
`default_nettype none
// Four frozen assets: compressed program, weights, bridge LUTs, coordinates.
// Header/addresses/lengths/CRCs are bound into the FPGA image, never accepted
// as arbitrary write addresses from Flash. model_ready is the sole publication
// event after every CRC and DDR write response succeeds. Shared bus reset only.
module qy_model_boot #(
    parameter HEADER_FILE="yolo_boot_header.hex",parameter [31:0] HEADER_ADDRESS=32'h00a00000,
    parameter [127:0] FLASH_ADDRESSES=0,DDR_ADDRESSES=0,LENGTHS=0,CRCS=0,
    parameter integer SPI_HALF_CYCLES=8
)(
    input wire clk,input wire rst,input wire cancel,
    input wire start_valid,output wire start_ready,input wire [31:0] start_tag,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,output reg [15:0] done_error,
    output reg model_ready,output wire [3:0] progress,output wire [1:0] asset_index,
    output wire wr_valid,input wire wr_ready,output wire [31:0] wr_addr,
    output wire [255:0] wr_data,output wire [31:0] wr_strb,
    input wire ack_valid,output wire ack_ready,input wire ack_error,
    output wire spi_cs_n,output wire spi_clk,output wire spi_mosi,input wire spi_miso
);
    localparam [3:0] IDLE=0,HEADER_START=1,HEADER_RUN=2,HEADER_FINISH=3,
        ASSET_START=4,ASSET_RUN=5,ASSET_FINISH=6,COMPLETE=7,ABORT=8,DONE=9;
    reg [3:0] state;reg [1:0] asset;reg [7:0] header_index;
    reg spi_started,worker_started,spi_finished,worker_finished,abort_issued,header_finished;
    reg [31:0] asset_crc,asset_received;
    reg [7:0] header[0:143];initial $readmemh(HEADER_FILE,header);
    wire [31:0] flash_address=FLASH_ADDRESSES[asset*32+:32],ddr_address=DDR_ADDRESSES[asset*32+:32];
    wire [31:0] length=LENGTHS[asset*32+:32],expected_crc=CRCS[asset*32+:32];
    wire abort_pulse=state==ABORT&&!abort_issued;
    wire spi_cmd_ready,byte_valid,byte_last,spi_done;wire [7:0] byte_data,spi_error;wire [31:0] spi_tag;
    wire exp_ready,exp_s_ready,exp_done,exp_wr,exp_ack_ready;wire [31:0] exp_tag,exp_words,exp_addr,exp_strb;wire [255:0] exp_data;wire [7:0] exp_error;
    wire copy_ready,copy_s_ready,copy_done,copy_wr,copy_ack_ready;wire [31:0] copy_tag,copy_addr,copy_strb;wire [255:0] copy_data;wire [7:0] copy_error;
    wire worker_ready=asset==0?exp_ready:copy_ready,worker_done=asset==0?exp_done:copy_done;
    wire [7:0] worker_error=asset==0?exp_error:copy_error;wire [31:0] worker_tag=asset==0?exp_tag:copy_tag;
    wire byte_ready=!cancel&&((state==HEADER_RUN&&!header_finished)||(state==ASSET_RUN&&(asset==0?exp_s_ready:copy_s_ready)));
    wire worker_response_ready=state==ASSET_RUN||state==ABORT;
    qy_flash_read13 #(.HALF_CYCLES(SPI_HALF_CYCLES)) reader(
        .clk(clk),.rst(rst),.cancel(abort_pulse&&spi_started&&!spi_finished),
        .cmd_valid(!cancel&&(state==HEADER_START||state==ASSET_START)&&!spi_started),.cmd_ready(spi_cmd_ready),.cmd_tag(done_tag),
        .cmd_address(state==HEADER_START?HEADER_ADDRESS:flash_address),.cmd_length(state==HEADER_START?32'd144:length),
        .m_valid(byte_valid),.m_ready(byte_ready),.m_data(byte_data),.m_last(byte_last),
        .done_valid(spi_done),.done_ready(state==HEADER_RUN||state==ASSET_RUN||state==ABORT),.done_tag(spi_tag),.done_error(spi_error),
        .spi_cs_n(spi_cs_n),.spi_clk(spi_clk),.spi_mosi(spi_mosi),.spi_miso(spi_miso));
    qy_program_expand expand(
        .clk(clk),.rst(rst),.cancel(abort_pulse&&worker_started&&!worker_finished&&asset==0),
        .cmd_valid(!cancel&&state==ASSET_START&&!worker_started&&asset==0),.cmd_ready(exp_ready),.cmd_tag(done_tag),.cmd_base(ddr_address),.cmd_encoded_bytes(length),
        .s_valid(!cancel&&state==ASSET_RUN&&asset==0&&byte_valid),.s_ready(exp_s_ready),.s_data(byte_data),.s_last(byte_last),.s_error(1'b0),
        .wr_valid(exp_wr),.wr_ready(asset==0&&wr_ready),.wr_addr(exp_addr),.wr_data(exp_data),.wr_strb(exp_strb),
        .b_valid(asset==0&&ack_valid),.b_ready(exp_ack_ready),.b_error(ack_error),
        .done_valid(exp_done),.done_ready(worker_response_ready&&asset==0),.done_tag(exp_tag),.done_words(exp_words),.done_error(exp_error));
    qy_stream_to_ddr copier(
        .clk(clk),.rst(rst),.cancel(abort_pulse&&worker_started&&!worker_finished&&asset!=0),
        .cmd_valid(!cancel&&state==ASSET_START&&!worker_started&&asset!=0),.cmd_ready(copy_ready),.cmd_tag(done_tag),.cmd_base(ddr_address),.cmd_length(length),.cmd_crc(expected_crc),
        .s_valid(!cancel&&state==ASSET_RUN&&asset!=0&&byte_valid),.s_ready(copy_s_ready),.s_data(byte_data),.s_last(byte_last),
        .wr_valid(copy_wr),.wr_ready(asset!=0&&wr_ready),.wr_addr(copy_addr),.wr_data(copy_data),.wr_strb(copy_strb),
        .ack_valid(asset!=0&&ack_valid),.ack_ready(copy_ack_ready),.ack_error(ack_error),
        .done_valid(copy_done),.done_ready(worker_response_ready&&asset!=0),.done_tag(copy_tag),.done_error(copy_error));
    assign start_ready=!rst&&!cancel&&state==IDLE;assign done_valid=!rst&&!cancel&&state==DONE;assign progress=state;assign asset_index=asset;
    assign wr_valid=!rst&&worker_started&&(asset==0?exp_wr:copy_wr);assign wr_addr=asset==0?exp_addr:copy_addr;
    assign wr_data=asset==0?exp_data:copy_data;assign wr_strb=asset==0?exp_strb:copy_strb;assign ack_ready=!rst&&worker_started&&(asset==0?exp_ack_ready:copy_ack_ready);
    function [31:0] crc_byte(input [31:0] old,input [7:0] data);
        integer i;reg [31:0] c;begin c=old^{24'd0,data};for(i=0;i<8;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;asset<=0;header_index<=0;spi_started<=0;worker_started<=0;spi_finished<=0;worker_finished<=0;
            abort_issued<=0;header_finished<=0;asset_crc<=0;asset_received<=0;done_tag<=0;done_error<=0;model_ready<=0;
        end else begin
            if((state==HEADER_START||state==ASSET_START)&&!spi_started&&spi_cmd_ready&&!cancel) spi_started<=1;
            if(state==ASSET_START&&!worker_started&&worker_ready&&!cancel) worker_started<=1;
            if(spi_done&&(state==HEADER_RUN||state==ASSET_RUN||state==ABORT)) spi_finished<=1;
            if(worker_done&&worker_response_ready) worker_finished<=1;
            if(state==ASSET_RUN&&byte_valid&&byte_ready) begin asset_crc<=crc_byte(asset_crc,byte_data);asset_received<=asset_received+1'b1;end
            if(cancel&&state!=IDLE&&state!=DONE&&state!=ABORT) begin done_error<=16'h8000;state<=ABORT;end
            else if(state!=ABORT&&spi_done&&(state==HEADER_RUN||state==ASSET_RUN)&&(spi_error!=0||spi_tag!=done_tag)) begin done_error<=16'h0100|{8'd0,spi_error};state<=ABORT;end
            else if(state==ASSET_RUN&&worker_done&&(worker_error!=0||worker_tag!=done_tag)) begin done_error<=16'h0200|{8'd0,worker_error};state<=ABORT;end
            else case(state)
                IDLE:if(start_valid&&start_ready) begin
                    done_tag<=start_tag;done_error<=0;model_ready<=0;asset<=0;header_index<=0;
                    spi_started<=0;worker_started<=0;spi_finished<=0;worker_finished<=0;header_finished<=0;abort_issued<=0;state<=HEADER_START;
                end
                HEADER_START:if(spi_started||spi_cmd_ready) state<=HEADER_RUN;
                HEADER_RUN:begin
                    if(byte_valid&&byte_ready) begin
                        if(byte_data!==header[header_index]||byte_last!=(header_index==143)) begin done_error<=1;state<=ABORT;end
                        else if(header_index==143) header_finished<=1;else header_index<=header_index+1'b1;
                    end
                    if(spi_finished) state<=HEADER_FINISH;
                end
                HEADER_FINISH:if(!header_finished) begin done_error<=2;state<=ABORT;end
                    else begin spi_started<=0;spi_finished<=0;worker_started<=0;worker_finished<=0;asset_crc<=32'hffffffff;asset_received<=0;state<=ASSET_START;end
                ASSET_START:if((spi_started||spi_cmd_ready)&&(worker_started||worker_ready)) state<=ASSET_RUN;
                ASSET_RUN:if(spi_finished&&worker_finished) state<=ASSET_FINISH;
                ASSET_FINISH:if(asset_received!=length||(~asset_crc)!=expected_crc) begin done_error<=4;state<=ABORT;end
                    else if(asset==3) state<=COMPLETE;
                    else begin asset<=asset+1'b1;spi_started<=0;worker_started<=0;spi_finished<=0;worker_finished<=0;asset_crc<=32'hffffffff;asset_received<=0;state<=ASSET_START;end
                COMPLETE:begin model_ready<=1;state<=DONE;end
                ABORT:begin
                    abort_issued<=1;model_ready<=0;
                    if((!spi_started||spi_finished)&&(!worker_started||worker_finished)) state<=DONE;
                end
                DONE:if(done_ready&&!cancel) state<=IDLE;
                default:begin done_error<=16'h4000;state<=ABORT;end
            endcase
        end
    end
endmodule
`default_nettype wire
