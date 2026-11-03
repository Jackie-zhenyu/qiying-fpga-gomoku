create_clock -name {ddr_clk} -period 10.000 -waveform {0.000 5.000} [get_ports {I_ddr_clk}]
create_clock -name {sys_clk} -period 40.000 -waveform {0.000 20.000} [get_ports {I_sys_clk}]


derive_clocks

rename_clock -name {clk_25m} [get_clocks {X_ui_pll/pll_inst.clkc[0]}]
rename_clock -name {clk_70m} [get_clocks {X_ui_pll/pll_inst.clkc[1]}]
rename_clock -name {pclkx1}  [get_clocks {X_ui_pll/pll_inst.clkc[2]}]
rename_clock -name {pclkx5}  [get_clocks {X_ui_pll/pll_inst.clkc[3]}]

set_clock_groups -asynchronous -group [get_clocks {clk_25m}] -group [get_clocks {clk_70m}] -group [get_clocks {pclkx1}] -group [get_clocks {pclkx5}] -group [get_clocks {X_ui_ddr/dfi_clk}]

          



# UART RTL S_clk_25m = PLL C2 = 25MHz; inherited SDC label is pclkx1.
# Static SDC: TD read_sdc does not expand the previous Tcl variable.
set_false_path -from [get_ports {I_capture_uart_rx}] -to [get_regs {qy_capture/serial_bridge/rx_s1}]


# SBX1 bundled-data channel: independently audited after physical routing.
set_false_path -to [get_regs {qy_stone_diag/mailbox/request_meta}]
set_false_path -to [get_regs {qy_stone_diag/mailbox/response_meta}]
set_max_delay -from [get_regs {qy_stone_diag/mailbox/source_payload*}] -to [get_regs {qy_stone_diag/mailbox/m_data*}] -datapath_only 8.000

# Asynchronous physical keys: only the first synchronizer stage is exempt.
set_false_path -from [get_ports {I_game_keys_n*}] -to [get_regs {X_hdmi_tx/qy_overlay/menu/keys/key_meta*}]

# 060 single-SPI return data enters a two-stage synchronizer. Only stage one
# is exempt; meta -> sync and all byte-engine logic retain normal timing.
set_false_path -from [get_ports {I_nn_flash_miso}] -to [get_regs {X_hdmi_tx/qy_overlay/storage_records/flash/serial/miso_meta}]
set_false_path -from [get_ports {I_nn_flash_miso}] -to [get_regs {X_hdmi_tx/qy_overlay/peripheral_config/flash/serial/miso_meta}]

# Runtime peripheral links: exempt only their asynchronous RX first stages.
set_false_path -from [get_ports {I_nfc_rx}] -to [get_regs {X_hdmi_tx/qy_overlay/peripherals/nfc_uart/rx_meta}]
set_false_path -from [get_ports {I_voice_rx}] -to [get_regs {X_hdmi_tx/qy_overlay/peripherals/voice_uart/rx_meta}]

# Camera fabric clock was absent from the inherited constraints. Sensor
# SYS_MODE=5 and INCKSEL table select 891Mbps at nominal 27MHz, and the
# four-lane receiver uses BYTE_NUM=1. Check at 111.375MHz (8.979ns).
# The unchanged board clock is 25MHz; this conservative upper-bound check
# does not certify the sensor's out-of-table input-clock configuration.
create_clock -name camera_byte -period 8.979 -waveform {0.000 4.489} [get_pins {u_mipi_dphy_rx_ph1a_mipiio_wrapper/u_ph1a_mipiio_wrapper/u_PH1_PHY_MIPIIO.hsrx_byteclk_to_fabric}]

# Independently clocked FIFO Gray pointers: cap flight time below the faster
# 233.372MHz period. TD datapath_only also excludes the meaningless phase-
# based hold check on these first synchronizer inputs; later stages retain
# their ordinary same-clock setup/hold checks. No whole-domain false path.
set_max_delay -from [get_regs {X_ui_dbuf/wdbuf_fifo/rd_to_wr_cross_inst/primary_addr_gray_reg*}] -to [get_regs {X_ui_dbuf/wdbuf_fifo/rd_to_wr_cross_inst/sync_r1*}] -datapath_only 4.000
set_max_delay -from [get_regs {X_ui_dbuf/wdbuf_fifo/wr_to_rd_cross_inst/primary_addr_gray_reg*}] -to [get_regs {X_ui_dbuf/wdbuf_fifo/wr_to_rd_cross_inst/sync_r1*}] -datapath_only 4.000

# Registered single-bit status and frame event synchronizers.
set_max_delay -from [get_regs {X_ui_dbuf/W_empty_ui}] -to [get_regs {X_ui_dbuf/W_empty_meta}] -datapath_only 4.000
set_max_delay -from [get_regs {X_ui_dbuf/W_idle_ui}] -to [get_regs {X_ui_dbuf/W_idle_meta}] -datapath_only 4.000
set_max_delay -from [get_regs {X_ui_dbuf/wfifo_rst_done}] -to [get_regs {X_ui_dbuf/wfifo_rst_done_r1}] -datapath_only 4.000
set_max_delay -from [get_regs {X_ui_dbuf/W_tuser_r3}] -to [get_regs {X_ui_dbuf/wfs_r1}] -datapath_only 4.000
set_max_delay -from [get_regs {X_hdmi_tx/qy_link_watch/frame_toggle}] -to [get_regs {X_hdmi_tx/qy_link_watch/toggle_sync[0]}] -datapath_only 4.000
set_max_delay -from [get_regs {u_mipi_dphy_rx_ph1a_mipiio_wrapper/u_ph1a_mipiio_wrapper/u_lane0_hs_detect/O_hs_en}] -to [get_regs {u_mipi_dphy_rx_ph1a_mipiio_wrapper/u_ph1a_mipiio_wrapper/S_data_lane_hs_en_1d}] -datapath_only 4.000

# Asynchronous assertion pins of reset synchronizers only. Their data-path
# release chains and all image/ISP data paths remain timed.
set_false_path -to [get_pins {X_ui_dbuf/wdbuf_fifo/asy_r_rst*_reg*.asr X_ui_dbuf/wdbuf_fifo/asy_w_rst*_reg*.asr}]
set_false_path -to [get_pins {X_hdmi_tx/qy_link_watch/source_reset/release_pipe*_reg*.asr}]
