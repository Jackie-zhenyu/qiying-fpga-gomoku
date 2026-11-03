/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/03/23
*Module Name:hdmi_tx
*File Name:hdmi_tx.v
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.1
*Signal description
*1) _i input
*2) _o output
*3) _n activ low
*4) _dg debug signal 
*5) _r delay or register
*6) _s state mechine
*********************************************************************/
/********************************************************************
本IP由上海安路科技提供，米联客根据自己使用习惯接口部分增加了RGB输入接口方式，
核心功能描述如下：
HDMI Transmitter工作需要两个时钟，像素时钟pixel_clk和串行发送时钟serial_clk。两个时钟都是通过PLL生成，其中serial_clk的频率是pixel_clk频率的五倍。
HDMI Transmitter的三个接口EDID_Read_interface、Video_interface和Audio_interface都是工作在pixel_clk时钟域下，因此用户逻辑需要使用pixel_clk来生成音视频数据。
HDMI Transmitter的pixel_clk频率和serial_clk频率需要根据显示分辨率进行计算。以1080p60的分辨率为例，有效分辨率为1920x1080，在计算频率的时候需要加上消隐区，
图像总的长宽为2200x1125，每秒60帧，因此像素时钟的频率为：
F_pixel=Htotal×Vtotal×FrameRate
F_pixel=2200×1125×60=148500000Hz=148.5MHz
串行发送时钟serial_clk频率为像素时钟频率的五倍，因此串行发送时钟频率为：
F_serial=5×F_pixel=5×148.5MHz=742.5MHz

1-最高支持1080p60显示分辨率。
2-支持两路音频输入。
3-支持RGB444和YUV444。
4-支持内部视频测试源。
5-支持EDID读取。
*********************************************************************/
`timescale 1ns / 1ns //仿真时间刻度/精度




module hdmi_tx#(
    parameter DEVICE            = "DR1"//"EF2","EF3","EF4","SF1","EG","PH1A","PH1P","DR1","PH2A"
)
(
    input wire [3:0] I_game_keys_n,
    input wire I_nfc_rx,I_voice_rx,output wire O_nfc_tx,O_voice_tx,
    output wire O_storage_cs_n,O_storage_sclk,O_storage_mosi,input wire I_storage_miso,
    output wire O_stone_valid,output wire [337:0] O_game_board,output wire [95:0] O_game_meta,output wire [31:0] O_game_origin_status,
    output wire [191:0] O_game_calibration_diag_data,output wire [7:0] O_game_calibration_diag_events,
    output wire [31:0] O_stone_sequence,O_stone_frame,O_stone_compute,O_stone_total,
    input wire       I_pixel_clk	,  //像素时钟
    input wire       I_serial_clk	,  //串行发送时钟
    input wire       I_rst			,  //异步复位信号，高电平有效
    input wire [15:0] I_nn_rgb565,input wire [1:0] I_nn_mask,input wire I_nn_valid,
    output wire [15:0] O_nn_read_address,output wire O_nn_video_blank,
    input wire I_camera_clk,I_camera_frame_end,
    input wire I_ddr_pll,I_ddr_done,I_buffer_ready,I_camera_configured,
    input wire [7:0] I_ddr_error,I_ddr_step,
    input wire[23:0] I_video_in_data,  //视频输入数据
    input wire       I_video_in_de	,  //输入de有效
    input wire       I_video_in_vs	,  //输入VS 帧同步
    input wire       I_video_in_hs	,  //输入hS 帧同步
    output           O_hdmi_clk_p	,  //HDMI输出时钟P端
    output    [2:0]  O_hdmi_tx_p  	   //HDMI输出数据P端

);

wire[9:0]   S_ch0_tmds_code_data;               
wire[9:0]   S_ch1_tmds_code_data;               
wire[9:0]   S_ch2_tmds_code_data;               
wire[9:0]   S_clk_tmds_code_data;

reg [23:0] 	r_video_in_data;

always @(posedge I_pixel_clk) r_video_in_data <= I_video_in_data;
  
 
// Qiying insertion AFTER the original RGB register: preserve input alignment.
wire qy_rst_n;
wire [23:0] qy_rgb;
wire qy_de,qy_hs,qy_vs;
wire qy_camera_ready,qy_frame_tick;
wire [20:0] qy_link_status;
qy_camera_link_watch qy_link_watch(
 .pixel_clk_i(I_pixel_clk),.rst_n_i(qy_rst_n),.frame_tick_i(qy_frame_tick),
 .camera_clk_i(I_camera_clk),.camera_frame_end_i(I_camera_frame_end),
 .ddr_pll_i(I_ddr_pll),.ddr_done_i(I_ddr_done),.buffer_ready_i(I_buffer_ready),
 .camera_configured_i(I_camera_configured),.ddr_error_i(I_ddr_error),.ddr_step_i(I_ddr_step),
 .camera_ready_o(qy_camera_ready),.status_o(qy_link_status));
qy_reset_sync qy_reset(.clk_i(I_pixel_clk),.arst_n_i(!I_rst),.rst_n_o(qy_rst_n));
qy_human_ai_video qy_overlay(
 .nfc_rx(I_nfc_rx),.voice_rx(I_voice_rx),.nfc_tx(O_nfc_tx),.voice_tx(O_voice_tx),
 .flash_cs_n(O_storage_cs_n),.flash_sclk(O_storage_sclk),.flash_mosi(O_storage_mosi),.flash_miso(I_storage_miso),
 .camera_ready_i(qy_camera_ready),.status_i(qy_link_status),.frame_tick_o(qy_frame_tick),.clk_i(I_pixel_clk),.rst_n_i(qy_rst_n),
 .keys_n(I_game_keys_n),.rgb_i(r_video_in_data),.de_i(I_video_in_de),.hs_i(I_video_in_hs),.vs_i(I_video_in_vs),
 .rgb_o(qy_rgb),.de_o(qy_de),.hs_o(qy_hs),.vs_o(qy_vs),
 .result_valid(O_stone_valid),.game_board(O_game_board),.game_meta(O_game_meta),.game_origin_status(O_game_origin_status),
 .game_calibration_diag_data(O_game_calibration_diag_data),.game_calibration_diag_events(O_game_calibration_diag_events),
 .result_sequence(O_stone_sequence),.source_frame(O_stone_frame),.compute_cycles(O_stone_compute),.total_cycles(O_stone_total));
assign O_nn_read_address=16'd0;
assign O_nn_video_blank=qy_frame_tick;
hdmi_tx_controller_wrapper u_hdmi_tx_controller_wrapper(
    .I_pixel_clk          (I_pixel_clk           ),
    .I_rst                (I_rst                 ),
    .I_video_in_data      (qy_rgb),
    .I_video_in_vs        (qy_vs),
    .I_video_in_hs        (qy_hs),
    .I_video_in_de        (qy_de),
    .O_ch0_tmds_code_data ( S_ch0_tmds_code_data ),
    .O_ch1_tmds_code_data ( S_ch1_tmds_code_data ),
    .O_ch2_tmds_code_data ( S_ch2_tmds_code_data ),
    .O_clk_tmds_code_data ( S_clk_tmds_code_data )
);
    
hdmi_tx_phy_wrapper  #(
    .DEVICE ( DEVICE )  //"EF2","EF3","EF4","SF1","EG","PH1A","PH1P","DR1"
)u_hdmi_tx_phy_wrapper(
    .I_pixel_clk        ( I_pixel_clk          ),
    .I_serial_clk       ( I_serial_clk         ),
    .I_rst              ( I_rst                ),

    .I_tmds_channel_0   ( S_ch0_tmds_code_data ),
    .I_tmds_channel_1   ( S_ch1_tmds_code_data ),
    .I_tmds_channel_2   ( S_ch2_tmds_code_data ),
    .I_tmds_channel_clk ( S_clk_tmds_code_data ),

    .O_tmds_ch0_p       ( O_hdmi_tx_p[0]       ),
    .O_tmds_ch1_p       ( O_hdmi_tx_p[1]       ),
    .O_tmds_ch2_p       ( O_hdmi_tx_p[2]       ),
    .O_tmds_clk_p       ( O_hdmi_clk_p         )
);



endmodule
