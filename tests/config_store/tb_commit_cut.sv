`timescale 1ns/1ps
module tb_commit_cut;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,grant=0,save_valid=0,done_ready=0;
 reg [255:0] save_data=0;
 wire initialized,config_valid,save_ready,done_valid,active,cs_n,sclk,mosi,miso;
 wire [255:0] config_data;wire [7:0] error,done_error;
 reg stuck_busy=0,protect_writes=0,bad_id=0;
 integer checks=0,i,j,old_transactions,old_erases,old_programs;
 reg [7:0] clean[0:131071];
 localparam [255:0] A={8{32'h12345678}};
 localparam [255:0] B={8{32'h89abcdef}};
 localparam [255:0] C={8{32'hf0e1d2c3}};
 qy_peripheral_config_store #(.HALF_CYCLES(4),.BUSY_TIMEOUT(5000),.STREAM_TIMEOUT(5000)) dut(.*);
 config_flash_model #(.BASE(32'h01bd0000),.BYTES(262144)) model(.*);
 always @(posedge clk)if(rst_n&&dut.state==dut.CLASSIFY)
  $display("PROGRESS sector=%0d mode=%0d t=%0t valid=%0d safe=%0d",dut.sector,dut.scan_mode,$time,dut.record_valid,dut.record_safe);
 task check(input bit good,input string message);
  begin checks=checks+1;if(!good)begin $display("FAIL %s at %t state=%0d err=%h done=%h",message,$time,dut.state,error,done_error);$fatal;end end
 endtask
 task boot;
  begin
   @(negedge clk);rst_n=0;save_valid=0;done_ready=0;grant=0;
   repeat(8)@(negedge clk);rst_n=1;
   old_transactions=model.transactions;
   repeat(20)@(negedge clk);
   check(!initialized&&active&&cs_n&&!sclk,"boot requests owner but never uses ungranted SPI");
   check(model.transactions==old_transactions,"no commands before startup grant");
   grant=1;wait(initialized);@(negedge clk);$display("PROGRESS boot finished t=%0t error=%h",$time,error);
   check(!active&&cs_n&&save_ready,"boot releases CS and ownership");
  end
 endtask
 task start_save(input [255:0] data);
  begin
   @(negedge clk);check(save_ready,"save only accepted when ready");
   save_data=data;save_valid=1;@(negedge clk);save_valid=0;save_data=~data;
   check(active&&!save_ready,"accepted save holds owner request and snapshots payload");
  end
 endtask
 task completed(input [7:0] expected);
  begin
   wait(done_valid);@(negedge clk);check(done_error==expected,"save completion code");
   check(!active&&cs_n&&!sclk,"completion releases SPI after CS high");
   repeat(8)@(negedge clk);check(done_valid&&done_error==expected,"completion stable until acknowledgement");
   done_ready=1;@(negedge clk);done_ready=0;check(save_ready,"completion handshake returns ready");
  end
 endtask
 task restore_clean;
  begin
   @(negedge clk);rst_n=0;repeat(5)@(negedge clk);
   for(i=0;i<131072;i=i+1)model.memory[65536+i]=clean[i];
   model.wel=0;model.busy_polls=0;
  end
 endtask
 function [31:0] crc_byte(input [31:0] previous,input [7:0] value);
  reg [31:0] v;integer b;
  begin v=previous^{24'd0,value};for(b=0;b<8;b=b+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_byte=v;end
 endfunction
 task fixture_record(input integer bank,input [31:0] seq,input [255:0] data);
  integer base,n;reg [31:0] c,inv;reg [63:0] magic,cm;
  begin
   base=65536+bank*65536;magic=64'h3130474643505951;cm=64'h54494d4d4f435951;inv=~seq;
   for(n=0;n<65536;n=n+1)model.memory[base+n]=8'hff;
   for(n=0;n<8;n=n+1)begin model.memory[base+n]=magic[n*8+:8];model.memory[base+256+n]=cm[n*8+:8];end
   for(n=0;n<4;n=n+1)begin model.memory[base+8+n]=seq[n*8+:8];model.memory[base+12+n]=inv[n*8+:8];model.memory[base+264+n]=seq[n*8+:8];end
   for(n=0;n<32;n=n+1)model.memory[base+16+n]=data[n*8+:8];
   c=32'hffffffff;for(n=0;n<48;n=n+1)c=crc_byte(c,model.memory[base+n]);c=~c;
   for(n=0;n<4;n=n+1)begin model.memory[base+48+n]=c[n*8+:8];model.memory[base+268+n]=c[n*8+:8];end
  end
 endtask
 task outside_unchanged;
  begin for(j=0;j<65536;j=j+1)begin
   check(model.memory[j]==8'ha5,"preceding model/gap sector unchanged");
   check(model.memory[196608+j]==8'h5a,"following game-record sector unchanged");
  end end
 endtask
 initial begin
  #1;for(i=0;i<65536;i=i+1)begin model.memory[i]=8'ha5;model.memory[196608+i]=8'h5a;end
  fixture_record(0,1,A);fixture_record(1,2,B);
  boot;check(config_valid&&config_data==B&&error==0,"fixture newest committed record");
  start_save(C);
  wait(model.command==8'h12&&model.address==32'h01be0100&&model.program_count==9);
  @(negedge clk);rst_n=0;repeat(6)@(negedge clk);
  check(model.memory[65536+256]==8'h51&&model.memory[65536+271]==8'hff,"actual interrupted commit left partial physical bytes");
  boot;check(config_valid&&config_data==B&&error==0,"partial compatible commit does not supersede old copy");
  old_erases=model.erases;old_programs=model.programs;
  repeat(100)@(negedge clk);check(model.erases==old_erases&&model.programs==old_programs,"no implicit repair write after interrupted commit");
  @(negedge clk);rst_n=0;model.memory[65536+256]=8'h50;
  boot;check(config_valid&&config_data==B&&error==8'h12,"incompatible commit fails ownership while preserving old copy");
  outside_unchanged;
  $display("PASS config_store_commit_cut checks=%0d programs=%0d erases=%0d actual_pin_spi=1",checks,model.programs,model.erases);$finish;
 end
 initial begin #1000000000;$display("TESTBENCH WATCHDOG state=%0d",dut.state);$fatal;end
endmodule
