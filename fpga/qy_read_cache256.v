`timescale 1ns/1ps
`default_nettype none
// Two read-only 32-byte cache lines for postprocessing. Reset between model
// frames after all accepted DDR responses drain. Word reads must be aligned;
// byte reads expose only the low byte (upper bytes are unspecified).
// Cancel drains an accepted miss before reporting error4; no stale response
// can be consumed by the next command. No writes or speculative reads.
module qy_read_cache256 (
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,input wire [31:0] cmd_addr,input wire cmd_word,
    output wire out_valid,input wire out_ready,output reg [31:0] out_tag,output reg [31:0] out_data,output reg [2:0] out_error,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error,
    output wire busy
);
    localparam [2:0] IDLE=0,LOOK=1,REQUEST=2,WAIT_READ=3,EXTRACT=4,OUTPUT=5;
    reg [2:0] state;reg [31:0] address;reg word_read,cancelled,victim;
    reg valid0,valid1;reg [26:0] tag0,tag1;reg [255:0] line0,line1,value;
    wire hit0=valid0&&tag0==address[31:5],hit1=valid1&&tag1==address[31:5];
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign out_valid=!rst&&!cancel&&state==OUTPUT;
    assign rd_valid=!rst&&!cancel&&state==REQUEST;
    assign rd_addr={address[31:5],5'd0};
    assign rsp_ready=!rst&&state==WAIT_READ;
    assign busy=state!=IDLE;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;address<=0;word_read<=0;cancelled<=0;victim<=0;valid0<=0;valid1<=0;tag0<=0;tag1<=0;
            line0<=0;line1<=0;value<=0;out_tag<=0;out_data<=0;out_error<=0;
        end else begin
            if(cancel&&state!=IDLE) cancelled<=1;
            if(cancel&&state!=IDLE&&state!=WAIT_READ) begin out_error<=4;out_data<=0;state<=OUTPUT;end
            else case(state)
                IDLE:if(cmd_valid&&cmd_ready) begin
                    address<=cmd_addr;word_read<=cmd_word;out_tag<=cmd_tag;out_error<=0;out_data<=0;cancelled<=0;state<=LOOK;
                end
                LOOK:if(word_read&&address[1:0]!=0) begin out_error<=1;state<=OUTPUT;end
                    else if(hit0||hit1) begin value<=hit0?line0:line1;victim<=hit0;state<=EXTRACT;end
                    else state<=REQUEST;
                REQUEST:if(rd_ready) state<=WAIT_READ;
                WAIT_READ:if(rsp_valid) begin
                    if(cancelled||cancel) begin out_error<=4;state<=OUTPUT;end
                    else if(rsp_error) begin out_error<=2;state<=OUTPUT;end
                    else begin
                        if(!victim) begin line0<=rsp_data;tag0<=address[31:5];valid0<=1;end
                        else begin line1<=rsp_data;tag1<=address[31:5];valid1<=1;end
                        victim<=!victim;value<=rsp_data;state<=EXTRACT;
                    end
                end
                EXTRACT:begin out_data<=value>>{address[4:0],3'b000};state<=OUTPUT;end
                OUTPUT:if(out_ready&&!cancel) state<=IDLE;
                default:begin out_error<=7;state<=OUTPUT;end
            endcase
        end
    end
endmodule
`default_nettype wire
