`timescale 1ns/1ps
`default_nettype none
// Two-edge read, matching address-register + synchronous ERAM in the photo
// store. Each 8K-word bank owns a distinct, bank-qualified address register;
// no one low address bit drives every ERAM in the complete photograph.
module qy_photo_ram #(parameter WORDS=1,parameter BANK_BITS=13)(
 input wire clk,input wire [17:0] read_address,
 input wire write_enable,input wire [17:0] write_address,
 input wire [15:0] write_data,output wire [15:0] read_data
);
 localparam BANK_WORDS=1<<BANK_BITS;
 localparam BANKS=(WORDS+BANK_WORDS-1)/BANK_WORDS;
 localparam SELECT_BITS=BANKS>1?$clog2(BANKS):1;
 reg [SELECT_BITS-1:0] select_q,select_d;
 wire [BANKS*16-1:0] outputs;
 always @(posedge clk)begin
  select_q<=read_address>>BANK_BITS;select_d<=select_q;
 end
 assign read_data=select_d<BANKS?outputs[select_d*16+:16]:16'd0;
 genvar bank;
 generate for(bank=0;bank<BANKS;bank=bank+1)begin:local_bank
  localparam DEPTH=(WORDS-bank*BANK_WORDS<BANK_WORDS)?WORDS-bank*BANK_WORDS:BANK_WORDS;
  localparam ADDRESS_BITS=DEPTH>1?$clog2(DEPTH):1;
  (* ram_style="bram" *) reg [15:0] memory[0:DEPTH-1];
  (* keep="true" *) reg [ADDRESS_BITS-1:0] address_q;
  reg [15:0] data_q;
  assign outputs[bank*16+:16]=data_q;
  always @(posedge clk)begin
   address_q<=(read_address>>BANK_BITS)==bank?read_address[ADDRESS_BITS-1:0]:0;
   data_q<=memory[address_q];
   if(write_enable&&(write_address>>BANK_BITS)==bank)
    memory[write_address[ADDRESS_BITS-1:0]]<=write_data;
  end
 end endgenerate
endmodule
`default_nettype wire
