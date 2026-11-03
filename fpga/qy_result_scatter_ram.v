`timescale 1ns/1ps
`default_nettype none
// One bounded output transaction, sequential writes, explicit publication.
// cancel invalidates the transaction and all responses, not the RAM contents.
// The owner supplies a fresh tag and asserts publish only on layer success.
module qy_result_scatter_ram #(parameter integer AW=16)(
    input wire clk,rst,cancel,input wire begin_scatter,
    input wire begin_valid,output wire begin_ready,input wire [31:0] begin_tag,begin_length,output reg begin_error,
    input wire wr_valid,output wire wr_ready,input wire [31:0] wr_addr,input wire [7:0] wr_data,
    output reg ack_valid,input wire ack_ready,output reg ack_error,
    input wire publish_valid,output wire publish_ready,input wire [31:0] publish_tag,output reg publish_error,
    output reg published,output reg [31:0] written_count,
    input wire rd_valid,output wire rd_ready,input wire [31:0] rd_tag,rd_addr,
    output reg rsp_valid,input wire rsp_ready,output reg [31:0] rsp_tag,output wire [7:0] rsp_data,output reg rsp_error
);
    localparam integer DEPTH=1<<AW;
    (* ram_style="bram" *) reg [7:0] mem[0:DEPTH-1],read_q;
    reg scatter,clearing,checking,committing;
    reg [31:0] clear_index,pending_addr;reg [7:0] pending_data;
    (* ram_style="bram" *) reg seen[0:DEPTH-1];reg seen_q;
    reg active,failed;reg [31:0] tag,length;
    assign begin_ready=!rst&&!cancel&&!clearing&&!checking&&!committing&&!active&&!published&&!ack_valid&&!rsp_valid;
    assign wr_ready=!rst&&!cancel&&active&&!failed&&!clearing&&!checking&&!committing&&(!ack_valid||ack_ready);
    assign publish_ready=!rst&&!cancel&&active&&!clearing&&!checking&&!committing&&!ack_valid&&!wr_valid;
    assign rd_ready=!rst&&!cancel&&(!rsp_valid||rsp_ready)&&!begin_valid;
    wire begin_fire=begin_valid&&begin_ready,write_fire=wr_valid&&wr_ready;
    wire read_fire=rd_valid&&rd_ready,publish_fire=publish_valid&&publish_ready;
    wire bad_write=(wr_addr>=DEPTH)||(wr_addr>=length)||(!scatter&&(wr_addr!=written_count));
    wire bad_read=!published||(rd_tag!=tag)||(rd_addr>=length)||(rd_addr>=DEPTH);
    wire bad_publish=failed||(publish_tag!=tag)||(written_count!=length);
    assign rsp_data=rsp_error?8'd0:read_q;
    wire commit_fire=committing&&!seen_q&&!rst&&!cancel;
    wire mem_write=(write_fire&&!bad_write&&!scatter)||commit_fire;
    wire [AW-1:0] mem_write_addr=scatter?pending_addr[AW-1:0]:wr_addr[AW-1:0];
    wire [7:0] mem_write_data=scatter?pending_data:wr_data;
    wire [AW-1:0] seen_write_addr=clearing?clear_index[AW-1:0]:pending_addr[AW-1:0];
    always @(posedge clk) begin
        if(mem_write) mem[mem_write_addr]<=mem_write_data;
        if(write_fire&&!bad_write&&scatter) seen_q<=seen[wr_addr[AW-1:0]];
        if(clearing||commit_fire) seen[seen_write_addr]<=!clearing;
        if(read_fire&&!bad_read) read_q<=mem[rd_addr[AW-1:0]];
    end
    always @(posedge clk) begin
        if(rst||cancel) begin
            scatter<=0;clearing<=0;checking<=0;committing<=0;clear_index<=0;pending_addr<=0;pending_data<=0;
            active<=0;failed<=0;tag<=0;length<=0;written_count<=0;published<=0;
            begin_error<=0;publish_error<=0;ack_valid<=0;ack_error<=0;rsp_valid<=0;rsp_error<=0;rsp_tag<=0;
        end else begin
            begin_error<=0;publish_error<=0;
            if(ack_valid&&ack_ready) ack_valid<=0;
            if(rsp_valid&&rsp_ready) rsp_valid<=0;
            if(begin_fire) begin
                begin_error<=begin_length==0||begin_length>DEPTH;
                if(begin_length!=0&&begin_length<=DEPTH) begin
                    scatter<=begin_scatter;clearing<=begin_scatter;clear_index<=0;
                    tag<=begin_tag;length<=begin_length;written_count<=0;failed<=0;active<=1;
                end
            end
            if(clearing) begin
                if(clear_index==length-1) clearing<=0;
                else clear_index<=clear_index+1'b1;
            end
            if(write_fire) begin
                if(!scatter||bad_write) begin
                    ack_valid<=1;ack_error<=bad_write;
                    if(bad_write) failed<=1;
                    else written_count<=written_count+1'b1;
                end else begin pending_addr<=wr_addr;pending_data<=wr_data;checking<=1;end
            end
            if(checking) begin checking<=0;committing<=1;end
            if(committing) begin
                committing<=0;ack_valid<=1;ack_error<=seen_q;
                if(seen_q) failed<=1;
                else written_count<=written_count+1'b1;
            end
            if(publish_fire) begin active<=0;published<=!bad_publish;publish_error<=bad_publish;end
            if(read_fire) begin rsp_valid<=1;rsp_tag<=rd_tag;rsp_error<=bad_read;end
        end
    end
endmodule
`default_nettype wire
