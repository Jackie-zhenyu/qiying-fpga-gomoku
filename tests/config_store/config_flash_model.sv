`timescale 1ns/1ps
// Independent pin-level NOR model: mode 0, 4-byte addresses, WREN, WIP,
// 1->0 page programming and block erase. Memory persists across host resets.
module config_flash_model #(
 parameter [31:0] BASE=32'h01c00000,
 parameter integer BYTES=4194304,
 parameter integer PROGRAM_POLLS=2,ERASE_POLLS=3
)(input wire cs_n,sclk,mosi,output reg miso,
 input wire stuck_busy,protect_writes,bad_id);
 reg [7:0] memory[0:BYTES-1];reg [7:0] input_shift,command,received_byte;
 reg [7:0] program_buffer[0:255];
 reg [31:0] address;integer bits,bytes_received,program_count,busy_polls;
 reg wel;integer transactions,programs,erases,i,j;reg [7:0] reply;
 function [7:0] read_reply(input integer offset);
  begin
   case(command)
    8'h9f:case(offset)0:read_reply=bad_id?8'hef:8'hc8;1:read_reply=8'h40;2:read_reply=8'h19;default:read_reply=8'hff;endcase
    8'h05:read_reply={6'd0,wel,(busy_polls>0||stuck_busy)};
    8'h35:read_reply=8'h02; // QE remains set, as for a Quad boot image.
    8'h15:read_reply=8'h00;
    8'h13:if(address+offset>=BASE&&address+offset<BASE+BYTES)read_reply=memory[address+offset-BASE];
      else read_reply=8'hff; // The final falling edge may prefetch an unused bit.
    default:read_reply=8'hff;
   endcase
  end
 endfunction
 initial begin
  for(i=0;i<BYTES;i=i+1)memory[i]=8'hff;
  miso=0;wel=0;busy_polls=0;transactions=0;programs=0;erases=0;
  bits=0;bytes_received=0;input_shift=0;command=0;address=0;program_count=0;
 end
 always @(negedge cs_n)begin
  bits=0;bytes_received=0;input_shift=0;command=0;address=0;program_count=0;
  transactions=transactions+1;miso=0;
 end
 always @(posedge sclk)if(!cs_n)begin
  if(command==8'h13&&bits>=40&&(address+(bits-40)/8<BASE||address+(bits-40)/8>=BASE+BYTES))begin
   $display("MODEL sampled out-of-range READ %h",address+(bits-40)/8);$fatal;
  end
  input_shift={input_shift[6:0],mosi};bits=bits+1;
  if(bits%8==0)begin
   received_byte=input_shift;
   if(bytes_received==0)begin
    command=received_byte;
    if(command!=8'h13&&command!=8'h12&&command!=8'hdc&&command!=8'h06&&
       command!=8'h05&&command!=8'h35&&command!=8'h15&&command!=8'h9f)begin
      $display("MODEL forbidden command %h",command);$fatal;
    end
   end else if((command==8'h13||command==8'h12||command==8'hdc)&&bytes_received<=4)
    address={address[23:0],received_byte};
   else if(command==8'h12)begin
    if(program_count>=256)begin $display("MODEL page overrun");$fatal;end
    program_buffer[program_count]=received_byte;program_count=program_count+1;
   end
   bytes_received=bytes_received+1;
  end
 end
 always @(negedge sclk)if(!cs_n)begin
  if(command==8'h13&&bits>=40)begin reply=read_reply((bits-40)/8);miso=reply[7-(bits-40)%8];end
  else if((command==8'h05||command==8'h35||command==8'h15||command==8'h9f)&&bits>=8)begin
   reply=read_reply((bits-8)/8);miso=reply[7-(bits-8)%8];
  end else miso=0;
 end
 always @(posedge cs_n)begin
  miso=0;
  if(bits%8==0)begin
   if(command==8'h06&&bytes_received==1&&busy_polls==0&&!stuck_busy)wel=1;
   if(command==8'h05&&bytes_received>=2&&busy_polls>0)busy_polls=busy_polls-1;
   if(command==8'h12&&bytes_received>=6&&wel&&busy_polls==0&&!stuck_busy&&!protect_writes)begin
    if(address<32'h01be0000||address+program_count>32'h01c00000)begin $display("MODEL config program outside owned range");$fatal;end
    if(address<BASE||address+program_count>BASE+BYTES||address[7:0]+program_count>256)begin
     $display("MODEL bad program range %h len %0d",address,program_count);$fatal;
    end
    for(j=0;j<program_count;j=j+1)memory[address-BASE+j]=memory[address-BASE+j]&program_buffer[j];
    wel=0;busy_polls=PROGRAM_POLLS;programs=programs+1;
   end
   if(command==8'hdc&&bytes_received==5&&wel&&busy_polls==0&&!stuck_busy&&!protect_writes)begin
    if(address<32'h01be0000||address+65536>32'h01c00000)begin $display("MODEL config erase outside owned range");$fatal;end
    if(address<BASE||address+65536>BASE+BYTES||address[15:0]!=0)begin $display("MODEL bad erase %h",address);$fatal;end
    for(j=0;j<65536;j=j+1)memory[address-BASE+j]=8'hff;
    wel=0;busy_polls=ERASE_POLLS;erases=erases+1;
   end
  end
 end
endmodule
