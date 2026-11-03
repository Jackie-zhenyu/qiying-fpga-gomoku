`timescale 1ns/1ps
`default_nettype none
// Read-only GD25Q256D: opcode13 with explicit 32-bit address, SPI mode0.
// Default 100MHz / (2*8) = 6.25MHz. No erase/program/status-write opcode.
// At least four source clocks per half-period allow two MISO synchronizers.
// Configuration CCLK must be released as ordinary IO after FPGA startup.
module qy_flash_read13 #(parameter integer HALF_CYCLES=8) (
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [31:0] cmd_address,input wire [31:0] cmd_length,
    output wire m_valid,input wire m_ready,output reg [7:0] m_data,output reg m_last,
    output wire done_valid,input wire done_ready,output reg [31:0] done_tag,output reg [7:0] done_error,
    output reg spi_cs_n,output reg spi_clk,output reg spi_mosi,input wire spi_miso
);
    localparam [2:0] IDLE=0,CHECK=1,COMMAND=2,DATA=3,HOLD=4,RELEASE=5,DONE=6;
    reg [2:0] state;
    reg [31:0] address,length,received;
    reg [39:0] command;
    reg [5:0] bit_index;
    reg [15:0] timer;
    reg [7:0] shift;
    (* ASYNC_REG="TRUE" *) reg miso_meta,miso_sync;
    wire [32:0] end_address={1'b0,address}+{1'b0,length};
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign m_valid=!rst&&!cancel&&state==HOLD;
    assign done_valid=!rst&&!cancel&&state==DONE;
    always @(posedge clk) begin
        miso_meta<=spi_miso;miso_sync<=miso_meta;
        if(rst) begin
            state<=IDLE;address<=0;length<=0;received<=0;command<=0;bit_index<=0;timer<=0;shift<=0;
            m_data<=0;m_last<=0;done_tag<=0;done_error<=0;spi_cs_n<=1;spi_clk<=0;spi_mosi<=0;
        end else if(cancel&&state!=IDLE&&state!=DONE) begin
            spi_cs_n<=1;spi_clk<=0;spi_mosi<=0;done_error<=8'h80;timer<=HALF_CYCLES-1;state<=RELEASE;
        end else case(state)
            IDLE:if(cmd_valid&&cmd_ready) begin
                address<=cmd_address;length<=cmd_length;received<=0;done_tag<=cmd_tag;done_error<=0;
                m_data<=0;m_last<=0;command<={8'h13,cmd_address};bit_index<=0;shift<=0;state<=CHECK;
            end
            CHECK:if(HALF_CYCLES<4||HALF_CYCLES>65535||length==0||end_address>33554432) begin done_error<=1;state<=DONE;end
                else begin spi_cs_n<=0;spi_clk<=0;spi_mosi<=command[39];timer<=HALF_CYCLES-1;state<=COMMAND;end
            COMMAND:if(timer!=0) timer<=timer-1'b1;
                else begin
                    timer<=HALF_CYCLES-1;
                    if(!spi_clk) spi_clk<=1;
                    else begin
                        spi_clk<=0;command<={command[38:0],1'b0};spi_mosi<=command[38];
                        if(bit_index==39) begin bit_index<=0;spi_mosi<=0;state<=DATA;end else bit_index<=bit_index+1'b1;
                    end
                end
            DATA:if(timer!=0) timer<=timer-1'b1;
                else begin
                    timer<=HALF_CYCLES-1;
                    if(!spi_clk) begin spi_clk<=1;shift<={shift[6:0],miso_sync};end
                    else begin
                        spi_clk<=0;
                        if(bit_index==7) begin bit_index<=0;m_data<=shift;m_last<=received==length-1'b1;state<=HOLD;end
                        else bit_index<=bit_index+1'b1;
                    end
                end
            HOLD:if(m_ready) begin
                received<=received+1'b1;
                if(m_last) begin spi_cs_n<=1;spi_mosi<=0;timer<=HALF_CYCLES-1;state<=RELEASE;end
                else begin timer<=HALF_CYCLES-1;state<=DATA;end
            end
            RELEASE:if(timer!=0) timer<=timer-1'b1;else state<=DONE;
            DONE:if(done_ready) state<=IDLE;
            default:begin spi_cs_n<=1;spi_clk<=0;done_error<=2;state<=DONE;end
        endcase
    end
endmodule
`default_nettype wire
