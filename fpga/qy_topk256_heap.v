`timescale 1ns/1ps
`default_nettype none
// Bounded top256 unsigned 79-bit keys. One RAM is reused for a min heap and
// in-place heap sort. No 8400-anchor feature or detection array is allocated.
// A key is {score_bits32,anchor_max_bits32,~anchor14,~class1}; both confidence
// bit fields are nonnegative finite values supplied by the frozen decoder LUT.
module qy_topk256_heap (
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,input wire [14:0] cmd_count,
    input wire s_valid,output wire s_ready,input wire [78:0] s_key,input wire s_last,
    output wire m_valid,input wire m_ready,output reg [31:0] m_tag,
    output reg [8:0] m_index,output reg [8:0] m_count,output reg [78:0] m_key,
    output reg m_last,output reg [2:0] m_error
);
    localparam [4:0] IDLE=0,ACCEPT=1,PLACE=2,UP_READ=3,UP_WAIT=4,UP_TEST=5,
        ROOT_READ=6,ROOT_WAIT=7,ROOT_TEST=8,DOWN_PICK=9,LEFT_READ=10,LEFT_WAIT=11,
        RIGHT_READ=12,RIGHT_WAIT=13,CHILD_TEST=14,DOWN_MOVE=15,INSERT_DONE=16,
        SORT_ROOT=17,SORT_ROOT_WAIT=18,SORT_TAIL=19,SORT_TAIL_WAIT=20,SORT_SAVE=21,
        EMIT_READ=22,EMIT_WAIT=23,OUTPUT=24,ERROR=25;
    reg [4:0] state;
    reg [78:0] heap[0:255];reg [78:0] ram_q,candidate,child_key,root_key;
    reg [8:0] heap_count,index,child_index;
    reg [14:0] expected_count,consumed;
    reg final_candidate,sorting;
    wire [8:0] parent_index=(index-1'b1)>>1;
    wire [9:0] left_index={index,1'b0}+10'd1,right_index={index,1'b0}+10'd2;
    wire rd_enable=state==UP_READ||state==ROOT_READ||state==LEFT_READ||state==RIGHT_READ||state==SORT_ROOT||state==SORT_TAIL||state==EMIT_READ;
    wire [7:0] rd_address=state==UP_READ?parent_index[7:0]:state==LEFT_READ?left_index[7:0]:state==RIGHT_READ?right_index[7:0]:state==SORT_TAIL?(heap_count-1'b1):state==EMIT_READ?m_index[7:0]:8'd0;
    wire write_enable=!rst&&!cancel&&(state==PLACE||(state==UP_TEST&&ram_q>candidate)||state==DOWN_MOVE||state==SORT_SAVE);
    wire [7:0] write_address=state==SORT_SAVE?(heap_count-1'b1):index[7:0];
    wire [78:0] write_data=state==PLACE?candidate:state==UP_TEST?ram_q:state==DOWN_MOVE?child_key:root_key;
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign s_ready=!rst&&!cancel&&state==ACCEPT;
    assign m_valid=!rst&&!cancel&&state==OUTPUT;
    always @(posedge clk) begin
        if(rd_enable) ram_q<=heap[rd_address];
        if(write_enable) heap[write_address]<=write_data;
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;heap_count<=0;index<=0;child_index<=0;expected_count<=0;consumed<=0;
            candidate<=0;child_key<=0;root_key<=0;final_candidate<=0;sorting<=0;
            m_tag<=0;m_index<=0;m_count<=0;m_key<=0;m_last<=0;m_error<=0;
        end else if(cancel) begin
            if(state!=IDLE) begin m_error<=4;state<=ERROR;end
        end else case(state)
            IDLE:if(cmd_valid) begin
                m_tag<=cmd_tag;m_index<=0;m_count<=0;m_key<=0;m_last<=0;m_error<=0;
                heap_count<=0;consumed<=0;expected_count<=cmd_count;sorting<=0;final_candidate<=0;
                if(cmd_count==0||cmd_count>16800) begin m_error<=1;state<=ERROR;end else state<=ACCEPT;
            end
            ACCEPT:if(s_valid) begin
                if(s_last!=(consumed==expected_count-1'b1)) begin m_error<=2;state<=ERROR;end
                else begin
                    candidate<=s_key;final_candidate<=s_last;consumed<=consumed+1'b1;
                    if(heap_count<256) begin index<=heap_count;heap_count<=heap_count+1'b1;state<=heap_count==0?PLACE:UP_READ;end
                    else state<=ROOT_READ;
                end
            end
            UP_READ:state<=UP_WAIT;
            UP_WAIT:state<=UP_TEST;
            UP_TEST:if(ram_q>candidate) begin index<=parent_index;state<=parent_index==0?PLACE:UP_READ;end else state<=PLACE;
            ROOT_READ:state<=ROOT_WAIT;
            ROOT_WAIT:state<=ROOT_TEST;
            ROOT_TEST:if(candidate>ram_q) begin index<=0;state<=DOWN_PICK;end else state<=INSERT_DONE;
            DOWN_PICK:if(left_index<{1'b0,heap_count}) state<=LEFT_READ;else state<=PLACE;
            LEFT_READ:state<=LEFT_WAIT;
            LEFT_WAIT:begin child_key<=ram_q;child_index<=left_index[8:0];state<=right_index<{1'b0,heap_count}?RIGHT_READ:CHILD_TEST;end
            RIGHT_READ:state<=RIGHT_WAIT;
            RIGHT_WAIT:begin if(ram_q<child_key) begin child_key<=ram_q;child_index<=right_index[8:0];end state<=CHILD_TEST;end
            CHILD_TEST:state<=child_key<candidate?DOWN_MOVE:PLACE;
            DOWN_MOVE:begin index<=child_index;state<=DOWN_PICK;end
            PLACE:if(sorting) begin if(heap_count<=1) begin m_index<=0;state<=EMIT_READ;end else state<=SORT_ROOT;end else state<=INSERT_DONE;
            INSERT_DONE:if(final_candidate) begin
                sorting<=1;m_count<=heap_count;m_index<=0;
                state<=heap_count<=1?EMIT_READ:SORT_ROOT;
            end else state<=ACCEPT;
            SORT_ROOT:state<=SORT_ROOT_WAIT;
            SORT_ROOT_WAIT:begin root_key<=ram_q;state<=SORT_TAIL;end
            SORT_TAIL:state<=SORT_TAIL_WAIT;
            SORT_TAIL_WAIT:begin candidate<=ram_q;state<=SORT_SAVE;end
            SORT_SAVE:begin heap_count<=heap_count-1'b1;index<=0;state<=DOWN_PICK;end
            EMIT_READ:state<=EMIT_WAIT;
            EMIT_WAIT:begin m_key<=ram_q;m_last<=(m_index==m_count-1'b1);state<=OUTPUT;end
            OUTPUT:if(m_ready) begin
                if(m_last) state<=IDLE;
                else begin m_index<=m_index+1'b1;state<=EMIT_READ;end
            end
            ERROR:begin heap_count<=0;m_count<=0;m_index<=0;m_key<=0;m_last<=1;state<=OUTPUT;end
            default:begin m_error<=7;state<=ERROR;end
        endcase
    end
endmodule
`default_nettype wire
