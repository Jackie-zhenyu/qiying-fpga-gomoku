`timescale 1ns/1ps
module tb_spi_owner;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,settings_active=1,game_active=0,replay_active=0,storage_busy=0;
 reg config_save_valid=0,config_done_ready=1,record_save_valid=0,record_load_valid=0,record_done_ready=0;
 reg [255:0] config_save_data=0;
 reg [2015:0] metadata=0;
 wire config_initialized,config_valid,config_active,config_save_ready,config_done_valid;
 wire [255:0] config_data;wire [7:0] config_error,config_done_error;
 wire config_cs_n,config_sclk,config_mosi,records_cs_n,records_sclk,records_mosi;
 wire config_grant,records_rst_n,config_owner,cs_n,sclk,mosi,miso;
 wire records_initialized,record_save_ready,record_load_ready,record_done;
 wire [7:0] records_init_error,record_error;wire [3:0] slot_valid;wire [31:0] slot_moves;
 wire records_idle=record_save_ready&&record_load_ready;
 // Testbench-only acceleration: deliver three synchronous reset clocks, then
 // pause the quiescent records clock while reset remains asserted. Otherwise
 // its 256-byte synchronous reset array is redundantly cleared millions of
 // times during each full config-sector scan. All active clocks stay aligned.
 reg [1:0] record_reset_edges=0;
 always @(posedge clk)begin
  if(records_rst_n)record_reset_edges<=0;
  else if(record_reset_edges<3)record_reset_edges<=record_reset_edges+1'b1;
 end
 wire records_clk=clk&&(records_rst_n||record_reset_edges<3);
 reg stuck_busy=0,protect_writes=0,bad_id=0;
 reg [7:0] snapshot[0:524287];
 integer checks=0,i,old_programs,old_erases;
 localparam [255:0] A={8{32'h12345678}},B={8{32'h89abcdef}},C={8{32'hf0e1d2c3}};
 qy_peripheral_config_store #(.HALF_CYCLES(4),.BUSY_TIMEOUT(5000),.STREAM_TIMEOUT(5000)) cfg(
  .clk(clk),.rst_n(rst_n),.grant(config_grant),.initialized(config_initialized),.config_valid(config_valid),.config_data(config_data),.error(config_error),
  .save_valid(config_save_valid),.save_ready(config_save_ready),.save_data(config_save_data),.done_valid(config_done_valid),.done_ready(config_done_ready),.done_error(config_done_error),
  .active(config_active),.cs_n(config_cs_n),.sclk(config_sclk),.mosi(config_mosi),.miso(miso));
 qy_storage_records #(.RECORD_SHIFT(16),.IMAGE_WIDTH(4),.IMAGE_HEIGHT(2),.HALF_CYCLES(4),.BUSY_TIMEOUT(5000),.STREAM_TIMEOUT(5000)) records(
  .clk(records_clk),.rst_n(records_rst_n),.initialized(records_initialized),.init_error(records_init_error),.slot_valid(slot_valid),.slot_moves(slot_moves),
  .save_valid(record_save_valid),.save_ready(record_save_ready),.save_slot(2'd0),.save_metadata(metadata),
  .image_in_valid(1'b1),.image_in_ready(),.image_in_data(8'h66),
  .load_valid(record_load_valid),.load_ready(record_load_ready),.load_slot(2'd0),.loaded_header(),
  .image_out_valid(),.image_out_ready(1'b1),.image_out_data(),
  .done_valid(record_done),.done_ready(record_done_ready),.done_is_load(),.done_error(record_error),
  .cs_n(records_cs_n),.sclk(records_sclk),.mosi(records_mosi),.miso(miso));
 qy_peripheral_spi_owner owner(.*);
 always @(posedge clk)if(rst_n&&cfg.state==cfg.CLASSIFY)
  $display("PROGRESS config sector=%0d mode=%0d t=%0t",cfg.sector,cfg.scan_mode,$time);
 always @(posedge records_initialized)$display("PROGRESS records boot finished t=%0t slots=%h",$time,slot_valid);
 shared_spi_flash_model #(.BASE(32'h01bd0000),.BYTES(786432)) model(.*);
 always @(posedge clk)if(rst_n)begin
  if(config_grant&&records_rst_n)begin $display("FAIL simultaneous SPI grants");$fatal;end
  if(!cs_n&&!(config_grant||records_rst_n))begin $display("FAIL transaction without owner");$fatal;end
 end
 always @(posedge cs_n)if(rst_n&&(model.command==8'h12||model.command==8'hdc)&&model.bytes_received>=5)begin
  if(config_grant&&model.address>=32'h01c00000)begin $display("FAIL config writes records");$fatal;end
  if(records_rst_n&&model.address<32'h01c00000)begin $display("FAIL records writes config");$fatal;end
 end
 task check(input bit good,input string message);
  begin checks=checks+1;if(!good)begin $display("FAIL %s t=%t owner=%0d cfgstate=%0d recstate=%0d",message,$time,owner.owner,cfg.state,records.state);$fatal;end end
 endtask
 task start_config(input [255:0] data);
  begin
   @(negedge clk);check(config_save_ready,"configuration controller ready");config_save_data=data;config_save_valid=1;
   @(negedge clk);config_save_valid=0;check(config_active,"configuration accepted request");
  end
 endtask
 task finish_config(input [7:0] expected);
  begin wait(config_done_valid);@(negedge clk);check(config_done_error==expected,"configuration completion status");check(cs_n&&!sclk,"handoff only after final CS high");end
 endtask
 task records_booted;
  begin wait(records_initialized&&records_idle);@(negedge clk);check(records_rst_n&&!config_grant&&!config_owner,"records rescan owns bus and returns idle");end
 endtask
 initial begin
  #1;for(i=0;i<65536;i=i+1)begin model.memory[i]=8'ha5;model.memory[720896+i]=8'h5a;end
  metadata[9*8+:8]=5;metadata[10*8+:8]=1;metadata[11*8+:8]=2;metadata[12*8+:8]=3;
  repeat(8)@(negedge clk);rst_n=1;repeat(10)@(negedge clk);
  check(config_grant&&!records_rst_n&&config_owner,"boot grants config and holds records reset");
  wait(config_initialized);@(negedge clk);check(!config_active&&config_cs_n,"boot config releases safely");
  wait(records_rst_n&&!records_cs_n);start_config(A);
  check(!records_initialized&&!config_grant,"config request during records boot waits");
  wait(records_initialized);wait(config_grant);@(negedge clk);
  check(!records_rst_n&&config_owner,"record scan complete before config takeover");
  finish_config(0);check(config_valid&&config_data==A,"first configuration persisted");records_booted;
  $display("PASS real boot scan not preempted checks=%0d",checks);

  settings_active=0;game_active=1;storage_busy=1;
  @(negedge clk);record_save_valid=1;@(negedge clk);record_save_valid=0;
  wait(records.state==records.ERASE_WAIT);settings_active=1;game_active=0;start_config(B);
  repeat(20)@(negedge clk);check(!config_grant&&records_rst_n,"active record save refuses config takeover");
  wait(record_done);@(negedge clk);check(record_error==0&&slot_valid[0]&&slot_moves[7:0]==3,"actual record save completed correctly");
  for(i=0;i<524288;i=i+1)snapshot[i]=model.memory[196608+i];
  storage_busy=0;repeat(20)@(negedge clk);
  check(!config_grant&&records_rst_n&&!records_idle,"unacknowledged record completion cannot be preempted");
  record_done_ready=1;@(negedge clk);record_done_ready=0;
  wait(config_grant);@(negedge clk);check(!records_rst_n&&!records_initialized,"config takeover resets record cache");
  finish_config(0);check(config_data==B,"queued config saves after record acknowledgement");records_booted;
  check(slot_valid[0]&&slot_moves[7:0]==3,"record directory restored by real rescan");
  for(i=0;i<524288;i=i+1)check(model.memory[196608+i]==snapshot[i],"all record bytes preserved through config save");
  $display("PASS actual record save, held completion, config handoff and directory rescan checks=%0d",checks);

  bad_id=1;old_programs=model.programs;old_erases=model.erases;start_config(C);finish_config(8'h10);
  wait(records_init_error!=0);@(negedge clk);
  check(!records_initialized&&records_rst_n&&!config_grant,"failed config returns bus; records bad-ID exit remains usable");
  check(model.programs==old_programs&&model.erases==old_erases,"bad identity never writes either region");
  bad_id=0;start_config(C);wait(config_grant);finish_config(0);records_booted;
  check(config_data==C&&slot_valid[0]&&slot_moves[7:0]==3,"configuration retry after records BOOT_FAILED succeeds and rescans");
  for(i=0;i<65536;i=i+1)begin check(model.memory[i]==8'ha5,"preceding guard unchanged");check(model.memory[720896+i]==8'h5a,"following guard unchanged");end
  $display("PASS peripheral_spi_owner checks=%0d actual_config_and_records=1 actual_pin_spi=1",checks);$finish;
 end
 initial begin #2000000000;$display("WATCHDOG owner=%0d cfgstate=%0d recstate=%0d",owner.owner,cfg.state,records.state);$fatal;end
endmodule
