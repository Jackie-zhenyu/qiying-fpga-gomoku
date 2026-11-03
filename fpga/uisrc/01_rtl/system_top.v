`timescale 1ns / 1ns //ï¿½ï¿½ï¿½ï¿½Ê±ï¿½ï¿½Ì¶ï¿?/ï¿½ï¿½ï¿½ï¿½
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2019/12/17
*Module Name:run_led
*File Name:run_led.v
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*3) _n activ low
*4) _dg debug signal 
*5) _r delay or register
*6) S_ state mechine
*********************************************************************/

`define DRAM_BYTE_NUM 4    // 1 = x8, 2 = x16,4 = x32,8=x64
`define DRAM_SIZE    "4G"     // AP106,AP102=2G ,AP104=4G    1G , 2G , 4G = 256x16bit, 8G    ,ONE DDR particle capacity

//`define XLNX_NATIVE
//`define ALC_NATIVE  
`define MC_AXI  
 
//`define AXI_ATG  
//`define ATG   
//`define DFI

// Real RGB snapshot diagnostic increment; accepted display path retained.
module system_top#(
parameter DRAM_TYPE       = "DDR3"  ,            //"DDR4" "DDR3"
parameter ECC             = "OFF",
parameter APP_ADDR_WIDTH  = (`DRAM_SIZE=="1G")?26:(`DRAM_SIZE=="2G")?27:(`DRAM_SIZE == "4G")?28:(`DRAM_SIZE == "8G")?29:28, //512Mx16bit=29 ,256Mx16bit=28 ,128Mx16bit=27,64Mx16bit = 26,
parameter AXI_ID_WIDTH    =  4,                                                                                   
parameter APP_DATA_WIDTH  = (ECC == "ON")? (`DRAM_BYTE_NUM-1)*8*8 : `DRAM_BYTE_NUM*8*8,
parameter APP_MASK_WIDTH  = (ECC == "ON")? (`DRAM_BYTE_NUM-1)*8   : `DRAM_BYTE_NUM*8,
parameter AXI_ADDR_WIDTH  = APP_ADDR_WIDTH+4,
parameter AXI_DATA_WIDTH  = APP_DATA_WIDTH,
parameter DQ_WIDTH        = `DRAM_BYTE_NUM * 8,
parameter DQS_WIDTH       = `DRAM_BYTE_NUM,
parameter DM_WIDTH        = `DRAM_BYTE_NUM,
parameter ADDR_WIDTH      = (DRAM_TYPE=="DDR4")?17:(`DRAM_SIZE=="1G")?13:(`DRAM_SIZE=="2G")?14:(`DRAM_SIZE == "4G")?15:(`DRAM_SIZE == "8G")?16:15, // 512Mx16bit=16 ,256Mx16bit=15,128Mx16bit=14,64Mx16bit=13
parameter ROW_WIDTH       = (`DRAM_SIZE=="1G")?13:(`DRAM_SIZE=="2G")?14:(`DRAM_SIZE == "4G")?15:(`DRAM_SIZE == "8G")?16:15,                        // 512Mx16bit=16 ,256Mx16bit=15,128Mx16bit=14,64Mx16bit=13
parameter COL_WIDTH       = 10,                  //
parameter BA_WIDTH        = 3,                   //
parameter BG_WIDTH        = 1,                   //
parameter ODT_WIDTH       = 1,                   // PP phy 2, single phy 1
parameter CKE_WIDTH       = 1,                   // PP phy 2, single phy 1
parameter CS_WIDTH        = 1                    // PP phy 2, single phy 1
)
(
	input wire [3:0] I_game_keys_n,
    input wire I_nfc_rx,I_voice_rx,output wire O_nfc_tx,O_voice_tx,
	input wire I_capture_uart_rx,
    output wire O_nn_flash_cs_n,O_nn_flash_clk,O_nn_flash_mosi,O_nn_flash_wp_n,O_nn_flash_hold_n,
    input wire I_nn_flash_miso,
	output wire O_capture_uart_tx,
	input wire                      I_sys_clk		,
	input wire                      I_ddr_clk   	,
	
	//DDR 
	output    [ADDR_WIDTH-1:0]      ddr_addr    	, 
	output    [  BA_WIDTH-1:0]      ddr_ba      	,
	output    [ CKE_WIDTH-1:0]      ddr_cke     	,
	output    [ ODT_WIDTH-1:0]      ddr_odt     	,
	output    [  CS_WIDTH-1:0]      ddr_cs_n    	,
	output                          ddr_ras_n   	,
	output                          ddr_cas_n   	,
	output                          ddr_we_n    	,
	output                          ddr_ck_p    	,
	output                          ddr_ck_n    	,
	output                          ddr_reset_n 	,
	inout     [  DM_WIDTH-1:0]      ddr_dm      	,   
	inout     [  DQ_WIDTH-1:0]      ddr_dq      	,
	inout     [ DQS_WIDTH-1:0]      ddr_dqs_n   	,
	inout     [ DQS_WIDTH-1:0]      ddr_dqs_p   	,
	inout  wire            			IO_cam_sda		,
	output wire           			O_cam_scl		,
	output wire           			O_cam_clk		,
	
	output wire   [2:0]             O_hdmi_tx_p 	,
	output wire                     O_hdmi_clk_p	

);

wire [15:0] qn_image_address,qn_image_rgb;wire [1:0] qn_image_mask;wire qn_image_valid,qn_video_blank;
// New NN master, existing FDMA remains the video owner.
wire qn_bus_reset_n,qn_protocol_fault;
wire qn_lease_req_valid,qn_lease_req_ready,qn_lease_valid,qn_lease_ready,qn_release_valid,qn_release_ready,qn_diag_valid,qn_diag_ready;
wire [31:0] qn_lease_req_tag,qn_lease_tag,qn_lease_frame,qn_lease_base,qn_release_tag;
wire [31:0] perf_capture_start,perf_capture_end,perf_capture_ready;
wire [7:0] qn_lease_status;wire [639:0] qn_diag_data;
assign O_nn_flash_wp_n=1'b1;assign O_nn_flash_hold_n=1'b1;
wire [31:0] V_axi_awaddr;
wire [3:0] V_axi_awid;
wire [7:0] V_axi_awlen;
wire [2:0] V_axi_awsize;
wire [1:0] V_axi_awburst;
wire V_axi_awlock;
wire [3:0] V_axi_awcache;
wire [2:0] V_axi_awprot;
wire [3:0] V_axi_awqos;
wire V_axi_awvalid;
wire [255:0] V_axi_wdata;
wire [31:0] V_axi_wstrb;
wire V_axi_wlast;
wire V_axi_wvalid;
wire [31:0] V_axi_araddr;
wire [3:0] V_axi_arid;
wire [7:0] V_axi_arlen;
wire [2:0] V_axi_arsize;
wire [1:0] V_axi_arburst;
wire V_axi_arlock;
wire [3:0] V_axi_arcache;
wire [2:0] V_axi_arprot;
wire [3:0] V_axi_arqos;
wire V_axi_arvalid;
wire V_axi_rready;
wire V_axi_bready;
wire V_axi_awready;
wire V_axi_wready;
wire V_axi_arready;
wire [255:0] V_axi_rdata;
wire [3:0] V_axi_rid;
wire [1:0] V_axi_rresp;
wire V_axi_rlast;
wire V_axi_rvalid;
wire [3:0] V_axi_bid;
wire [1:0] V_axi_bresp;
wire V_axi_bvalid;
wire [31:0] N_axi_awaddr;
wire [3:0] N_axi_awid;
wire [7:0] N_axi_awlen;
wire [2:0] N_axi_awsize;
wire [1:0] N_axi_awburst;
wire N_axi_awlock;
wire [3:0] N_axi_awcache;
wire [2:0] N_axi_awprot;
wire [3:0] N_axi_awqos;
wire N_axi_awvalid;
wire [255:0] N_axi_wdata;
wire [31:0] N_axi_wstrb;
wire N_axi_wlast;
wire N_axi_wvalid;
wire [31:0] N_axi_araddr;
wire [3:0] N_axi_arid;
wire [7:0] N_axi_arlen;
wire [2:0] N_axi_arsize;
wire [1:0] N_axi_arburst;
wire N_axi_arlock;
wire [3:0] N_axi_arcache;
wire [2:0] N_axi_arprot;
wire [3:0] N_axi_arqos;
wire N_axi_arvalid;
wire N_axi_rready;
wire N_axi_bready;
wire N_axi_awready;
wire N_axi_wready;
wire N_axi_arready;
wire [255:0] N_axi_rdata;
wire [3:0] N_axi_rid;
wire [1:0] N_axi_rresp;
wire N_axi_rlast;
wire N_axi_rvalid;
wire [3:0] N_axi_bid;
wire [1:0] N_axi_bresp;
wire N_axi_bvalid;
qy_clip_nn_idle #(.ENABLE_PREVIEW(1)) qy_nn(.nn_clk(I_ddr_clk),
.bus_clk(S_dfi_clk),
.reset_n(S_ddr_init_cal_done & S_pll_lock),
.bus_reset_n(qn_bus_reset_n),
.video_clk(S_pclkx1),
.video_blank(qn_video_blank),
.preview_read_address(qn_image_address),
.preview_rgb565(qn_image_rgb),
.preview_mask(qn_image_mask),
.preview_valid(qn_image_valid),
.preview_tag(),
.preview_frame(),
.lease_req_valid(qn_lease_req_valid),
.lease_req_ready(qn_lease_req_ready),
.lease_req_tag(qn_lease_req_tag),
.lease_valid(qn_lease_valid),
.lease_ready(qn_lease_ready),
.lease_tag(qn_lease_tag),
.lease_frame(qn_lease_frame),
.lease_base(qn_lease_base),
.lease_status(qn_lease_status),
.perf_capture_start(perf_capture_start),.perf_capture_end(perf_capture_end),.perf_capture_ready(perf_capture_ready),
.release_valid(qn_release_valid),
.release_ready(qn_release_ready),
.release_tag(qn_release_tag),
.diag_valid(),
.diag_ready(1'b1),
.diag_data(),
.spi_cs_n(),
.spi_clk(),
.spi_mosi(),
.spi_miso(1'b1),
.n_awaddr(N_axi_awaddr),
.n_awid(N_axi_awid),
.n_awlen(N_axi_awlen),
.n_awsize(N_axi_awsize),
.n_awburst(N_axi_awburst),
.n_awlock(N_axi_awlock),
.n_awcache(N_axi_awcache),
.n_awprot(N_axi_awprot),
.n_awqos(N_axi_awqos),
.n_awvalid(N_axi_awvalid),
.n_wdata(N_axi_wdata),
.n_wstrb(N_axi_wstrb),
.n_wlast(N_axi_wlast),
.n_wvalid(N_axi_wvalid),
.n_araddr(N_axi_araddr),
.n_arid(N_axi_arid),
.n_arlen(N_axi_arlen),
.n_arsize(N_axi_arsize),
.n_arburst(N_axi_arburst),
.n_arlock(N_axi_arlock),
.n_arcache(N_axi_arcache),
.n_arprot(N_axi_arprot),
.n_arqos(N_axi_arqos),
.n_arvalid(N_axi_arvalid),
.n_rready(N_axi_rready),
.n_bready(N_axi_bready),
.n_awready(N_axi_awready),
.n_wready(N_axi_wready),
.n_arready(N_axi_arready),
.n_rdata(N_axi_rdata),
.n_rid(N_axi_rid),
.n_rresp(N_axi_rresp),
.n_rlast(N_axi_rlast),
.n_rvalid(N_axi_rvalid),
.n_bid(N_axi_bid),
.n_bresp(N_axi_bresp),
.n_bvalid(N_axi_bvalid));
qy_video_nn_axi_arbiter qy_ddr_arbiter(.clk(S_dfi_clk),
.rst(!qn_bus_reset_n),
.protocol_fault(qn_protocol_fault),
.v_awaddr(V_axi_awaddr),
.v_awid(V_axi_awid),
.v_awlen(V_axi_awlen),
.v_awsize(V_axi_awsize),
.v_awburst(V_axi_awburst),
.v_awlock(V_axi_awlock),
.v_awcache(V_axi_awcache),
.v_awprot(V_axi_awprot),
.v_awqos(V_axi_awqos),
.v_awvalid(V_axi_awvalid),
.v_wdata(V_axi_wdata),
.v_wstrb(V_axi_wstrb),
.v_wlast(V_axi_wlast),
.v_wvalid(V_axi_wvalid),
.v_araddr(V_axi_araddr),
.v_arid(V_axi_arid),
.v_arlen(V_axi_arlen),
.v_arsize(V_axi_arsize),
.v_arburst(V_axi_arburst),
.v_arlock(V_axi_arlock),
.v_arcache(V_axi_arcache),
.v_arprot(V_axi_arprot),
.v_arqos(V_axi_arqos),
.v_arvalid(V_axi_arvalid),
.v_rready(V_axi_rready),
.v_bready(V_axi_bready),
.v_awready(V_axi_awready),
.v_wready(V_axi_wready),
.v_arready(V_axi_arready),
.v_rdata(V_axi_rdata),
.v_rid(V_axi_rid),
.v_rresp(V_axi_rresp),
.v_rlast(V_axi_rlast),
.v_rvalid(V_axi_rvalid),
.v_bid(V_axi_bid),
.v_bresp(V_axi_bresp),
.v_bvalid(V_axi_bvalid),
.n_awaddr(N_axi_awaddr),
.n_awid(N_axi_awid),
.n_awlen(N_axi_awlen),
.n_awsize(N_axi_awsize),
.n_awburst(N_axi_awburst),
.n_awlock(N_axi_awlock),
.n_awcache(N_axi_awcache),
.n_awprot(N_axi_awprot),
.n_awqos(N_axi_awqos),
.n_awvalid(N_axi_awvalid),
.n_wdata(N_axi_wdata),
.n_wstrb(N_axi_wstrb),
.n_wlast(N_axi_wlast),
.n_wvalid(N_axi_wvalid),
.n_araddr(N_axi_araddr),
.n_arid(N_axi_arid),
.n_arlen(N_axi_arlen),
.n_arsize(N_axi_arsize),
.n_arburst(N_axi_arburst),
.n_arlock(N_axi_arlock),
.n_arcache(N_axi_arcache),
.n_arprot(N_axi_arprot),
.n_arqos(N_axi_arqos),
.n_arvalid(N_axi_arvalid),
.n_rready(N_axi_rready),
.n_bready(N_axi_bready),
.n_awready(N_axi_awready),
.n_wready(N_axi_wready),
.n_arready(N_axi_arready),
.n_rdata(N_axi_rdata),
.n_rid(N_axi_rid),
.n_rresp(N_axi_rresp),
.n_rlast(N_axi_rlast),
.n_rvalid(N_axi_rvalid),
.n_bid(N_axi_bid),
.n_bresp(N_axi_bresp),
.n_bvalid(N_axi_bvalid),
.m_awaddr(S_axi_awaddr),
.m_awid(S_axi_awid),
.m_awlen(S_axi_awlen),
.m_awsize(S_axi_awsize),
.m_awburst(S_axi_awburst),
.m_awlock(S_axi_awlock),
.m_awcache(S_axi_awcache),
.m_awprot(S_axi_awprot),
.m_awqos(S_axi_awqos),
.m_awvalid(S_axi_awvalid),
.m_wdata(S_axi_wdata),
.m_wstrb(S_axi_wstrb),
.m_wlast(S_axi_wlast),
.m_wvalid(S_axi_wvalid),
.m_araddr(S_axi_araddr),
.m_arid(S_axi_arid),
.m_arlen(S_axi_arlen),
.m_arsize(S_axi_arsize),
.m_arburst(S_axi_arburst),
.m_arlock(S_axi_arlock),
.m_arcache(S_axi_arcache),
.m_arprot(S_axi_arprot),
.m_arqos(S_axi_arqos),
.m_arvalid(S_axi_arvalid),
.m_rready(S_axi_rready),
.m_bready(S_axi_bready),
.m_awready(S_axi_awready),
.m_wready(S_axi_wready),
.m_arready(S_axi_arready),
.m_rdata(S_axi_rdata),
.m_rid(S_axi_rid),
.m_rresp(S_axi_rresp),
.m_rlast(S_axi_rlast),
.m_rvalid(S_axi_rvalid),
.m_bid(S_axi_bid),
.m_bresp(S_axi_bresp),
.m_bvalid(S_axi_bvalid));
// Separate wires keep the original ui_dbuf display protocol intact.
wire [AXI_ADDR_WIDTH-1:0] qy_capture_waddr, qy_capture_raddr;
wire [15:0] qy_capture_rsize;
wire qy_capture_rreq, qy_capture_rbusy, qy_capture_rvalid, qy_capture_rready;
wire [255:0] qy_capture_rdata;
qy_capture_clip_system #(.ADDR_WIDTH(AXI_ADDR_WIDTH)) qy_capture (
    .bus_clk(S_dfi_clk),
.uart_clk(S_clk_25m),
.reset_n(S_ddr_init_cal_done & S_pll_lock),
    .uart_rx(I_capture_uart_rx),
.uart_tx(O_capture_uart_tx),
    .lease_req_valid(qn_lease_req_valid),
.lease_req_ready(qn_lease_req_ready),
.lease_req_tag(qn_lease_req_tag),
    .lease_valid(qn_lease_valid),
.lease_ready(qn_lease_ready),
.lease_tag(qn_lease_tag),
.lease_frame(qn_lease_frame),
.lease_base(qn_lease_base),
.lease_status(qn_lease_status),
.perf_capture_start(perf_capture_start),.perf_capture_end(perf_capture_end),.perf_capture_ready(perf_capture_ready),
    .release_valid(qn_release_valid),
.release_ready(qn_release_ready),
.release_tag(qn_release_tag),
    .diag_valid(qn_diag_valid),
.diag_ready(qn_diag_ready),
.diag_data(qn_diag_data),
    .dbuf_waddr(S_fdma_waddr),
.dbuf_wreq(S_fdma_wareq),
.dbuf_wsize(S_fdma_wsize),
    .fdma_wbusy(S_fdma_wbusy),
.fdma_wvalid(S_fdma_wvalid),
.mapped_waddr(qy_capture_waddr),
    .axi_aw_fire(V_axi_awvalid & V_axi_awready),
    .axi_b_fire(V_axi_bvalid & V_axi_bready),
    .axi_b_error(V_axi_bvalid & V_axi_bready & (V_axi_bresp != 2'b00)),
    .dbuf_raddr(S_fdma_raddr),
.dbuf_rreq(S_fdma_rareq),
.dbuf_rsize(S_fdma_rsize),
    .dbuf_rbusy(S_fdma_rbusy),
.dbuf_rvalid(S_fdma_rvalid),
.dbuf_rdata(S_fdma_rdata),
    .fdma_raddr(qy_capture_raddr),
.fdma_rreq(qy_capture_rreq),
.fdma_rsize(qy_capture_rsize),
    .fdma_rready(qy_capture_rready),
.fdma_rbusy(qy_capture_rbusy),
    .fdma_rvalid(qy_capture_rvalid),
.fdma_rdata(qy_capture_rdata),
    .axi_r_error(V_axi_rvalid & V_axi_rready & (V_axi_rresp != 2'b00))
);
//-------- User Clock --------//
wire                       		S_dfi_clk             ;
wire                       		S_ddr_init_cal_done   ;

// AXI Write Addr
wire [AXI_ADDR_WIDTH-1:0]      	S_axi_awaddr  	;
wire                           	S_axi_awvalid 	;
wire                           	S_axi_awready 	;
wire   [AXI_ID_WIDTH-1:0]      	S_axi_awid    	;
wire                [7:0]      	S_axi_awlen   	; 
wire                [2:0]      	S_axi_awsize  	; 
wire                [1:0]      	S_axi_awburst 	; 
wire                [0:0]      	S_axi_awlock  	; 
wire                [3:0]      	S_axi_awcache 	; 
wire                [2:0]      	S_axi_awprot  	; 
wire                [3:0]      	S_axi_awqos   	;
// AXI Write Data              		
wire [APP_DATA_WIDTH-1:0]      	S_axi_wdata   	;
wire [APP_MASK_WIDTH-1:0]      	S_axi_wstrb   	;
wire                           	S_axi_wvalid  	;
wire                           	S_axi_wlast   	;
wire                           	S_axi_wready  	;
// Write Response Port         		
wire   [AXI_ID_WIDTH-1:0]      	S_axi_bid     	;    
wire                [1:0]      	S_axi_bresp   	;    
wire                           	S_axi_bvalid  	;    
wire                           	S_axi_bready  	;    
								
// AXI Read Addr               	
wire [AXI_ADDR_WIDTH-1:0]      	S_axi_araddr  	;
wire                           	S_axi_arvalid 	;
wire                           	S_axi_arready 	;
wire [  AXI_ID_WIDTH-1:0]      	S_axi_arid    	;
wire                [7:0]      	S_axi_arlen   	;
wire                [2:0]      	S_axi_arsize  	;
wire                [1:0]      	S_axi_arburst 	;
wire                [0:0]      	S_axi_arlock  	;
wire                [3:0]      	S_axi_arcache 	;
wire                [2:0]      	S_axi_arprot  	;
wire                [3:0]      	S_axi_arqos   	;
// AXI Read Data               		
wire [APP_DATA_WIDTH-1:0]      	S_axi_rdata   	;
wire                           	S_axi_rlast   	;
wire                           	S_axi_rvalid  	;
wire                           	S_axi_rready  	;
wire   [AXI_ID_WIDTH-1:0]      	S_axi_rid     	;
wire                [1:0]      	S_axi_rresp   	;

//MLK_FDMA
wire [AXI_ADDR_WIDTH-1:  0]    	S_fdma_waddr	;   //FDMA写通道地址
wire                           	S_fdma_wareq	;   //FDMA写通道请求
wire [15: 0]                   	S_fdma_wsize	;   //FDMA写通道一次FDMA的传输大小                                       
wire                           	S_fdma_wbusy	;   //FDMA处于BUSY状态，AXI总线正在写操作 		
wire [AXI_DATA_WIDTH-1 : 0]    	S_fdma_wdata	;   //FDMA写数据
wire                           	S_fdma_wvalid	;   //FDMA 写有效
wire                           	S_fdma_wready	;   //FDMA写准备好，用户可以写数据
								
wire [AXI_ADDR_WIDTH-1:  0]    	S_fdma_raddr	;   //FDMA读通道地址
wire                           	S_fdma_rareq	;   //FDMA读通道请求
wire [15: 0]                   	S_fdma_rsize	;   //FDMA读通道一次FDMA的传输大小                                       
wire                           	S_fdma_rbusy	;   //FDMA处于BUSY状态，AXI总线正在读操作 			
wire [AXI_DATA_WIDTH-1 : 0]    	S_fdma_rdata	;   //FDMA读数据
wire                           	S_fdma_rvalid	;   //FDMA 读有效
wire                           	S_fdma_rready	;   //FDMA读准备好，用户可以读数据	
wire                           	S_test_error	;   //测试是否有错误，1有错误，0没错误

wire        					S_clk_25m		;
wire        					S_clk_70m		;
wire        					S_pclkx1		;
wire        					S_pclkx5		;
wire        					S_pll_lock		;

wire [7:0]						S_ae			;
wire 							S_cam_cfg_done	;
wire 							S_ae_cfg_done	;
wire 							S_ae_req		;

wire          					S_hs_rx_clk		;  
wire          					S_hs_rx_valid	;  
wire [31 : 0] 					S_hs_rx_data	; 
wire [ 3 : 0] 					S_lane_error	; 

wire        					S_csi_frame_start;       
wire        					S_csi_frame_end	;         
wire        					S_csi_valid		;             
wire[31:0]  					S_csi_data		;  
	
wire          					S_raw10_frame_start;
wire          					S_raw10_frame_end;
wire          					S_raw10_valid	;
wire [39 : 0] 					S_raw10_data	;

wire [39:0]						S_axis_tdata	;
wire 							S_axis_tvalid	;
wire 							S_axis_tlast	; 
wire 							S_axis_tuser	; 

wire            				S_ISP_O_tready	;
wire [127:0]    				S_ISP_O_tdata 	;
wire            				S_ISP_O_tlast 	;
wire            				S_ISP_O_tuser 	;
wire            				S_ISP_O_tvalid	;

wire [7:0] 						S_wbuf_sync		;
wire [7:0] 						S_rbuf_sync		;

wire 							S_vtc_vs		;
wire 							S_vtc_hs		;
wire 							S_vtc_de_valid	;
wire 							S_vtc_user		;
wire 							S_vtc_last      ;

wire        					S_R_vrst		;
wire [23:0] 					S_ud_rtdata		;


// Read-only bring-up status from the existing DDR controller.
wire qy_ddr_pll;
wire [7:0] qy_ddr_error,qy_ddr_step;
ui_pll X_ui_pll(
	.refclk   		( I_sys_clk		),
	.lock     		( S_pll_lock	),
					
	.clk0_out 		( S_pclkx1		),
	.clk1_out 		( S_pclkx5		),
	.clk2_out 		( S_clk_25m		),
	.clk3_out 		( S_clk_70m		)
);


PH1_LOGIC_ODDR X_cam_clk (
    .q  			(O_cam_clk		), 
    .clk			(S_clk_25m		),
    .d0 			(1'b1			),
    .d1 			(1'b0			),
    .rst			(~S_pll_lock	)
  );

//手动配置相机AE
ui_ae_set X_ui_ae_set (
	.I_clk			(S_clk_25m		),
	.I_rst			(S_pll_lock		),
	.I_btn			(2'b00		),
	.I_cam_cfg_done	(S_cam_cfg_done	),
	.I_ae_cfg_done	(S_ae_cfg_done	),
	.O_ae_req		(S_ae_req		),
	.O_ae			(S_ae			)
  );
  
//IIC协议配置摄像头寄存器
ui_cfg_imx415#(
	.CLK_DIV(24_000_000/100_000-1)
	)
X_ui_cfg_imx415(
	.I_clk			(S_clk_25m		),  
	.I_rst_n		(S_pll_lock		),  
	.I_ae_req		(S_ae_req		),
	.I_ae_data		(S_ae			),
	.O_cam_scl		(O_cam_scl		), 
	.IO_cam_sda		(IO_cam_sda		), 
	.O_cfg_done		(S_cam_cfg_done	),
	.O_ae_cfg_done	(S_ae_cfg_done	)
  );

//mipi_rx
mipi_dphy_rx_ph1a_mipiio_wrapper#(
.LANE_NUM              ( 4 ),
.BYTE_NUM              ( 1 )
)u_mipi_dphy_rx_ph1a_mipiio_wrapper(
.I_lp_clk              ( S_clk_70m		),
.I_rst                 ( ~S_pll_lock	),

.I_clk_lane_in_delay   ( 'd0	),
.I_data_lane0_in_delay ( 'd20   ),
.I_data_lane1_in_delay ( 'd20   ),
.I_data_lane2_in_delay ( 'd20	),
.I_data_lane3_in_delay ( 'd20	),

.I_lane_invert         ( 4'b0000         ),

.O_hs_rx_clk           ( S_hs_rx_clk     ),
.O_hs_rx_valid         ( S_hs_rx_valid   ),
.O_hs_rx_data          ( S_hs_rx_data    ),

.I_lp_tx_en            (1'b0 ),
.I_lp_tx_lane0_p       (1'b0 ),
.I_lp_tx_lane0_n       (1'b0 ),

.O_lane_error          ( S_lane_error    )
);

//csi解码模块
ui_csi_unpacket_4lane X_ui_csi_unpacket_4lane(
	.I_clk            ( S_hs_rx_clk       ),
	.I_rst_n          ( S_pll_lock        ),
	.I_hs_valid       ( S_hs_rx_valid     ),
	.I_hs_data        ( S_hs_rx_data      ),
		
	.O_csi_frame_start( S_csi_frame_start ),
	.O_csi_frame_end  ( S_csi_frame_end   ),
	.O_csi_valid      ( S_csi_valid       ),
	.O_csi_data       ( S_csi_data        )
);

//转为RAW10数据格式
ui_raw10_unpacket_4lane X_ui_raw10_unpacket_4lane (
	.I_clk  			(S_hs_rx_clk		),
	.I_rst_n			(S_pll_lock			),
		
	.I_csi_frame_start	(S_csi_frame_start	),
	.I_csi_frame_end  	(S_csi_frame_end	),
	.I_csi_valid      	(S_csi_valid		),
	.I_csi_data       	(S_csi_data			),
		
	.O_raw10_frame_start(S_raw10_frame_start),
	.O_raw10_frame_end  (S_raw10_frame_end  ),
	.O_raw10_valid      (S_raw10_valid      ),
	.O_raw10_data       (S_raw10_data       )
);

//图像大小裁剪模块
ui_image_correction #(
    .DATA_WIDTH  (40),
    .TDEST_WIDTH (10)
)X_ui_image_correction
(
    .I_clk            	(S_hs_rx_clk		),
    .I_rst_n          	(S_pll_lock			),
		
    .I_raw_data       	(S_raw10_data       ),       
    .I_raw_valid      	(S_raw10_valid      ),     
    .I_raw_frame_start	(S_raw10_frame_start),
    .I_raw_frame_end  	(S_raw10_frame_end  ),
		
    .O_raw_tdata 	  	(S_axis_tdata		),
    .O_raw_tlast 	  	(S_axis_tlast		),
    .O_raw_tvalid	  	(S_axis_tvalid		),
    .O_raw_tuser 	  	(S_axis_tuser		)

);


//米联客ISP图像处理模块
ui_isp_top X_ui_isp_top (
	.I_clk		     	(S_hs_rx_clk		),
	.I_rst_n         	(S_pll_lock			),
	.I_tlast         	(S_axis_tlast 		),
	.I_tuser         	(S_axis_tuser 		),
	.I_tdata         	(S_axis_tdata 		),
	.I_tvalid        	(S_axis_tvalid		),
	.I_tdest         	(					),
	.O_tready        	(S_ISP_O_tready		),
	.O_tdata         	(S_ISP_O_tdata 		),
	.O_tlast         	(S_ISP_O_tlast 		),
	.O_tuser         	(S_ISP_O_tuser 		),
	.O_tvalid        	(S_ISP_O_tvalid		),
	.I_tready        	(					)
  );


//设置3帧缓存，读延迟写1帧
ui_setvbuf#(
	.BUF_DELAY		(1			),
	.BUF_LENTH		(3			)
)
X_ui_setvbuf
(
	.I_bufn			(S_wbuf_sync),
	.O_bufn			(S_rbuf_sync)
);


//例化uidbuf 控制器
ui_dbuf# (  
	.AXI_DATA_WIDTH	(AXI_DATA_WIDTH		),//AXI总线数据位宽
	.AXI_ADDR_WIDTH	(AXI_ADDR_WIDTH		),//AXI总线地址位宽
	.ENABLE_VSYNC	(1					),
	.W_BUFDEPTH		(1024				),//写通道AXI设置FIFO缓存大小
	.W_DATAWIDTH	(128				),//写通道AXI设置数据位宽大小
	.W_BASEADDR		(0					),//写通道设置内存起始地址
	.W_DSIZEBITS	(25					),//写通道设置缓存数据的增量地址大小，用于FDMA DBUF 计算帧缓存起始地址
	.W_XSIZE		(480				),//写通道设置X方向的数据大小，代表了每次FDMA 传输的数据长度
	.W_XSTRIDE		(480				),//写通道设置X方向的Stride值，主要用于图形缓存应用
	.W_YSIZE		(1080				),//写通道设置Y方向值，代表了进行了多少次XSIZE传输
	.W_XDIV			(2					),//写通道对X方向数据拆分为XDIV次传输，减少FIFO的使用
	.W_BUFSIZE		(3					),//写通道设置帧缓存大小，目前最大支持128帧，可以修改参数支持更缓存数
		
	.R_BUFDEPTH		(1024				),//读通道AXI设置FIFO缓存大小
	.R_DATAWIDTH	(32					),//读通道AXI设置数据位宽大小
	.R_BASEADDR		(0					),//读通道设置内存起始地址
	.R_DSIZEBITS	(25					),//读通道设置缓存数据的增量地址大小，用于FDMA DBUF 计算帧缓存起始地址
	.R_XSIZE		(1920				),//读通道设置X方向的数据大小，代表了每次FDMA 传输的数据长度
	.R_XSTRIDE		(1920				),//读通道设置X方向的Stride值，主要用于图形缓存应用
	.R_YSIZE		(1080				),//读通道设置Y方向值，代表了进行了多少次XSIZE传输
	.R_XDIV			(2					),//读通道对X方向数据拆分为XDIV次传输，减少FIFO的使用
	.R_BUFSIZE		(3					) //读通道设置帧缓存大小，目前最大支持128帧，可以修改参数支持更缓存数
)
X_ui_dbuf
(
	.I_ui_clk		(S_dfi_clk			),
	.I_ui_rstn		(S_ddr_init_cal_done),
		
	.I_W_en      	(1					),
	.I_W_wclk    	(S_hs_rx_clk		),
	.I_W_tuser   	(S_ISP_O_tuser		),
	.I_W_tvalid  	(S_ISP_O_tvalid		),
	.I_W_tdata   	(S_ISP_O_tdata		),
	.I_W_tlast   	(S_ISP_O_tlast		),
	.O_W_tready  	(					),
	.O_W_sync_cnt	(S_wbuf_sync		),
	.I_W_buf     	(S_wbuf_sync		),
	
	.I_R_en      	(S_vtc_vs			),
	.I_R_rclk    	(S_pclkx1			),
	.I_R_tready  	(S_vtc_de_valid		),
	.O_R_tuser   	(					),
	.O_R_tvalid  	(					),
	.O_R_tdata   	(S_ud_rtdata		),
	.O_R_tlast   	(					),
	.O_R_sync_cnt	(					),
	.I_R_buf     	(S_rbuf_sync		),
	.O_R_vrst    	(S_R_vrst			),
	
	.O_fdma_waddr 	(S_fdma_waddr		),
	.O_fdma_wareq 	(S_fdma_wareq		),
	.O_fdma_wsize 	(S_fdma_wsize		),
	.I_fdma_wbusy 	(S_fdma_wbusy		),
	.O_fdma_wdata 	(S_fdma_wdata		),
	.I_fdma_wvalid	(S_fdma_wvalid		),
	.O_fdma_wready	(S_fdma_wready		),
	.O_fdma_raddr 	(S_fdma_raddr		),
	.O_fdma_rareq 	(S_fdma_rareq		),
	.O_fdma_rsize 	(S_fdma_rsize		),
	.I_fdma_rbusy 	(S_fdma_rbusy		),
	.I_fdma_rdata 	(S_fdma_rdata		),
	.I_fdma_rvalid	(S_fdma_rvalid		),
	.O_fdma_rready	(S_fdma_rready		)
	//.O_fmda_wbuf  	(fdma_wbuf			),	
	//.O_fdma_wirq  	(fdma_wirq			),		
	//.O_fmda_rbuf  	(fdma_rbuf			),	
	//.O_fdma_rirq  	(fdma_rirq			)
);

//例化米联客uiFDMA AXI 控制器 IP
ui_FDMA#
(
	.M_AXI_B2B_SET		(1				),
	.M_AXI_ID_WIDTH		(AXI_ID_WIDTH	),//ID位宽
	.M_AXI_ADDR_WIDTH	(AXI_ADDR_WIDTH	),//内存地址位宽
	.M_AXI_DATA_WIDTH	(AXI_DATA_WIDTH	),//AXI总线的数据位宽
	.M_AXI_MAX_BURST_LEN(16				) //AXI总线的burst 大小，对于AXI4，支持任意长度，对于AXI3以下最大16
)
X_ui_FDMA
(
	.I_fdma_waddr		(qy_capture_waddr),//FDMA写通道地址
	.I_fdma_wareq		(S_fdma_wareq	),//FDMA写通道请求
	.I_fdma_wsize		(S_fdma_wsize	),//FDMA写通道一次FDMA的传输大小                                            
	.O_fdma_wbusy		(S_fdma_wbusy	),//FDMA处于BUSY状态，AXI总线正在写操作  
					
	.I_fdma_wdata		(S_fdma_wdata	),//FDMA写数据
	.O_fdma_wvalid		(S_fdma_wvalid	),//FDMA 写有效
	.I_fdma_wready		(1'b1			),//FDMA写准备好，用户可以写数据
	
	.I_fdma_raddr		(qy_capture_raddr),// FDMA读通道地址
	.I_fdma_rareq		(qy_capture_rreq),// FDMA读通道请求
	.I_fdma_rsize		(qy_capture_rsize),// FDMA读通道一次FDMA的传输大小                                      
	.O_fdma_rbusy		(qy_capture_rbusy),// FDMA处于BUSY状态，AXI总线正在读操作 
					
	.O_fdma_rdata		(qy_capture_rdata),// FDMA读数据
	.O_fdma_rvalid		(qy_capture_rvalid),// FDMA 读有效
	.I_fdma_rready		(qy_capture_rready),// FDMA读准备好，用户可以读数据

//以下为AXI总线信号		
	.M_AXI_ACLK         (S_dfi_clk		),
	.M_AXI_ARESETN      (S_ddr_init_cal_done),
// Master Interface Write Address Ports
	.M_AXI_AWID         (V_axi_awid		),
	.M_AXI_AWADDR       (V_axi_awaddr	),
	.M_AXI_AWLEN        (V_axi_awlen	),
	.M_AXI_AWSIZE       (V_axi_awsize	),
	.M_AXI_AWBURST      (V_axi_awburst	),
	.M_AXI_AWLOCK       (V_axi_awlock	),
	.M_AXI_AWCACHE      (V_axi_awcache	),
	.M_AXI_AWPROT       (V_axi_awprot	),
	.M_AXI_AWQOS        (V_axi_awqos	),
	.M_AXI_AWVALID      (V_axi_awvalid	),
	.M_AXI_AWREADY      (V_axi_awready	),
// Master Interface Write Data Ports
	.M_AXI_WDATA        (V_axi_wdata	),
	.M_AXI_WSTRB        (V_axi_wstrb	),
	.M_AXI_WLAST        (V_axi_wlast	),
	.M_AXI_WVALID       (V_axi_wvalid	),
	.M_AXI_WREADY       (V_axi_wready	),
// Master Interface Write Response Ports
	.M_AXI_BID          (V_axi_bid		),
	.M_AXI_BRESP        (V_axi_bresp	),
	.M_AXI_BVALID       (V_axi_bvalid	),
	.M_AXI_BREADY       (V_axi_bready	),
// Master Interface Read Address Ports
	.M_AXI_ARID         (V_axi_arid		),
	.M_AXI_ARADDR       (V_axi_araddr	),
	.M_AXI_ARLEN        (V_axi_arlen	),
	.M_AXI_ARSIZE       (V_axi_arsize	),
	.M_AXI_ARBURST      (V_axi_arburst	),
	.M_AXI_ARLOCK       (V_axi_arlock	),
	.M_AXI_ARCACHE      (V_axi_arcache	),
	.M_AXI_ARPROT       (V_axi_arprot	),
	.M_AXI_ARQOS        (V_axi_arqos	),
	.M_AXI_ARVALID      (V_axi_arvalid	),
	.M_AXI_ARREADY      (V_axi_arready	),
// Master Interface Read Data Ports
	.M_AXI_RID          (V_axi_rid		),
	.M_AXI_RDATA        (V_axi_rdata	),
	.M_AXI_RRESP        (V_axi_rresp	),
	.M_AXI_RLAST        (V_axi_rlast	),
	.M_AXI_RVALID       (V_axi_rvalid	),
	.M_AXI_RREADY       (V_axi_rready	)		
);


//例化DDR IP
//===== DDR3 PHY INS =====//
ui_ddr X_ui_ddr (

	.sys_rst_n  		(S_pll_lock		),
    .sys_clk    		(I_ddr_clk		),

// DDRIO
`ifdef MC0_DRAM_DDR4
    .ddr_ck_t       	(				),
    .ddr_ck_c       	(				),
    .ddr_reset_n    	(				),
    .ddr_cke        	(				),
    .ddr_odt        	(				),
    .ddr_cs_n       	(				),
    .ddr_act_n      	(				),
    .ddr_bg         	(				),
    .ddr_ba         	(				),
    .ddr_addr       	(				),
    .ddr_dqs_t      	(				),
    .ddr_dqs_c      	(				),
    .ddr_dq         	(				),
    .ddr_dm_dbi     	(				),
`else
    .ddr_ck_p       	(ddr_ck_p		),    
    .ddr_ck_n       	(ddr_ck_n		),    
    .ddr_reset_n    	(ddr_reset_n	),    
    .ddr_cke        	(ddr_cke		),    
    .ddr_odt        	(ddr_odt		),    
    .ddr_cs_n       	(ddr_cs_n		),    
    .ddr_ras_n      	(ddr_ras_n		),    
    .ddr_cas_n      	(ddr_cas_n		), 		
    .ddr_we_n       	(ddr_we_n		),    
    .ddr_ba         	(ddr_ba			),    
    .ddr_addr       	(ddr_addr		),      
    .ddr_dqs_p      	(ddr_dqs_p		),    
    .ddr_dqs_n      	(ddr_dqs_n		),    
    .ddr_dq         	(ddr_dq			),    
    .ddr_dm            	(ddr_dm			),    
`endif

    .ctl_ram_rst_n     	(				),
    .ctl_ram_cke       	(				),

// user interface ports
    .dfi_clk           	(S_dfi_clk		),
    .pll_locked        	(qy_ddr_pll),
    .ddrphy_rst_n      	(				),
    .ddr_init_cal_done 	(S_ddr_init_cal_done),
    .ddr_init_cal_err  	(qy_ddr_error),
    .ddr_init_cal_step 	(qy_ddr_step),

// mc user interface
`ifdef MC0_MIS_AXI
// AXI Interface
    .axi_aclk          	(				),
    .axi_aresetn       	(				),
// AXI Write Address Channel
    .axi_awid          (S_axi_awid   	),
    .axi_awaddr        (S_axi_awaddr 	),
    .axi_awlen         (S_axi_awlen  	),
    .axi_awsize        (S_axi_awsize 	),
    .axi_awburst       (S_axi_awburst	),
    .axi_awlock        (S_axi_awlock 	),
    .axi_awcache       (S_axi_awcache	),
    .axi_awprot        (S_axi_awprot 	),
    .axi_awqos         (S_axi_awqos  	),
    .axi_awvalid       (S_axi_awvalid	),
    .axi_awready       (S_axi_awready	),
// AXI Write Data Channel                 
    .axi_wdata         (S_axi_wdata 	),
    .axi_wstrb         (S_axi_wstrb 	),
    .axi_wlast         (S_axi_wlast 	),
    .axi_wvalid        (S_axi_wvalid	),
    .axi_wready        (S_axi_wready	),
// AXI Write Response Channel             
    .axi_bid           (S_axi_bid   	),
    .axi_bresp         (S_axi_bresp 	),
    .axi_bvalid        (S_axi_bvalid	),
    .axi_bready        (S_axi_bready	),
// AXI Read Address Channel               
    .axi_arid          (S_axi_arid   	),
    .axi_araddr        (S_axi_araddr 	),
    .axi_arlen         (S_axi_arlen  	),
    .axi_arsize        (S_axi_arsize 	),
    .axi_arburst       (S_axi_arburst	),
    .axi_arlock        (S_axi_arlock 	),
    .axi_arcache       (S_axi_arcache	),
    .axi_arprot        (S_axi_arprot 	),
    .axi_arqos         (S_axi_arqos  	),
    .axi_arvalid       (S_axi_arvalid	),
    .axi_arready       (S_axi_arready	),
// AXI Read Data Channel                  
    .axi_rid           (S_axi_rid   	),
    .axi_rdata         (S_axi_rdata 	),
    .axi_rresp         (S_axi_rresp 	),
    .axi_rlast         (S_axi_rlast 	),
    .axi_rvalid        (S_axi_rvalid	),
    .axi_rready        (S_axi_rready	),
`else  // PAXI
// Write Address Ports
    .paxi_awaddr       (				), 
    .paxi_awvalid      (				), 
    .paxi_awready      (				), 
// Write Data Ports    				
    .paxi_wdata        (				), 
    .paxi_wstrb        (				), 
    .paxi_wvalid       (				), 
    .paxi_wlast        (				), 
    .paxi_wready       (				), 
// Write Response Port 				
    .paxi_bresp        (				), 
    .paxi_bvalid       (				), 
    .paxi_bready       (				), 
// Read Address Ports  				
    .paxi_araddr       (				), 
    .paxi_arvalid      (				), 
    .paxi_arready      (				), 			 
// Read Data Ports     				
    .paxi_rdata        (				), 
    .paxi_rlast        (				), 
    .paxi_rvalid       (				), 
    .paxi_rready       (				), 
`endif
// PZQ Share
    .pzq_cal_done_i    (				),
    .pzq_cal_done_o    (				),
// DFX				
    .user_clk          (				), 
    .apb_clk           (				), 
    .mcu_busy          (				), 
    .user_update       (				), 
    .user_ram_addr     (				), 
    .user_ram_wr_en    (				), 
    .user_ram_rd_en    (				), 
    .user_ram_wr_data  (				), 
    .user_ram_rd_data  (				), 
				
    .uart_rxd          (				),
    .uart_txd          (				)
);

ui_vtc #(
 //1080P 
.H_ActiveSize       (1920           ),//视频时间参数,行视频信号，一行有效(需要显示的部分)像素所占的时钟数，一个时钟对应一个有效像素
.H_SyncStart        (1920+88        ),//视频时间参数,行同步开始，即多少时钟数后开始产生行同步信号 
.H_SyncEnd          (1920+88+44     ),//视频时间参数,行同步结束，即多少时钟数后停止产生行同步信号，之后就是行有效数据部分
.H_FrameSize        (1920+88+44+16	),//视频时间参数,行视频信号，一行视频信号总计占用的时钟数
.V_ActiveSize       (1080           ),//视频时间参数,场视频信号，一帧图像所占用的有效(需要显示的部分)行数量，通常说的视频分辨率即H_ActiveSize*V_ActiveSize
.V_SyncStart        (1080+4         ),//视频时间参数,场同步开始，即多少行数后开始产生场同步信号 
.V_SyncEnd          (1080+4+5       ), //视频时间参数,场同步结束，多少行后停止产生长同步信号  
.V_FrameSize        (1080+4+5+19    )//视频时间参数,场视频信号，一帧视频信号总计占用的行数量        
) 
X_ui_vtc
(
    .I_vtc_rstn		   (S_pll_lock), //系统复位
    .I_vtc_clk		   (S_pclkx1		), //系统时钟
    .O_vtc_vs		   (S_vtc_vs		), //场同步输出
    .O_vtc_hs		   (S_vtc_hs		), //行同步输出
    .O_vtc_de_valid	   (S_vtc_de_valid	), //视频数据有效	
    .O_vtc_user		   (S_vtc_user		), //满足stream时序产生 user 信号,用于帧同步
    .O_vtc_last        (S_vtc_last      )  //满足stream时序产生 later 信号,用于每行结束
);


wire sb_result_valid;wire [337:0] sb_game_board;wire [95:0] sb_game_meta;wire [31:0] sb_game_origin_status;
wire [31:0] sb_sequence,sb_frame,sb_compute,sb_total;
wire [191:0] sb_calibration_diag_data;wire [7:0] sb_calibration_diag_events;
qy_game_telemetry #(.ENABLE_GAC1(1)) qy_stone_diag(.video_clk(S_pclkx1),.bus_clk(S_dfi_clk),
 .common_reset_n(S_ddr_init_cal_done & S_pll_lock),
 .result_valid(sb_result_valid),.board(sb_game_board),.meta(sb_game_meta),.origin_status(sb_game_origin_status),
 .result_sequence(sb_sequence),.source_frame(sb_frame),.compute_cycles(sb_compute),.total_cycles(sb_total),
 .cal_diag_data(sb_calibration_diag_data),.cal_diag_events(sb_calibration_diag_events),
 .diag_valid(qn_diag_valid),.diag_ready(qn_diag_ready),.diag_data(qn_diag_data));
//hdmi 输出IP
hdmi_tx #(  
	.DEVICE            ("PH1A_HP"       ) //"EF2","EF3","EF4","SF1","EG","PH1A","PH1P","DR1","PH2A"
) 
X_hdmi_tx (
 .O_storage_cs_n(O_nn_flash_cs_n),.O_storage_sclk(O_nn_flash_clk),.O_storage_mosi(O_nn_flash_mosi),.I_storage_miso(I_nn_flash_miso),
 .I_nfc_rx(I_nfc_rx),.I_voice_rx(I_voice_rx),.O_nfc_tx(O_nfc_tx),.O_voice_tx(O_voice_tx),


.I_game_keys_n(I_game_keys_n),.O_stone_valid(sb_result_valid),.O_game_board(sb_game_board),.O_game_meta(sb_game_meta),.O_game_origin_status(sb_game_origin_status),
.O_game_calibration_diag_data(sb_calibration_diag_data),.O_game_calibration_diag_events(sb_calibration_diag_events),
.O_stone_sequence(sb_sequence),.O_stone_frame(sb_frame),
.O_stone_compute(sb_compute),.O_stone_total(sb_total),

.I_nn_rgb565(qn_image_rgb),
.I_nn_mask(qn_image_mask),
.I_nn_valid(qn_image_valid),
.O_nn_read_address(qn_image_address),
.O_nn_video_blank(qn_video_blank),                           
	
    .I_camera_clk(S_hs_rx_clk),
.I_camera_frame_end(S_raw10_frame_end),
    .I_ddr_pll(qy_ddr_pll),
.I_ddr_done(S_ddr_init_cal_done),
    .I_buffer_ready(~S_R_vrst),
.I_camera_configured(S_cam_cfg_done),
    .I_ddr_error(qy_ddr_error),
.I_ddr_step(qy_ddr_step),
.I_pixel_clk       (S_pclkx1        ),// 像素时钟
	.I_serial_clk      (S_pclkx5        ),// 串行发送时钟
	.I_rst             (~S_pll_lock),// 异步复位信号，高电平有效
	.I_video_in_data   (S_ud_rtdata 	),// 视频输入数据
	.I_video_in_de     (S_vtc_de_valid  ),// 输入de有效
	.I_video_in_vs     (S_vtc_vs     	),// 输入VS 帧同步
	.I_video_in_hs     (S_vtc_hs     	),// 输入hS 帧同步
	.O_hdmi_clk_p      (O_hdmi_clk_p    ),// HDMI输出时钟P端
	.O_hdmi_tx_p       (O_hdmi_tx_p     ) // HDMI输出数据P端
) ;

    
endmodule
