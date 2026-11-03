`timescale 1ns/1ps
`default_nettype none
// PN532 HSU: wake, SAMConfiguration, bounded RF retries, then Type-A polling.
// Host reads UID only. No card authentication or card-memory write operations.
module qy_pn532_host #(
 parameter [63:0] STARTUP_US=100000,WAKE_US=10000,POLL_US=150000,TIMEOUT_US=1000000
)(
 input wire clk,rst_n,input wire [63:0] now_us,
 input wire rx_valid,rx_error,input wire [7:0] rx_data,
 output wire tx_valid,output wire [7:0] tx_data,input wire tx_ready,
 output reg uid_valid,output reg [79:0] uid,output reg [3:0] uid_length,
 output reg ready,fault,output reg [31:0] errors,output reg card_present
);
 localparam BOOT=0,WAKE=1,SETTLE=2,SEND=3,ACK=4,RESPONSE=5,WAIT_POLL=6,FAILED=7;
 reg [2:0] state,operation;reg [7:0] tx_index;reg [63:0] deadline;reg [1:0] retries,absent;
 reg armed;
 wire fack,fvalid,ferror;wire [7:0] flen;wire [511:0] payload;
 qy_pn532_frame parser(.clk(clk),.rst_n(rst_n),.now_us(now_us),.rx_valid(rx_valid),.rx_error(rx_error),
  .rx_data(rx_data),.ack(fack),.valid(fvalid),.error(ferror),.length(flen),.payload(payload));
 wire [7:0] data_len=operation==0?8'd5:operation==1?8'd6:8'd4;
 wire [7:0] command=operation==0?8'h14:operation==1?8'h32:8'h4a;
 wire [7:0] response=command+1'b1;
 wire [7:0] ulen=payload[7*8+:8];
 reg [7:0] out_byte;
 always @* begin
  out_byte=0;
  if(state==WAKE)out_byte=tx_index<2?8'h55:8'h00;
  else case(tx_index)
   0,1:out_byte=0;2:out_byte=8'hff;3:out_byte=data_len;4:out_byte=8'd0-data_len;
   5:out_byte=8'hd4;6:out_byte=command;
   7:out_byte=operation==1?8'h05:8'h01;
   8:out_byte=operation==0?8'h14:operation==1?8'hff:8'h00;
   9:out_byte=operation==2?8'he1:8'h01;
   10:out_byte=operation==0?8'h02:8'h00;
   11:out_byte=operation==1?8'hf5:8'h00;
   default:out_byte=0;
  endcase
 end
 assign tx_valid=state==WAKE||state==SEND;
 assign tx_data=out_byte;
 integer i;
 task failed_attempt;
  begin
   errors<=errors+1'b1;absent<=0;
   if(retries==2)begin state<=FAILED;fault<=1;ready<=0;end
   else begin retries<=retries+1'b1;state<=WAIT_POLL;deadline<=now_us+POLL_US;end
  end
 endtask
 always @(posedge clk)begin
  if(!rst_n)begin
   // A local peripheral restart does not reset the application's timebase.
   // Anchor the settling interval to the most recent reset edge.
   state<=BOOT;operation<=0;tx_index<=0;deadline<=now_us+STARTUP_US;retries<=0;absent<=0;armed<=1;
   uid_valid<=0;uid<=0;uid_length<=0;ready<=0;fault<=0;errors<=0;card_present<=0;
  end else begin
   uid_valid<=0;
   case(state)
    BOOT:if(now_us>=deadline)begin state<=WAKE;tx_index<=0;end
    WAKE:if(tx_ready)begin
     if(tx_index==4)begin state<=SETTLE;deadline<=now_us+WAKE_US;end else tx_index<=tx_index+1'b1;
    end
    SETTLE:if(now_us>=deadline)begin state<=SEND;tx_index<=0;end
    SEND:if(tx_ready)begin
     if(tx_index==data_len+6)begin state<=ACK;deadline<=now_us+TIMEOUT_US;end else tx_index<=tx_index+1'b1;
    end
    ACK:if(fack)begin state<=RESPONSE;deadline<=now_us+TIMEOUT_US;end
     else if(ferror||now_us>=deadline)failed_attempt();
    RESPONSE:begin
     if(ferror||now_us>=deadline)failed_attempt();
     else if(fvalid)begin
      if(payload[15:8]!=response)failed_attempt();
      else if(operation<2)begin
       if(flen!=2)failed_attempt();
       else begin operation<=operation+1'b1;state<=WAIT_POLL;deadline<=now_us+POLL_US;retries<=0;
        if(operation==1)ready<=1;end
      end else if(flen==3&&payload[23:16]==0)begin
       if(absent==1)begin armed<=1;absent<=2;card_present<=0;end else if(absent==0)absent<=1;
       retries<=0;state<=WAIT_POLL;deadline<=now_us+POLL_US;
      end else if(flen>=12&&payload[23:16]==1&&payload[31:24]==1&&
        (ulen==4||ulen==7||ulen==10)&&flen>=8+ulen)begin
       absent<=0;card_present<=1;
       if(armed)begin
        uid<=0;for(i=0;i<10;i=i+1)if(i<ulen)uid[i*8+:8]<=payload[(i+8)*8+:8];
        uid_length<=ulen[3:0];uid_valid<=1;armed<=0;
       end
       retries<=0;state<=WAIT_POLL;deadline<=now_us+POLL_US;
      end else failed_attempt();
     end
    end
    WAIT_POLL:if(now_us>=deadline)begin state<=SEND;tx_index<=0;end
    FAILED:begin ready<=0;end
    default:state<=FAILED;
   endcase
  end
 end
endmodule
`default_nettype wire
