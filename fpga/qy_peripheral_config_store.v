`timescale 1ns/1ps
`default_nettype none
// Two independent 64 KiB sectors, never the boot/model/game-record regions.
// Header page: QYPCFG01, sequence LE, ~sequence LE, 32 payload bytes LE,
// CRC32/ISO-HDLC over bytes 0..47, then FF. Commit at offset 256: QYCOMMIT,
// sequence LE, header CRC LE. Every other byte in the whole sector MUST be FF.
// An exact CRC-valid header with a partly programmed compatible commit is an
// owned incomplete record. An unrecognizable/torn header is read-only: retain
// any other valid copy, report UNKNOWN, and never erase uncertain contents.
// Arbiter contract: grant is held from start until active deasserts. No flash
// command is issued before grant. done_valid is held with CS high, active low.
module qy_peripheral_config_store #(
 parameter HALF_CYCLES=8,
 parameter [31:0] BUSY_TIMEOUT=300000000, STREAM_TIMEOUT=100000000
)(
 input wire clk,rst_n,grant,
 output reg initialized,config_valid,
 output reg [255:0] config_data,output reg [7:0] error,
 input wire save_valid,output wire save_ready,input wire [255:0] save_data,
 output wire done_valid,input wire done_ready,output reg [7:0] done_error,
 output wire active,output wire cs_n,sclk,mosi,input wire miso
);
 localparam [31:0] REGION_BEGIN=32'h01be0000, REGION_END=32'h01c00000;
 localparam [63:0] MAGIC=64'h3130474643505951, COMMIT_MAGIC=64'h54494d4d4f435951;
 localparam WAIT_GRANT=0,ID_CMD=1,ID_WAIT=2,SCAN_START=3,READ_CMD=4,READ_WAIT=5,
  CLASSIFY=6,SELECT=7,IDLE=8,ERASE_CMD=9,ERASE_WAIT=10,BUILD_CRC=11,
  HEADER_CMD=12,HEADER_SEND=13,HEADER_WAIT=14,COMMIT_CMD=15,COMMIT_SEND=16,
  COMMIT_WAIT=17,COMPLETE=18;
 localparam BOOT_SCAN=0,SAVE_SCAN=1,ERASE_SCAN=2,HEADER_SCAN=3,COMMIT_SCAN=4;
 localparam [7:0] E_ID=8'h10,E_READ=8'h11,E_UNKNOWN=8'h12,E_SEQUENCE=8'h13,
  E_ERASE=8'h20,E_VERIFY=8'h21,E_PROGRAM=8'h22;
 reg [4:0] state;reg [2:0] scan_mode;
 reg saving,id_ok,sector,target;
 reg [15:0] page_offset;reg [8:0] position;
 reg [23:0] jedec;
 reg [415:0] header;
 reg [127:0] commit;
 reg blank,tail_ff;
 reg [31:0] crc,write_sequence,write_crc;
 reg [255:0] write_data;
 reg [1:0] valid_copy,safe_copy;
 reg [31:0] seq0,seq1;
 reg [255:0] data0,data1;
 wire [31:0] scan_base=REGION_BEGIN+(sector?32'h10000:32'd0);
 wire [31:0] target_base=REGION_BEGIN+(target?32'h10000:32'd0);
 wire [16:0] read_offset={1'b0,page_offset}+{8'd0,position};
 wire [31:0] h_sequence=header[95:64],h_crc=header[415:384];
 wire [255:0] h_data=header[383:128];
 wire header_good=header[63:0]==MAGIC && header[127:96]==~h_sequence && h_crc==~crc;
 wire [127:0] expected_commit={h_crc,h_sequence,COMMIT_MAGIC};
 wire commit_good=commit==expected_commit;
 wire commit_compatible=(commit & expected_commit)==expected_commit;
 wire record_valid=header_good&&tail_ff&&commit_good;
 wire record_safe=blank||(header_good&&tail_ff&&commit_compatible);
 wire [31:0] seq_delta=seq1-seq0;
 wire ambiguous=valid_copy==2'b11&&((seq_delta==0&&data0!=data1)||seq_delta==32'h80000000);
 wire choose_one=valid_copy[1]&&(!valid_copy[0]||(seq_delta!=0&&!seq_delta[31]));
 wire any_valid=|valid_copy;
 wire [31:0] latest_sequence=choose_one?seq1:seq0;
 wire [255:0] latest_data=choose_one?data1:data0;

 function [31:0] crc_byte(input [31:0] old_crc,input [7:0] value);
  reg [31:0] v;integer k;
  begin v=old_crc^{24'd0,value};for(k=0;k<8;k=k+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_byte=v;end
 endfunction
 function [7:0] header_byte(input [8:0] at);
  reg [31:0] inv_sequence;
  begin
   inv_sequence=~write_sequence;
   if(at<8)header_byte=MAGIC[at*8+:8];
   else if(at<12)header_byte=write_sequence[(at-8)*8+:8];
   else if(at<16)header_byte=inv_sequence[(at-12)*8+:8];
   else if(at<48)header_byte=write_data[(at-16)*8+:8];
   else if(at<52)header_byte=write_crc[(at-48)*8+:8];
   else header_byte=8'hff;
  end
 endfunction
 function [7:0] commit_byte(input [4:0] at);
  reg [127:0] bytes;
  begin bytes={write_crc,write_sequence,COMMIT_MAGIC};commit_byte=bytes[at*8+:8];end
 endfunction

 reg f_cmd_valid;wire f_cmd_ready;reg [2:0] f_op;
 reg [31:0] f_address;reg [8:0] f_length;
 wire f_in_ready,f_out_valid,f_done;wire [7:0] f_out,f_error;
 wire f_in_valid=state==HEADER_SEND||state==COMMIT_SEND;
 wire [7:0] f_in=state==COMMIT_SEND?commit_byte(position[4:0]):header_byte(position);
 wire f_done_ready=state==ID_WAIT||state==READ_WAIT||state==ERASE_WAIT||
  state==HEADER_WAIT||state==COMMIT_WAIT;
 assign save_ready=state==IDLE;
 assign done_valid=state==COMPLETE;
 assign active=state!=IDLE&&state!=COMPLETE;
 qy_storage_flash #(.REGION_BEGIN(REGION_BEGIN),.REGION_END(REGION_END),
  .HALF_CYCLES(HALF_CYCLES),.BUSY_TIMEOUT(BUSY_TIMEOUT),.STREAM_TIMEOUT(STREAM_TIMEOUT)) flash(
  .clk(clk),.rst_n(rst_n),.allow_write(id_ok&&saving&&grant),
  .cmd_valid(f_cmd_valid&&grant),.cmd_ready(f_cmd_ready),.cmd_op(f_op),
  .cmd_address(f_address),.cmd_length(f_length),.in_valid(f_in_valid),
  .in_ready(f_in_ready),.in_data(f_in),.out_valid(f_out_valid),.out_ready(1'b1),.out_data(f_out),
  .done_valid(f_done),.done_ready(f_done_ready),.error(f_error),
  .cs_n(cs_n),.sclk(sclk),.mosi(mosi),.miso(miso));
 task launch(input [2:0] op,input [31:0] addr,input [8:0] count,input [4:0] next_state);
  begin f_op<=op;f_address<=addr;f_length<=count;f_cmd_valid<=1;position<=0;state<=next_state;end
 endtask
 task finish(input [7:0] why);
  begin error<=why;done_error<=why;
   if(saving)state<=COMPLETE;else begin initialized<=1;state<=IDLE;end
  end
 endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=WAIT_GRANT;scan_mode<=BOOT_SCAN;saving<=0;initialized<=0;config_valid<=0;
   config_data<=0;error<=0;done_error<=0;id_ok<=0;sector<=0;target<=0;
   page_offset<=0;position<=0;jedec<=0;header<=0;commit<=0;blank<=1;tail_ff<=1;
   crc<=32'hffffffff;write_sequence<=0;write_crc<=0;write_data<=0;
   valid_copy<=0;safe_copy<=0;seq0<=0;seq1<=0;data0<=0;data1<=0;
   f_cmd_valid<=0;f_op<=0;f_address<=0;f_length<=0;
  end else begin
   if(f_cmd_valid&&f_cmd_ready&&grant)f_cmd_valid<=0;
   case(state)
    WAIT_GRANT:if(grant)begin id_ok<=0;jedec<=0;state<=ID_CMD;end
    ID_CMD:if(grant&&f_cmd_ready&&!f_cmd_valid)launch(3,0,3,ID_WAIT);
    ID_WAIT:begin
     if(f_out_valid)begin jedec<={jedec[15:0],f_out};position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||position!=3||jedec!=24'hc84019)finish(E_ID);
      else begin id_ok<=1;valid_copy<=0;safe_copy<=0;sector<=0;
       scan_mode<=saving?SAVE_SCAN:BOOT_SCAN;state<=SCAN_START;end
     end
    end
    SCAN_START:begin page_offset<=0;header<=0;commit<=0;blank<=1;tail_ff<=1;crc<=32'hffffffff;state<=READ_CMD;end
    READ_CMD:if(grant&&f_cmd_ready&&!f_cmd_valid)launch(0,scan_base+{16'd0,page_offset},256,READ_WAIT);
    READ_WAIT:begin
     if(f_out_valid)begin
      if(f_out!=8'hff)blank<=0;
      if(read_offset<52)header[read_offset*8+:8]<=f_out;
      if(read_offset<48)crc<=crc_byte(crc,f_out);
      if(read_offset>=256&&read_offset<272)commit[(read_offset-256)*8+:8]<=f_out;
      if((read_offset>=52&&read_offset<256)||read_offset>=272)if(f_out!=8'hff)tail_ff<=0;
      position<=position+1'b1;
     end
     if(f_done)begin
      if(f_error!=0||position!=256)finish(E_READ);
      else if(page_offset==16'hff00)state<=CLASSIFY;
      else begin page_offset<=page_offset+16'd256;state<=READ_CMD;end
     end
    end
    CLASSIFY:case(scan_mode)
     BOOT_SCAN,SAVE_SCAN:begin
      valid_copy[sector]<=record_valid;safe_copy[sector]<=record_safe;
      if(sector)begin seq1<=h_sequence;data1<=h_data;state<=SELECT;end
      else begin seq0<=h_sequence;data0<=h_data;sector<=1;state<=SCAN_START;end
     end
     ERASE_SCAN:if(!blank)finish(E_VERIFY);else begin position<=0;crc<=32'hffffffff;state<=BUILD_CRC;end
     HEADER_SCAN:if(!header_good||!tail_ff||commit!={128{1'b1}}||h_sequence!=write_sequence||h_data!=write_data)finish(E_VERIFY);
      else state<=COMMIT_CMD;
     COMMIT_SCAN:if(!record_valid||h_sequence!=write_sequence||h_data!=write_data)finish(E_VERIFY);
      else begin config_valid<=1;config_data<=write_data;finish(0);end
     default:finish(E_VERIFY);
    endcase
    SELECT:begin
     config_valid<=any_valid&&!ambiguous;config_data<=any_valid&&!ambiguous?latest_data:256'd0;
     if(ambiguous)finish(E_SEQUENCE);
     else if(safe_copy!=2'b11)finish(E_UNKNOWN);
     else if(!saving)finish(0);
     else begin
      target<=any_valid?!choose_one:1'b0;sector<=any_valid?!choose_one:1'b0;
      write_sequence<=any_valid?latest_sequence+1'b1:32'd1;state<=ERASE_CMD;
     end
    end
    IDLE:if(save_valid)begin
     write_data<=save_data;saving<=1;done_error<=0;state<=WAIT_GRANT;
    end
    ERASE_CMD:if(grant&&f_cmd_ready&&!f_cmd_valid)launch(2,target_base,0,ERASE_WAIT);
    ERASE_WAIT:if(f_done)begin
     if(f_error!=0)finish(E_ERASE);else begin sector<=target;scan_mode<=ERASE_SCAN;state<=SCAN_START;end
    end
    BUILD_CRC:begin
     crc<=crc_byte(crc,header_byte(position));position<=position+1'b1;
     if(position==47)begin write_crc<=~crc_byte(crc,header_byte(position));state<=HEADER_CMD;end
    end
    HEADER_CMD:if(grant&&f_cmd_ready&&!f_cmd_valid)launch(1,target_base,256,HEADER_SEND);
    HEADER_SEND:begin
     if(f_in_ready)begin position<=position+1'b1;if(position==255)state<=HEADER_WAIT;end
     if(f_done)state<=HEADER_WAIT;
    end
    HEADER_WAIT:if(f_done)begin
     if(f_error!=0)finish(E_PROGRAM);else begin scan_mode<=HEADER_SCAN;sector<=target;state<=SCAN_START;end
    end
    COMMIT_CMD:if(grant&&f_cmd_ready&&!f_cmd_valid)launch(1,target_base+32'd256,16,COMMIT_SEND);
    COMMIT_SEND:begin
     if(f_in_ready)begin position<=position+1'b1;if(position==15)state<=COMMIT_WAIT;end
     if(f_done)state<=COMMIT_WAIT;
    end
    COMMIT_WAIT:if(f_done)begin
     if(f_error!=0)finish(E_PROGRAM);else begin scan_mode<=COMMIT_SCAN;sector<=target;state<=SCAN_START;end
    end
    COMPLETE:if(done_ready)begin saving<=0;state<=IDLE;end
    default:finish(E_VERIFY);
   endcase
  end
 end
endmodule
`default_nettype wire
