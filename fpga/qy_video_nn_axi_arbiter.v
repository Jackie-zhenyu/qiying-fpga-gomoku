`timescale 1ns/1ps
`default_nettype none
// One burst per direction; AXI write ownership is held through B.
// Video is preferred, with at most 8 consecutive video grants while
// NN waits. Read and write progress independently. Only address
// acceptance can change owner; every response returns to that owner.
// IDs are preserved, checked, and never used to misroute an error.
// rst shares the downstream AXI reset; cancellation drains upstream.
module qy_video_nn_axi_arbiter (
    input wire clk,input wire rst,output reg protocol_fault,
    input wire [31:0] v_awaddr,
    input wire [3:0] v_awid,
    input wire [7:0] v_awlen,
    input wire [2:0] v_awsize,
    input wire [1:0] v_awburst,
    input wire v_awlock,
    input wire [3:0] v_awcache,
    input wire [2:0] v_awprot,
    input wire [3:0] v_awqos,
    input wire v_awvalid,
    input wire [255:0] v_wdata,
    input wire [31:0] v_wstrb,
    input wire v_wlast,
    input wire v_wvalid,
    input wire [31:0] v_araddr,
    input wire [3:0] v_arid,
    input wire [7:0] v_arlen,
    input wire [2:0] v_arsize,
    input wire [1:0] v_arburst,
    input wire v_arlock,
    input wire [3:0] v_arcache,
    input wire [2:0] v_arprot,
    input wire [3:0] v_arqos,
    input wire v_arvalid,
    input wire v_rready,
    input wire v_bready,
    output wire v_awready,
    output wire v_wready,
    output wire v_arready,
    output wire [255:0] v_rdata,
    output wire [3:0] v_rid,
    output wire [1:0] v_rresp,
    output wire v_rlast,
    output wire v_rvalid,
    output wire [3:0] v_bid,
    output wire [1:0] v_bresp,
    output wire v_bvalid,
    input wire [31:0] n_awaddr,
    input wire [3:0] n_awid,
    input wire [7:0] n_awlen,
    input wire [2:0] n_awsize,
    input wire [1:0] n_awburst,
    input wire n_awlock,
    input wire [3:0] n_awcache,
    input wire [2:0] n_awprot,
    input wire [3:0] n_awqos,
    input wire n_awvalid,
    input wire [255:0] n_wdata,
    input wire [31:0] n_wstrb,
    input wire n_wlast,
    input wire n_wvalid,
    input wire [31:0] n_araddr,
    input wire [3:0] n_arid,
    input wire [7:0] n_arlen,
    input wire [2:0] n_arsize,
    input wire [1:0] n_arburst,
    input wire n_arlock,
    input wire [3:0] n_arcache,
    input wire [2:0] n_arprot,
    input wire [3:0] n_arqos,
    input wire n_arvalid,
    input wire n_rready,
    input wire n_bready,
    output wire n_awready,
    output wire n_wready,
    output wire n_arready,
    output wire [255:0] n_rdata,
    output wire [3:0] n_rid,
    output wire [1:0] n_rresp,
    output wire n_rlast,
    output wire n_rvalid,
    output wire [3:0] n_bid,
    output wire [1:0] n_bresp,
    output wire n_bvalid,
    output wire [31:0] m_awaddr,
    output wire [3:0] m_awid,
    output wire [7:0] m_awlen,
    output wire [2:0] m_awsize,
    output wire [1:0] m_awburst,
    output wire m_awlock,
    output wire [3:0] m_awcache,
    output wire [2:0] m_awprot,
    output wire [3:0] m_awqos,
    output wire m_awvalid,
    output wire [255:0] m_wdata,
    output wire [31:0] m_wstrb,
    output wire m_wlast,
    output wire m_wvalid,
    output wire [31:0] m_araddr,
    output wire [3:0] m_arid,
    output wire [7:0] m_arlen,
    output wire [2:0] m_arsize,
    output wire [1:0] m_arburst,
    output wire m_arlock,
    output wire [3:0] m_arcache,
    output wire [2:0] m_arprot,
    output wire [3:0] m_arqos,
    output wire m_arvalid,
    output wire m_rready,
    output wire m_bready,
    input wire m_awready,
    input wire m_wready,
    input wire m_arready,
    input wire [255:0] m_rdata,
    input wire [3:0] m_rid,
    input wire [1:0] m_rresp,
    input wire m_rlast,
    input wire m_rvalid,
    input wire [3:0] m_bid,
    input wire [1:0] m_bresp,
    input wire m_bvalid
);
    reg [1:0] rs,ws;reg ro,wo;reg [3:0] rq,wq;
    reg [3:0] read_id,write_id;reg [7:0] read_len,write_len,read_beat,write_beat;
    wire read_bad=(m_rid!=read_id)||(m_rlast!=(read_beat==read_len));
    wire write_bad=(m_bid!=write_id);
    assign v_awready=!rst&&ws==1&&wo==0&&m_awready;
    assign v_wready=!rst&&ws==2&&wo==0&&m_wready;
    assign v_arready=!rst&&rs==1&&ro==0&&m_arready;
    assign v_rdata=m_rdata;
    assign v_rid=m_rid;
    assign v_rresp=read_bad?2'b10:m_rresp;
    assign v_rlast=m_rlast;
    assign v_rvalid=!rst&&rs==2&&ro==0&&m_rvalid;
    assign v_bid=m_bid;
    assign v_bresp=write_bad?2'b10:m_bresp;
    assign v_bvalid=!rst&&ws==3&&wo==0&&m_bvalid;
    assign n_awready=!rst&&ws==1&&wo==1&&m_awready;
    assign n_wready=!rst&&ws==2&&wo==1&&m_wready;
    assign n_arready=!rst&&rs==1&&ro==1&&m_arready;
    assign n_rdata=m_rdata;
    assign n_rid=m_rid;
    assign n_rresp=read_bad?2'b10:m_rresp;
    assign n_rlast=m_rlast;
    assign n_rvalid=!rst&&rs==2&&ro==1&&m_rvalid;
    assign n_bid=m_bid;
    assign n_bresp=write_bad?2'b10:m_bresp;
    assign n_bvalid=!rst&&ws==3&&wo==1&&m_bvalid;
    assign m_awaddr=(wo?n_awaddr:v_awaddr);
    assign m_awid=(wo?n_awid:v_awid);
    assign m_awlen=(wo?n_awlen:v_awlen);
    assign m_awsize=(wo?n_awsize:v_awsize);
    assign m_awburst=(wo?n_awburst:v_awburst);
    assign m_awlock=(wo?n_awlock:v_awlock);
    assign m_awcache=(wo?n_awcache:v_awcache);
    assign m_awprot=(wo?n_awprot:v_awprot);
    assign m_awqos=(wo?n_awqos:v_awqos);
    assign m_awvalid=!rst&&ws==1&&(wo?n_awvalid:v_awvalid);
    assign m_wdata=(wo?n_wdata:v_wdata);
    assign m_wstrb=(wo?n_wstrb:v_wstrb);
    assign m_wlast=(wo?n_wlast:v_wlast);
    assign m_wvalid=!rst&&ws==2&&(wo?n_wvalid:v_wvalid);
    assign m_araddr=(ro?n_araddr:v_araddr);
    assign m_arid=(ro?n_arid:v_arid);
    assign m_arlen=(ro?n_arlen:v_arlen);
    assign m_arsize=(ro?n_arsize:v_arsize);
    assign m_arburst=(ro?n_arburst:v_arburst);
    assign m_arlock=(ro?n_arlock:v_arlock);
    assign m_arcache=(ro?n_arcache:v_arcache);
    assign m_arprot=(ro?n_arprot:v_arprot);
    assign m_arqos=(ro?n_arqos:v_arqos);
    assign m_arvalid=!rst&&rs==1&&(ro?n_arvalid:v_arvalid);
    assign m_rready=!rst&&rs==2&&(ro?n_rready:v_rready);
    assign m_bready=!rst&&ws==3&&(wo?n_bready:v_bready);
    always @(posedge clk) begin
        if(rst) begin
            rs<=0;ws<=0;ro<=0;wo<=0;rq<=0;wq<=0;read_id<=0;write_id<=0;
            read_len<=0;write_len<=0;read_beat<=0;write_beat<=0;protocol_fault<=0;
        end else begin
            case(rs)
                0:if(v_arvalid||n_arvalid) begin ro<=n_arvalid&&(!v_arvalid||rq>=8);rs<=1;end
                1:if(m_arvalid&&m_arready) begin
                    read_id<=m_arid;read_len<=m_arlen;read_beat<=0;rs<=2;
                    if(ro||!n_arvalid) rq<=0;else rq<=rq+1'b1;
                    if(m_arid[3]!=ro) protocol_fault<=1;
                end
                2:if(m_rvalid&&m_rready) begin
                    if(read_bad) protocol_fault<=1;
                    if(m_rlast) rs<=0;else read_beat<=read_beat+1'b1;
                end
                default:begin rs<=0;protocol_fault<=1;end
            endcase
            case(ws)
                0:if(v_awvalid||n_awvalid) begin wo<=n_awvalid&&(!v_awvalid||wq>=8);ws<=1;end
                1:if(m_awvalid&&m_awready) begin
                    write_id<=m_awid;write_len<=m_awlen;write_beat<=0;ws<=2;
                    if(wo||!n_awvalid) wq<=0;else wq<=wq+1'b1;
                    if(m_awid[3]!=wo) protocol_fault<=1;
                end
                2:if(m_wvalid&&m_wready) begin
                    if(m_wlast!=(write_beat==write_len)) protocol_fault<=1;
                    if(m_wlast) ws<=3;else write_beat<=write_beat+1'b1;
                end
                3:if(m_bvalid&&m_bready) begin if(write_bad) protocol_fault<=1;ws<=0;end
                default:begin ws<=0;protocol_fault<=1;end
            endcase
        end
    end
endmodule
`default_nettype wire
