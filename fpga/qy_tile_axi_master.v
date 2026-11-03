`timescale 1ns/1ps
`default_nettype none
// Bridge the tile DMA's aligned 32-byte transactions to AXI4. Read and write
// channels are independent, with at most one transaction in flight each.
// rst MUST share the downstream AXI reset/flush domain. Task cancellation is
// handled upstream by draining replies; it must not reset this bridge alone.
module qy_tile_axi_master #(parameter [3:0] AXI_ID=4'd8)(
    input wire clk,rst,
    input wire rd_valid,output wire rd_ready,input wire [31:0] rd_addr,
    output wire rsp_valid,input wire rsp_ready,output reg [255:0] rsp_data,output reg rsp_error,
    input wire wr_valid,output wire wr_ready,input wire [31:0] wr_addr,
    input wire [255:0] wr_data,input wire [31:0] wr_strobe,
    output wire ack_valid,input wire ack_ready,output reg ack_error,
    output wire arvalid,input wire arready,output reg [31:0] araddr,
    output wire [3:0] arid,output wire [7:0] arlen,output wire [2:0] arsize,output wire [1:0] arburst,
    input wire rvalid,output wire rready,input wire [255:0] rdata,
    input wire [3:0] rid,input wire [1:0] rresp,input wire rlast,
    output wire awvalid,input wire awready,output reg [31:0] awaddr,
    output wire [3:0] awid,output wire [7:0] awlen,output wire [2:0] awsize,output wire [1:0] awburst,
    output wire wvalid,input wire wready,output reg [255:0] wdata,output reg [31:0] wstrb,output wire wlast,
    input wire bvalid,output wire bready,input wire [3:0] bid,input wire [1:0] bresp
);
    localparam [2:0] R_IDLE=0,R_ADDR=1,R_DATA=2,R_DRAIN=3,R_DONE=4;
    localparam [1:0] W_IDLE=0,W_SEND=1,W_REPLY=2,W_DONE=3;
    reg [2:0] rs;reg [1:0] ws;reg aw_sent,w_sent;
    assign rd_ready=!rst&&rs==R_IDLE;assign wr_ready=!rst&&ws==W_IDLE;
    assign rsp_valid=!rst&&rs==R_DONE;assign ack_valid=!rst&&ws==W_DONE;
    assign arvalid=!rst&&rs==R_ADDR;assign rready=!rst&&(rs==R_DATA||rs==R_DRAIN);
    assign awvalid=!rst&&ws==W_SEND&&!aw_sent;assign wvalid=!rst&&ws==W_SEND&&!w_sent;
    assign bready=!rst&&ws==W_REPLY;
    assign arid=AXI_ID;assign awid=AXI_ID;assign arlen=0;assign awlen=0;
    assign arsize=3'd5;assign awsize=3'd5;assign arburst=2'b01;assign awburst=2'b01;assign wlast=1'b1;
    always @(posedge clk) begin
        if(rst) begin
            rs<=R_IDLE;araddr<=0;rsp_data<=0;rsp_error<=0;
        end else case(rs)
            R_IDLE: if(rd_valid) begin
                araddr<=rd_addr;rsp_data<=0;rsp_error<=rd_addr[4:0]!=0;
                rs<=(rd_addr[4:0]!=0)?R_DONE:R_ADDR;
            end
            R_ADDR: if(arready) rs<=R_DATA;
            R_DATA: if(rvalid) begin
                rsp_data<=rdata;rsp_error<=(rid!=AXI_ID)||(rresp!=0)||!rlast;
                rs<=rlast?R_DONE:R_DRAIN;
            end
            R_DRAIN: if(rvalid&&rlast) rs<=R_DONE;
            R_DONE: if(rsp_ready) rs<=R_IDLE;
            default: rs<=R_IDLE;
        endcase
    end
    always @(posedge clk) begin
        if(rst) begin
            ws<=W_IDLE;awaddr<=0;wdata<=0;wstrb<=0;aw_sent<=0;w_sent<=0;ack_error<=0;
        end else case(ws)
            W_IDLE: if(wr_valid) begin
                awaddr<=wr_addr;wdata<=wr_data;wstrb<=wr_strobe;aw_sent<=0;w_sent<=0;
                ack_error<=(wr_addr[4:0]!=0)||(wr_strobe==0);
                ws<=((wr_addr[4:0]!=0)||(wr_strobe==0))?W_DONE:W_SEND;
            end
            W_SEND: begin
                if(awvalid&&awready) aw_sent<=1;
                if(wvalid&&wready) w_sent<=1;
                if((aw_sent||awready)&&(w_sent||wready)) ws<=W_REPLY;
            end
            W_REPLY: if(bvalid) begin ack_error<=(bid!=AXI_ID)||(bresp!=0);ws<=W_DONE;end
            W_DONE: if(ack_ready) ws<=W_IDLE;
            default: ws<=W_IDLE;
        endcase
    end
endmodule
`default_nettype wire
