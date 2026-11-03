`timescale 1ns/1ps
`default_nettype none
// Four logical slots, two erase-independent records per slot. Payload first,
// CRC-checked header next, full readback, and commit page LAST. There is no
// global directory to corrupt. The older committed record is never erased
// while its replacement is being written. All image bytes are RGB565 LE.
module qy_storage_records #(
 parameter [31:0] REGION_BEGIN=32'h01c00000,
 parameter RECORD_SHIFT=19,IMAGE_WIDTH=640,IMAGE_HEIGHT=360,
 parameter HALF_CYCLES=8,
 parameter [31:0] BUSY_TIMEOUT=300000000,STREAM_TIMEOUT=100000000
)(
 input wire clk,rst_n,
 output reg initialized,output reg [7:0] init_error,
 output reg [3:0] slot_valid,output reg [31:0] slot_moves,
 input wire save_valid,output wire save_ready,input wire [1:0] save_slot,
 input wire [2015:0] save_metadata,
 input wire image_in_valid,output wire image_in_ready,input wire [7:0] image_in_data,
 input wire load_valid,output wire load_ready,input wire [1:0] load_slot,
 output reg [2047:0] loaded_header,
 output wire image_out_valid,input wire image_out_ready,output wire [7:0] image_out_data,
 output wire done_valid,input wire done_ready,output reg done_is_load,output reg [7:0] done_error,
 output wire cs_n,sclk,mosi,input wire miso
);
 localparam [31:0] RECORD_BYTES=32'd1<<RECORD_SHIFT;
 localparam [31:0] REGION_END=REGION_BEGIN+(32'd8<<RECORD_SHIFT);
 localparam [31:0] IMAGE_BYTES=IMAGE_WIDTH*IMAGE_HEIGHT*2;
 localparam ERASE_BLOCKS=1<<(RECORD_SHIFT-16);
 localparam BOOT=0,ID_WAIT=1,RH_CMD=2,RH_WAIT=3,RC_CMD=4,RC_WAIT=5,VALIDATE=6,
  IDLE=7,ERASE_CMD=8,ERASE_WAIT=9,SI_CMD=10,SI_SEND=11,SI_WAIT=12,
  BUILD_HEADER=13,HEADER_CRC=14,HEADER_FINISH=15,WH_CMD=16,WH_SEND=17,WH_WAIT=18,
  VH_CMD=19,VH_WAIT=20,VI_CMD=21,VI_WAIT=22,WC_CMD=23,WC_SEND=24,WC_WAIT=25,
  VC_CMD=26,VC_WAIT=27,LI_CMD=28,LI_WAIT=29,COMPLETE=30,BOOT_FAILED=31;
 reg [5:0] state;
 reg [7:0] header[0:255];reg [127:0] commit_data;
 reg [31:0] sequences[0:3];reg [3:0] active_bank;
 reg [2:0] physical_record;reg [1:0] logical_slot;
 reg [31:0] record_sequence,offset;reg [8:0] page_length,position;
 reg [3:0] erase_index;reg scan_mode,compare_bad,id_ok;
 reg [23:0] jedec;reg [31:0] crc,header_crc,image_crc;
 wire [31:0] record_base=REGION_BEGIN+({29'd0,physical_record}<<RECORD_SHIFT);
 wire [31:0] h_sequence={header[19],header[18],header[17],header[16]};
 wire [31:0] h_image_crc={header[27],header[26],header[25],header[24]};
 wire [31:0] h_crc={header[255],header[254],header[253],header[252]};
 wire [31:0] h_image_size={header[31],header[30],header[29],header[28]};
 wire header_good=header[0]==8'h51&&header[1]==8'h59&&header[2]==8'h53&&header[3]==8'h31&&
  header[4]==1&&header[5]==0&&header[6]==0&&header[7]==1&&header[8]==physical_record[2:1]&&
  header[9]>=5&&header[9]<=13&&header[10]>=1&&header[10]<=2&&header[11]>=1&&header[11]<=2&&
  header[12]<=169&&header[245]==1&&{header[247],header[246]}==IMAGE_WIDTH&&
  {header[249],header[248]}==IMAGE_HEIGHT&&h_image_size==IMAGE_BYTES&&h_crc==~crc;
 wire commit_good=commit_data[31:0]==32'h31435951&&commit_data[63:32]==h_sequence&&
  commit_data[95:64]==h_crc&&commit_data[127:96]==~h_crc;
 wire [31:0] seq_difference=h_sequence-sequences[physical_record[2:1]];
 wire sequence_newer=seq_difference!=0&&!seq_difference[31];
 function [31:0] crc_byte(input [31:0] previous,input [7:0] value);
  reg [31:0] v;integer b;
  begin v=previous^{24'd0,value};for(b=0;b<8;b=b+1)v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_byte=v;end
 endfunction
 function [7:0] commit_byte(input [4:0] at);
  reg [127:0] v;
  begin v={~header_crc,header_crc,record_sequence,32'h31435951};commit_byte=v[at*8+:8];end
 endfunction
 reg f_cmd_valid;wire f_cmd_ready;reg [2:0] f_op;reg [31:0] f_address;reg [8:0] f_length;
 wire f_in_ready,f_out_valid,f_done;wire [7:0] f_out,f_error;
 wire f_in_valid=state==SI_SEND?image_in_valid:(state==WH_SEND||state==WC_SEND);
 wire [7:0] f_in=state==SI_SEND?image_in_data:state==WC_SEND?commit_byte(position[4:0]):header[position[7:0]];
 wire f_out_ready=state==LI_WAIT?image_out_ready:1'b1;
 wire f_done_ready=state==ID_WAIT||state==RH_WAIT||state==RC_WAIT||state==ERASE_WAIT||state==SI_WAIT||
  state==WH_WAIT||state==VH_WAIT||state==VI_WAIT||state==WC_WAIT||state==VC_WAIT||state==LI_WAIT;
 assign image_in_ready=state==SI_SEND&&f_in_ready;
 assign image_out_valid=state==LI_WAIT&&f_out_valid;
 assign image_out_data=f_out;
 assign save_ready=state==IDLE;
 assign load_ready=state==IDLE&&!save_valid;
 assign done_valid=state==COMPLETE;
 qy_storage_flash #(.REGION_BEGIN(REGION_BEGIN),.REGION_END(REGION_END),.HALF_CYCLES(HALF_CYCLES),
  .BUSY_TIMEOUT(BUSY_TIMEOUT),.STREAM_TIMEOUT(STREAM_TIMEOUT)) flash(
  .clk(clk),.rst_n(rst_n),.allow_write(id_ok),.cmd_valid(f_cmd_valid),.cmd_ready(f_cmd_ready),
  .cmd_op(f_op),.cmd_address(f_address),.cmd_length(f_length),
  .in_valid(f_in_valid),.in_ready(f_in_ready),.in_data(f_in),
  .out_valid(f_out_valid),.out_ready(f_out_ready),.out_data(f_out),
  .done_valid(f_done),.done_ready(f_done_ready),.error(f_error),.cs_n(cs_n),.sclk(sclk),.mosi(mosi),.miso(miso));
 task launch(input [2:0] op,input [31:0] addr,input [8:0] count,input [5:0] next_state);
  begin f_op<=op;f_address<=addr;f_length<=count;f_cmd_valid<=1;position<=0;state<=next_state;end
 endtask
 task finish(input [7:0] err);
  begin done_error<=err;state<=COMPLETE;end
 endtask
 task skip_record;
  begin
   if(physical_record==7)begin initialized<=1;state<=IDLE;end
   else begin physical_record<=physical_record+1'b1;state<=RH_CMD;end
  end
 endtask
 integer j;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=BOOT;initialized<=0;init_error<=0;slot_valid<=0;slot_moves<=0;active_bank<=0;
   physical_record<=0;logical_slot<=0;record_sequence<=0;offset<=0;page_length<=0;position<=0;
   erase_index<=0;scan_mode<=1;compare_bad<=0;id_ok<=0;jedec<=0;
   crc<=32'hffffffff;header_crc<=0;image_crc<=0;commit_data<=0;loaded_header<=0;
   f_cmd_valid<=0;f_op<=0;f_address<=0;f_length<=0;done_is_load<=0;done_error<=0;
   for(j=0;j<4;j=j+1)sequences[j]<=0;
   for(j=0;j<256;j=j+1)header[j]<=0;
  end else begin
   if(f_cmd_valid&&f_cmd_ready)f_cmd_valid<=0;
   case(state)
    BOOT:if(f_cmd_ready&&!f_cmd_valid)launch(3,0,3,ID_WAIT);
    ID_WAIT:begin
     if(f_out_valid)begin jedec<={jedec[15:0],f_out};position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||position!=3||jedec!=24'hc84019)begin init_error<=8'h10;state<=BOOT_FAILED;end
      else begin id_ok<=1;physical_record<=0;scan_mode<=1;state<=RH_CMD;end
     end
    end
    RH_CMD:if(f_cmd_ready&&!f_cmd_valid)begin crc<=32'hffffffff;launch(0,record_base,256,RH_WAIT);end
    RH_WAIT:begin
     if(f_out_valid)begin header[position[7:0]]<=f_out;if(position<252)crc<=crc_byte(crc,f_out);position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||position!=256)begin
       if(scan_mode)begin init_error<=8'h11;state<=BOOT_FAILED;end else finish(8'h11);
      end else state<=RC_CMD;
     end
    end
    RC_CMD:if(f_cmd_ready&&!f_cmd_valid)begin commit_data<=0;launch(0,record_base+32'hf00,16,RC_WAIT);end
    RC_WAIT:begin
     if(f_out_valid)begin commit_data[position*8+:8]<=f_out;position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||position!=16)begin
       if(scan_mode)begin init_error<=8'h11;state<=BOOT_FAILED;end else finish(8'h11);
      end else state<=VALIDATE;
     end
    end
    VALIDATE:begin
     if(scan_mode)begin
      if(header_good&&commit_good&&(!slot_valid[physical_record[2:1]]||sequence_newer))begin
       slot_valid[physical_record[2:1]]<=1;active_bank[physical_record[2:1]]<=physical_record[0];
       sequences[physical_record[2:1]]<=h_sequence;slot_moves[physical_record[2:1]*8+:8]<=header[12];
      end
      skip_record;
     end else if(!header_good||!commit_good||h_sequence!=sequences[logical_slot])finish(8'h12);
     else begin offset<=0;crc<=32'hffffffff;image_crc<=h_image_crc;state<=LI_CMD;end
    end
    IDLE:begin
     done_error<=0;
     if(save_valid)begin
      done_is_load<=0;logical_slot<=save_slot;physical_record<={save_slot,slot_valid[save_slot]?!active_bank[save_slot]:1'b0};
      record_sequence<=slot_valid[save_slot]?sequences[save_slot]+1'b1:32'd1;
      for(j=0;j<252;j=j+1)header[j]<=save_metadata[j*8+:8];
      erase_index<=0;offset<=0;crc<=32'hffffffff;
      if(save_metadata[9*8+:8]<5||save_metadata[9*8+:8]>13||save_metadata[10*8+:8]<1||
         save_metadata[10*8+:8]>2||save_metadata[11*8+:8]<1||save_metadata[11*8+:8]>2||
         save_metadata[12*8+:8]>169)finish(8'h16);
      else state<=ERASE_CMD;
     end else if(load_valid)begin
      done_is_load<=1;logical_slot<=load_slot;physical_record<={load_slot,active_bank[load_slot]};scan_mode<=0;
      if(!slot_valid[load_slot])finish(8'h13);else state<=RH_CMD;
     end
    end
    ERASE_CMD:if(f_cmd_ready&&!f_cmd_valid)launch(2,record_base+({28'd0,erase_index}<<16),0,ERASE_WAIT);
    ERASE_WAIT:if(f_done)begin
     if(f_error!=0)finish(8'h20);
     else if(erase_index==ERASE_BLOCKS-1)begin offset<=0;crc<=32'hffffffff;state<=SI_CMD;end
     else begin erase_index<=erase_index+1'b1;state<=ERASE_CMD;end
    end
    SI_CMD:if(f_cmd_ready&&!f_cmd_valid)begin
     page_length<=IMAGE_BYTES-offset>=256?9'd256:IMAGE_BYTES-offset;
     launch(1,record_base+4096+offset,IMAGE_BYTES-offset>=256?9'd256:IMAGE_BYTES-offset,SI_SEND);
    end
    SI_SEND:begin
     if(image_in_valid&&f_in_ready)begin
      crc<=crc_byte(crc,image_in_data);position<=position+1'b1;
      if(position+1'b1==page_length)state<=SI_WAIT;
     end
     // The flash controller can time out before a complete page arrives.
     if(f_done)begin state<=SI_WAIT;end
    end
    SI_WAIT:if(f_done)begin
     if(f_error!=0)finish(8'h21);
     else if(offset+page_length==IMAGE_BYTES)begin image_crc<=~crc;state<=BUILD_HEADER;end
     else begin offset<=offset+page_length;state<=SI_CMD;end
    end
    BUILD_HEADER:begin
     header[0]<=8'h51;header[1]<=8'h59;header[2]<=8'h53;header[3]<=8'h31;
     header[4]<=1;header[5]<=0;header[6]<=0;header[7]<=1;header[8]<={6'd0,logical_slot};
     for(j=0;j<4;j=j+1)begin header[16+j]<=record_sequence[j*8+:8];header[24+j]<=image_crc[j*8+:8];header[28+j]<=IMAGE_BYTES[j*8+:8];end
     header[245]<=1;header[246]<=IMAGE_WIDTH&255;header[247]<=(IMAGE_WIDTH>>8)&255;
     header[248]<=IMAGE_HEIGHT&255;header[249]<=(IMAGE_HEIGHT>>8)&255;
     header[250]<=0;header[251]<=0;crc<=32'hffffffff;position<=0;state<=HEADER_CRC;
    end
    HEADER_CRC:begin
     crc<=crc_byte(crc,header[position[7:0]]);
     if(position==251)state<=HEADER_FINISH;else position<=position+1'b1;
    end
    HEADER_FINISH:begin
     header_crc<=~crc;
     for(j=0;j<4;j=j+1)header[252+j]<=~crc[j*8+:8];
     state<=WH_CMD;
    end
    WH_CMD:if(f_cmd_ready&&!f_cmd_valid)launch(1,record_base,256,WH_SEND);
    WH_SEND:if(f_in_ready)begin position<=position+1'b1;if(position==255)state<=WH_WAIT;end
    WH_WAIT:if(f_done)begin if(f_error!=0)finish(8'h21);else begin compare_bad<=0;state<=VH_CMD;end end
    VH_CMD:if(f_cmd_ready&&!f_cmd_valid)launch(0,record_base,256,VH_WAIT);
    VH_WAIT:begin
     if(f_out_valid)begin if(f_out!=header[position[7:0]])compare_bad<=1;position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||compare_bad||position!=256)finish(8'h22);
      else begin offset<=0;crc<=32'hffffffff;state<=VI_CMD;end
     end
    end
    VI_CMD:if(f_cmd_ready&&!f_cmd_valid)begin
     page_length<=IMAGE_BYTES-offset>=256?9'd256:IMAGE_BYTES-offset;
     launch(0,record_base+4096+offset,IMAGE_BYTES-offset>=256?9'd256:IMAGE_BYTES-offset,VI_WAIT);
    end
    VI_WAIT:begin
     if(f_out_valid)begin crc<=crc_byte(crc,f_out);position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||position!=page_length)finish(8'h22);
      else if(offset+page_length==IMAGE_BYTES)begin if(~crc!=image_crc)finish(8'h22);else state<=WC_CMD;end
      else begin offset<=offset+page_length;state<=VI_CMD;end
     end
    end
    WC_CMD:if(f_cmd_ready&&!f_cmd_valid)launch(1,record_base+32'hf00,16,WC_SEND);
    WC_SEND:if(f_in_ready)begin position<=position+1'b1;if(position==15)state<=WC_WAIT;end
    WC_WAIT:if(f_done)begin if(f_error!=0)finish(8'h21);else begin compare_bad<=0;state<=VC_CMD;end end
    VC_CMD:if(f_cmd_ready&&!f_cmd_valid)launch(0,record_base+32'hf00,16,VC_WAIT);
    VC_WAIT:begin
     if(f_out_valid)begin if(f_out!=commit_byte(position[4:0]))compare_bad<=1;position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||compare_bad||position!=16)finish(8'h22);
      else begin
       slot_valid[logical_slot]<=1;active_bank[logical_slot]<=physical_record[0];
       sequences[logical_slot]<=record_sequence;slot_moves[logical_slot*8+:8]<=header[12];finish(0);
      end
     end
    end
    LI_CMD:if(f_cmd_ready&&!f_cmd_valid)begin
     page_length<=IMAGE_BYTES-offset>=256?9'd256:IMAGE_BYTES-offset;
     launch(0,record_base+4096+offset,IMAGE_BYTES-offset>=256?9'd256:IMAGE_BYTES-offset,LI_WAIT);
    end
    LI_WAIT:begin
     if(f_out_valid&&image_out_ready)begin crc<=crc_byte(crc,f_out);position<=position+1'b1;end
     if(f_done)begin
      if(f_error!=0||position!=page_length)finish(8'h14);
      else if(offset+page_length==IMAGE_BYTES)begin
       if(~crc!=image_crc)finish(8'h15);
       else begin for(j=0;j<256;j=j+1)loaded_header[j*8+:8]<=header[j];finish(0);end
      end else begin offset<=offset+page_length;state<=LI_CMD;end
     end
    end
    COMPLETE:if(done_ready)state<=IDLE;
    BOOT_FAILED:begin initialized<=0;id_ok<=0;end
    default:begin init_error<=8'hff;state<=BOOT_FAILED;end
   endcase
  end
 end
endmodule
`default_nettype wire
