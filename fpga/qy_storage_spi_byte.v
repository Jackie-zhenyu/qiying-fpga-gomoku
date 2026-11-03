`timescale 1ns/1ps
`default_nettype none
// SPI mode 0. CS belongs to the command controller. HALF_CYCLES >= 4
// gives the two-stage MISO synchronizer time to settle before sampling.
module qy_storage_spi_byte #(parameter HALF_CYCLES=8)(
 input wire clk,rst_n,start,input wire [7:0] tx,
 output reg busy,done,output reg [7:0] rx,
 output reg sclk,mosi,input wire miso
);
 (* ASYNC_REG="TRUE" *) reg miso_meta,miso_sync;
 reg [7:0] shift;reg [2:0] bit_number;reg [15:0] divider;
 always @(posedge clk)begin
  if(!rst_n)begin miso_meta<=0;miso_sync<=0;end
  else begin miso_meta<=miso;miso_sync<=miso_meta;end
 end
 always @(posedge clk)begin
  if(!rst_n)begin busy<=0;done<=0;rx<=0;sclk<=0;mosi<=0;shift<=0;bit_number<=0;divider<=0;end
  else begin
   done<=0;
   if(!busy)begin
    sclk<=0;
    if(start)begin busy<=1;shift<=tx;mosi<=tx[7];rx<=0;bit_number<=7;divider<=HALF_CYCLES-1;end
   end else if(divider!=0)divider<=divider-1'b1;
   else begin
    divider<=HALF_CYCLES-1;
    if(!sclk)begin sclk<=1;rx<={rx[6:0],miso_sync};end
    else begin
     sclk<=0;
     if(bit_number==0)begin busy<=0;done<=1;end
     else begin bit_number<=bit_number-1'b1;shift<={shift[6:0],1'b0};mosi<=shift[6];end
    end
   end
  end
 end
endmodule
`default_nettype wire
