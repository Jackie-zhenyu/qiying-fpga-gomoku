`timescale 1ns/1ps
`default_nettype none
// A frozen 192x32 record vector with local 16-word banks. Wide captures use
// twelve clocks; indexed writes first latch data/address beside the selected
// bank. Readers must use busy/done before consuming a completed snapshot.
// capture_start restarts an in-flight capture, as required by the overlay.
// Reset initializes control immediately and clears payload banks in twelve
// clocks. Payload is invalid while busy; no thousands-bit reset broadcast is
// needed. All callers gate publication or mask construction until completion.
module qy_banked_records(
 input wire clk,rst_n,capture_start,capture_zero,
 input wire [6143:0] capture_data,
 input wire write_valid,input wire [7:0] write_index,input wire [31:0] write_data,
 output wire busy,output reg done,output wire [6143:0] records
);
 reg capturing,initializing;reg [3:0] capture_bank;
 wire [11:0] word_pending;
 assign busy=capturing||(|word_pending);
 always @(posedge clk)begin
  if(!rst_n)begin capturing<=1;initializing<=1;capture_bank<=0;done<=0;end
  else begin
   done<=0;
   if(capture_start)begin capturing<=1;initializing<=0;capture_bank<=0;end
   else if(capturing)begin
    if(capture_bank==11)begin capturing<=0;initializing<=0;done<=1;end
    else capture_bank<=capture_bank+1'b1;
   end
  end
 end
 genvar bank,slot;
 generate for(bank=0;bank<12;bank=bank+1)begin:local_bank
  reg pending;reg [3:0] column;reg [31:0] data;
  assign word_pending[bank]=pending;
  always @(posedge clk)begin
   if(!rst_n)begin pending<=0;column<=0;data<=0;end
   else begin
    pending<=write_valid&&!capture_start&&!capturing&&write_index[7:4]==bank;
    if(write_valid&&write_index[7:4]==bank)begin column<=write_index[3:0];data<=write_data;end
   end
  end
  for(slot=0;slot<16;slot=slot+1)begin:word
   reg [31:0] value;
   assign records[(bank*16+slot)*32+:32]=value;
   always @(posedge clk)begin
    if(capturing&&!capture_start&&capture_bank==bank)
     value<=initializing||capture_zero?32'd0:capture_data[(bank*16+slot)*32+:32];
    else if(pending&&!capturing&&!capture_start&&column==slot)value<=data;
   end
  end
 end endgenerate
endmodule

// A two-stage local read replaces one scattered 192:1 word mux. Address and
// data advance every clock. The caller leaves two edges before using a new
// address, and holds the underlying frozen snapshot during that read.
module qy_banked_record_reader(
 input wire clk,input wire [6143:0] records,input wire [7:0] index,
 output reg [31:0] data
);
 reg [3:0] bank_q;
 reg [31:0] local_word[0:11];
 genvar k;
 generate for(k=0;k<12;k=k+1)begin:read_bank
  always @(posedge clk)local_word[k]<=records[k*512+index[3:0]*32+:32];
 end endgenerate
 always @(posedge clk)begin bank_q<=index[7:4];data<=bank_q<12?local_word[bank_q]:32'd0;end
endmodule
`default_nettype wire
