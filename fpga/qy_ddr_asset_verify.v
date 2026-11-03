`timescale 1ns/1ps
`default_nettype none
// Read back every loaded asset from DDR, not merely the SPI source CRC.
// Four aligned regions; one 32-byte line and serial CRC, bounded storage.
module qy_ddr_asset_verify #(
    parameter [127:0] BASES=0,LENGTHS=0,CRCS=0
)(
    input wire clk,input wire rst,input wire start_valid,output wire start_ready,
    output wire done_valid,input wire done_ready,output reg [7:0] done_error,output wire [1:0] asset_index,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error
);
    localparam [2:0] IDLE=0,CHECK=1,REQUEST=2,RESPONSE=3,CRC=4,FINISH=5,DONE=6;
    reg [2:0] state;reg [1:0] asset;reg [31:0] address,remaining,crc;reg [255:0] line;reg [4:0] index;
    wire [31:0] base=BASES[asset*32+:32],length=LENGTHS[asset*32+:32],expected=CRCS[asset*32+:32];
    wire [32:0] last_address={1'b0,base}+{1'b0,length};
    assign start_ready=!rst&&state==IDLE;assign done_valid=!rst&&state==DONE;assign asset_index=asset;
    assign rd_valid=!rst&&state==REQUEST;assign rd_addr=address;assign rsp_ready=!rst&&state==RESPONSE;
    function [31:0] crc_byte(input [31:0] old,input [7:0] data);
        integer i;reg [31:0] c;begin c=old^{24'd0,data};for(i=0;i<8;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;asset<=0;address<=0;remaining<=0;crc<=0;line<=0;index<=0;done_error<=0;end
        else case(state)
            IDLE:if(start_valid) begin asset<=0;done_error<=0;state<=CHECK;end
            CHECK:if(base[4:0]!=0||length==0||length[4:0]!=0||last_address>33'h100000000) begin done_error<=1;state<=DONE;end
                else begin address<=base;remaining<=length;crc<=32'hffffffff;state<=REQUEST;end
            REQUEST:if(rd_ready) state<=RESPONSE;
            RESPONSE:if(rsp_valid) begin
                if(rsp_error) begin done_error<=2;state<=DONE;end
                else begin line<=rsp_data;index<=0;state<=CRC;end
            end
            CRC:begin
                crc<=crc_byte(crc,line[7:0]);line<={8'd0,line[255:8]};
                if(index==31) begin
                    if(remaining==32) state<=FINISH;
                    else begin remaining<=remaining-32;address<=address+32;state<=REQUEST;end
                end else index<=index+1'b1;
            end
            FINISH:if((~crc)!=expected) begin done_error<=4;state<=DONE;end
                else if(asset==3) state<=DONE;
                else begin asset<=asset+1'b1;state<=CHECK;end
            DONE:if(done_ready) state<=IDLE;
            default:begin done_error<=8;state<=DONE;end
        endcase
    end
endmodule
`default_nettype wire
