`timescale 1ns/1ps
module tb_spi_owner;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,config_initialized=0,config_active=1;
 reg settings_active=0,game_active=0,replay_active=0,storage_busy=0;
 reg records_initialized=0,records_idle=0;reg [7:0] records_init_error=0;
 reg record_save_valid=0,record_load_valid=0;
 reg config_cs_n=1,config_sclk=0,config_mosi=1;
 reg records_cs_n=1,records_sclk=0,records_mosi=1;
 wire config_grant,records_rst_n,config_owner,cs_n,sclk,mosi;
 qy_peripheral_spi_owner dut(.*);
 integer checks=0;
 task tick;begin @(posedge clk);#1;end endtask
 task ck(input bit condition,input [511:0] message);
 begin checks++;if(!condition)$fatal(1,"check %0d: %0s",checks,message);end endtask
 task stays_records(input integer cycles);
 integer k;begin for(k=0;k<cycles;k++)begin tick;ck(records_rst_n&&!config_grant,"records cannot be preempted");end end endtask
 task start_records;
 begin config_initialized=1;config_active=0;config_cs_n=1;config_sclk=0;tick;
  ck(!config_grant&&!records_rst_n&&cs_n&&!sclk,"idle gap after config");tick;
  ck(records_rst_n&&!config_grant,"record scanner released");
 end endtask
 task start_config;
 begin tick;ck(!records_rst_n&&!config_grant&&cs_n&&!sclk,"idle gap before save grant");
  tick;ck(config_grant&&!records_rst_n,"config gets exclusive save ownership");end endtask
 initial begin
  tick;ck(cs_n&&!sclk&&!config_grant&&!records_rst_n,"reset bus idle");rst_n=1;tick;
  ck(config_grant&&!records_rst_n,"configuration boot owns SPI first");
  config_cs_n=0;config_sclk=1;config_mosi=0;tick;
  ck(!cs_n&&sclk&&!mosi,"config pins routed");
  config_active=0;config_initialized=1;tick;
  ck(config_grant,"CS low prohibits release even after completion");
  config_cs_n=1;tick;ck(config_grant,"high SCLK prohibits release");config_sclk=0;
  start_records();config_active=1;
  stays_records(4); // scan has CS-high gaps but is not ready
  settings_active=1;records_initialized=1;stays_records(3);
  records_idle=1;storage_busy=1;stays_records(3);
  storage_busy=0;record_save_valid=1;stays_records(3);
  record_save_valid=0;record_load_valid=1;stays_records(3);
  record_load_valid=0;game_active=1;stays_records(3);
  game_active=0;replay_active=1;stays_records(3);
  replay_active=0;settings_active=0;stays_records(3);
  settings_active=1;records_cs_n=0;records_sclk=1;records_mosi=0;stays_records(3);
  ck(!cs_n&&sclk&&!mosi,"in-progress record pins retained");
  records_cs_n=1;stays_records(3);records_sclk=0;start_config();
  records_cs_n=0;records_sclk=1;records_mosi=0;
  ck(cs_n&&!sclk&&mosi==config_mosi,"inactive records pins disconnected");
  settings_active=0;game_active=1;storage_busy=1;repeat(3)begin tick;ck(config_grant,"grant held throughout accepted config operation");end
  config_active=0;config_cs_n=0;tick;ck(config_grant,"config release waits for CS high");
  config_cs_n=1;config_sclk=1;tick;ck(config_grant,"config release waits for SCLK low");
  config_sclk=0;tick;ck(!config_grant&&!records_rst_n&&cs_n&&!sclk,"idle completion gap");
  records_cs_n=1;records_sclk=0;records_initialized=0;records_idle=0;tick;
  ck(records_rst_n,"record driver restarts after configuration save");
  settings_active=1;game_active=0;storage_busy=0;config_active=1;
  stays_records(4);records_init_error=8'h10;start_config();
  ck(config_owner,"record boot failure does not prevent config ownership");
  rst_n=0;tick;ck(cs_n&&!sclk&&!records_rst_n&&!config_grant,"reset interrupts into idle bus only");
  rst_n=1;config_initialized=0;config_active=1;tick;ck(config_grant&&!records_rst_n,"warm reset always reloads config first");
  $display("PASS spi_owner checks=%0d",checks);$finish;
 end
 initial begin #100000;$fatal(1,"watchdog");end
endmodule
