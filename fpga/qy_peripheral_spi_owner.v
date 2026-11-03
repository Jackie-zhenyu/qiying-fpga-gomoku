`timescale 1ns/1ps
`default_nettype none
// Config and game records share the one physical SPI. A whole transaction owns
// the bus; CS-high gaps alone never permit preemption of the record scanner.
module qy_peripheral_spi_owner(
 input wire clk,rst_n,
 input wire config_initialized,config_active,
 input wire settings_active,game_active,replay_active,storage_busy,
 input wire records_initialized,records_idle,input wire [7:0] records_init_error,
 input wire record_save_valid,record_load_valid,
 input wire config_cs_n,config_sclk,config_mosi,
 input wire records_cs_n,records_sclk,records_mosi,
 output wire config_grant,records_rst_n,config_owner,
 output wire cs_n,sclk,mosi
);
 localparam BOOT_CONFIG=0,TO_RECORDS=1,RECORDS=2,TO_CONFIG=3,SAVE_CONFIG=4;
 reg [2:0] owner;
 wire config_quiet=config_cs_n&&!config_sclk;
 wire records_quiet=records_cs_n&&!records_sclk;
 wire safe_save=settings_active&&!game_active&&!replay_active&&!storage_busy&&
  !record_save_valid&&!record_load_valid&&records_quiet&&
  ((records_initialized&&records_idle)||(records_init_error!=0));
 assign config_grant=rst_n&&(owner==BOOT_CONFIG||owner==SAVE_CONFIG);
 assign records_rst_n=rst_n&&owner==RECORDS;
 // Include waiting/gaps in the UI lock, so exit cannot strand a save request.
 assign config_owner=owner!=RECORDS||config_active;
 assign cs_n=!rst_n?1'b1:config_grant?config_cs_n:records_rst_n?records_cs_n:1'b1;
 assign sclk=!rst_n?1'b0:config_grant?config_sclk:records_rst_n?records_sclk:1'b0;
 assign mosi=!rst_n?1'b1:config_grant?config_mosi:records_rst_n?records_mosi:1'b1;
 always @(posedge clk)begin
  if(!rst_n)owner<=BOOT_CONFIG;
  else case(owner)
   BOOT_CONFIG:if(config_initialized&&!config_active&&config_quiet)owner<=TO_RECORDS;
   TO_RECORDS:owner<=RECORDS;
   RECORDS:if(config_active&&safe_save)owner<=TO_CONFIG;
   TO_CONFIG:owner<=SAVE_CONFIG;
   SAVE_CONFIG:if(!config_active&&config_quiet)owner<=TO_RECORDS;
   default:owner<=BOOT_CONFIG;
  endcase
 end
endmodule
`default_nettype wire
