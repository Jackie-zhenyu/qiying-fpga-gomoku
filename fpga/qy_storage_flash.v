`timescale 1ns/1ps
`default_nettype none
// Bounded GD25Q256D SPI operations. Never changes address/QPI/QE/protection
// modes; never issues chip erase. All memory accesses are restricted to
// [REGION_BEGIN, REGION_END). Erase requires 64 KiB alignment; program is
// staged in full before WREN and cannot cross a 256-byte page.
// op: 0 read, 1 page program, 2 erase64K, 3 JEDEC ID, 4/5/6 SR1/SR2/SR3.
module qy_storage_flash #(
 parameter [31:0] REGION_BEGIN=32'h01c00000,REGION_END=32'h02000000,
 parameter HALF_CYCLES=8,
 parameter [31:0] BUSY_TIMEOUT=300000000,STREAM_TIMEOUT=100000000
)(
 input wire clk,rst_n,allow_write,
 input wire cmd_valid,output wire cmd_ready,input wire [2:0] cmd_op,
 input wire [31:0] cmd_address,input wire [8:0] cmd_length,
 input wire in_valid,output wire in_ready,input wire [7:0] in_data,
 output reg out_valid,input wire out_ready,output reg [7:0] out_data,
 output wire done_valid,input wire done_ready,output reg [7:0] error,
 output reg cs_n,output wire sclk,mosi,input wire miso
);
 localparam IDLE=0,COLLECT=1,PREPOLL=2,WREN=3,WEL=4,MAIN=5,POSTPOLL=6,
  TX_START=7,TX_WAIT=8,PUBLISH=9,ADVANCE=10,GAP=11,DISPATCH=12,DONE=13;
 localparam PRE=0,ENABLE=1,CHECK_WEL=2,BODY=3,POST=4;
 reg [3:0] state;reg [2:0] op,kind;
 reg [31:0] address;reg [8:0] length,fill;
 reg [7:0] page[0:255];
 reg [7:0] opcode,status;
 reg use_address;reg [9:0] index,total,read_offset;
 reg [31:0] busy_age,stall_age;reg [15:0] gap_count;
 reg byte_start;wire byte_busy,byte_done;wire [7:0] byte_rx;
 reg [7:0] byte_tx;
 wire is_read=op==0||op>=3;
 wire [32:0] command_end={1'b0,cmd_address}+{24'd0,cmd_length};
 wire [32:0] erase_end={1'b0,cmd_address}+33'd65536;
 wire [9:0] page_end={2'b0,cmd_address[7:0]}+{1'b0,cmd_length};
 wire memory_command=cmd_op<=2;
 wire valid_length=cmd_length!=0&&cmd_length<=256;
 wire command_ok=(cmd_op<=6)&&
  (!memory_command||(cmd_address>=REGION_BEGIN&&
   (cmd_op==2?(cmd_address[15:0]==0&&erase_end<={1'b0,REGION_END}):
    (valid_length&&command_end<={1'b0,REGION_END}))))&&
  (cmd_op!=1||page_end<=256)&&
  ((cmd_op!=1&&cmd_op!=2)||allow_write);
 assign cmd_ready=state==IDLE;
 assign in_ready=state==COLLECT;
 assign done_valid=state==DONE;
 always @* begin
  byte_tx=8'hff;
  if(index==0)byte_tx=opcode;
  else if(use_address&&index<=4)case(index)
   1:byte_tx=address[31:24];2:byte_tx=address[23:16];
   3:byte_tx=address[15:8];default:byte_tx=address[7:0];
  endcase
  else if(kind==BODY&&op==1)byte_tx=page[(index-5)&255];
 end
 qy_storage_spi_byte #(.HALF_CYCLES(HALF_CYCLES)) serial(
  .clk(clk),.rst_n(rst_n),.start(byte_start),.tx(byte_tx),.busy(byte_busy),
  .done(byte_done),.rx(byte_rx),.sclk(sclk),.mosi(mosi),.miso(miso));
 task transaction(input [2:0] k,input [7:0] command,input addr,input [9:0] count,input [9:0] read_at);
  begin kind<=k;opcode<=command;use_address<=addr;total<=count;read_offset<=read_at;
   index<=0;cs_n<=0;state<=TX_START;end
 endtask
 task finish(input [7:0] why);
  begin error<=why;state<=DONE;cs_n<=1;out_valid<=0;end
 endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;op<=0;address<=0;length<=0;fill<=0;kind<=0;opcode<=0;status<=0;
   use_address<=0;index<=0;total<=0;read_offset<=0;busy_age<=0;stall_age<=0;
   gap_count<=0;byte_start<=0;cs_n<=1;out_valid<=0;out_data<=0;error<=0;
  end else begin
   byte_start<=0;
   if(kind==PRE||kind==POST)begin if(busy_age!=32'hffffffff)busy_age<=busy_age+1'b1;end
   if(state==COLLECT||state==PUBLISH)begin if(stall_age!=32'hffffffff)stall_age<=stall_age+1'b1;end
   else stall_age<=0;
   case(state)
    IDLE:begin
     cs_n<=1;out_valid<=0;error<=0;busy_age<=0;stall_age<=0;
     if(cmd_valid)begin
      op<=cmd_op;address<=cmd_address;length<=cmd_op==3?9'd3:cmd_op>=4?9'd1:cmd_length;fill<=0;
      if(!command_ok)finish(8'h01);
      else if(cmd_op==1)state<=COLLECT;
      else if(cmd_op>=4)state<=MAIN;
      else state<=PREPOLL;
     end
    end
    COLLECT:begin
     if(in_valid)begin page[fill[7:0]]<=in_data;fill<=fill+1'b1;stall_age<=0;
      if(fill+1'b1==length)begin state<=PREPOLL;busy_age<=0;end
     end else if(stall_age>=STREAM_TIMEOUT)finish(8'h02);
    end
    PREPOLL:transaction(PRE,8'h05,0,2,1);
    WREN:begin
     if(!allow_write)finish(8'h03);
     else transaction(ENABLE,8'h06,0,1,10'h3ff);
    end
    WEL:transaction(CHECK_WEL,8'h05,0,2,1);
    MAIN:begin
     if((op==1||op==2)&&!allow_write)finish(8'h03);
     else case(op)
      0:transaction(BODY,8'h13,1,10'd5+length,5);
      1:transaction(BODY,8'h12,1,10'd5+length,10'h3ff);
      2:transaction(BODY,8'hdc,1,5,10'h3ff);
      3:transaction(BODY,8'h9f,0,4,1);
      4:transaction(BODY,8'h05,0,2,1);
      5:transaction(BODY,8'h35,0,2,1);
      6:transaction(BODY,8'h15,0,2,1);
      default:finish(8'h01);
     endcase
    end
    POSTPOLL:transaction(POST,8'h05,0,2,1);
    TX_START:if(!byte_busy)begin byte_start<=1;state<=TX_WAIT;end
    TX_WAIT:if(byte_done)begin
     if(index>=read_offset)begin
      if(kind==BODY&&is_read)begin out_data<=byte_rx;out_valid<=1;state<=PUBLISH;end
      else begin status<=byte_rx;state<=ADVANCE;end
     end else state<=ADVANCE;
    end
    PUBLISH:if(out_ready)begin out_valid<=0;state<=ADVANCE;stall_age<=0;end
     else if(stall_age>=STREAM_TIMEOUT)finish(8'h02);
    ADVANCE:if(index+1'b1==total)begin cs_n<=1;gap_count<=2*HALF_CYCLES;state<=GAP;end
     else begin index<=index+1'b1;state<=TX_START;end
    GAP:if(gap_count!=0)gap_count<=gap_count-1'b1;else state<=DISPATCH;
    DISPATCH:case(kind)
     PRE:if(status[0])begin if(busy_age>=BUSY_TIMEOUT)finish(8'h05);else state<=PREPOLL;end
      else if(op==1||op==2)state<=WREN;else state<=MAIN;
     ENABLE:state<=WEL;
     CHECK_WEL:if(status[1])state<=MAIN;else finish(8'h04);
     BODY:if(op==1||op==2)begin state<=POSTPOLL;busy_age<=0;end else finish(0);
     POST:if(status[0])begin if(busy_age>=BUSY_TIMEOUT)finish(8'h05);else state<=POSTPOLL;end
      else finish(0);
     default:finish(8'h06);
    endcase
    DONE:if(done_ready)begin state<=IDLE;out_valid<=0;end
    default:finish(8'h06);
   endcase
  end
 end
endmodule
`default_nettype wire
