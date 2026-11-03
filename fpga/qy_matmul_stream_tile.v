`timescale 1ns/1ps
`default_nettype none
// U8/U8 matrix tile: A[M,K] and B[K,N] with independent row strides.
// Existing 64KiB A / 16KiB B public caches are reused. Addresses advance
// incrementally within a dot; no address multiplication is on the read path.
// Multiple requests may overlap their ordered responses. Errors and cancellation
// flush the feature response channel before accepting another command.
module qy_matmul_stream_tile (
    input wire clk, input wire rst, input wire cancel, output wire memory_reset,
    input wire cmd_valid, output wire cmd_ready,
    input wire [31:0] cmd_tag, input wire [31:0] cmd_a_base, input wire [31:0] cmd_b_base,
    input wire [31:0] cmd_a_stride, input wire [31:0] cmd_b_stride,
    input wire [8:0] cmd_rows, input wire [8:0] cmd_cols, input wire [11:0] cmd_terms,
    input wire [7:0] cmd_a_zero, input wire [7:0] cmd_b_zero, input wire [7:0] cmd_output_zero,
    input wire [31:0] cmd_multiplier, input wire [5:0] cmd_shift,
    output wire req_valid, input wire req_ready, output wire [31:0] req_a, output wire [31:0] req_b,
    input wire rsp_valid, output wire rsp_ready, input wire [7:0] rsp_a, input wire [7:0] rsp_b, input wire rsp_error,
    output wire wr_valid, input wire wr_ready, output wire [31:0] wr_addr, output wire [7:0] wr_data,
    input wire ack_valid, output wire ack_ready, input wire ack_error,
    output wire done_valid, input wire done_ready,
    output reg [31:0] done_tag, output reg [31:0] done_written, output reg [7:0] done_error
);
    localparam [3:0] IDLE=0,SHAPE=1,EXTENT=2,BOUNDS=3,ISSUE=4,REQUEST=5,REPLY=6,
        RESULT=7,WRITE=8,ACK=9,DONE=10;
    reg [3:0] state;
    reg [31:0] a_base,b_base,a_stride,b_stride,multiplier,a_row,b_col,a_cursor,b_cursor,index,total;
    reg [8:0] rows,cols,row,col;
    reg [11:0] terms,term,issued;
    reg [7:0] az,bz,oz,result_byte;
    reg [5:0] shift;
    reg [40:0] a_extent,b_extent;
    wire [41:0] a_end={10'd0,a_base}+{1'b0,a_extent}+{30'd0,terms};
    wire [41:0] b_end={10'd0,b_base}+{1'b0,b_extent}+{33'd0,cols};
    wire active_reset=rst||cancel;
    assign memory_reset=active_reset||(state==DONE&&done_error!=0);
    assign cmd_ready=!memory_reset&&state==IDLE;
    assign req_valid=!memory_reset&&state==REQUEST&&issued<terms;
    assign req_a=a_cursor;assign req_b=b_cursor;
    wire dot_ready,dot_s_ready,dot_valid;wire [31:0] dot_tag;wire [2:0] dot_error;
    wire signed [39:0] dot_sum;wire [7:0] dot_pre,dot_data;
    assign rsp_ready=!memory_reset&&(state==REQUEST||state==REPLY)&&(rsp_error||dot_s_ready);
    assign wr_valid=!memory_reset&&state==WRITE;assign wr_addr=index;assign wr_data=result_byte;
    assign ack_ready=!memory_reset&&state==ACK;
    assign done_valid=!active_reset&&state==DONE;
    qy_u8_dot_pipeline dot(
        .clk(clk),.rst(memory_reset||state==DONE),.cmd_valid(!memory_reset&&state==ISSUE),.cmd_ready(dot_ready),
        .cmd_tag(done_tag),.cmd_terms(terms),.cmd_bias(32'sd0),.cmd_input_zero(az),.cmd_weight_zero(bz),
        .cmd_multiplier(multiplier),.cmd_shift(shift),.cmd_output_zero(oz),
        .s_valid(!memory_reset&&(state==REQUEST||state==REPLY)&&rsp_valid&&!rsp_error),.s_ready(dot_s_ready),.s_activation(rsp_a),.s_weight(rsp_b),
        .m_valid(dot_valid),.m_ready(!memory_reset&&state==RESULT),.m_tag(dot_tag),.m_sum(dot_sum),.m_pre(dot_pre),.m_activation(dot_data),.m_error(dot_error));
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;done_tag<=0;done_written<=0;done_error<=0;index<=0;
            a_base<=0;b_base<=0;a_stride<=0;b_stride<=0;multiplier<=0;
            rows<=0;cols<=0;terms<=0;row<=0;col<=0;term<=0;issued<=0;az<=0;bz<=0;oz<=0;shift<=0;
            a_row<=0;b_col<=0;a_cursor<=0;b_cursor<=0;result_byte<=0;
        end else if(cancel) begin
            if(state!=IDLE) begin done_error<=8'h10;state<=DONE;end
        end else case(state)
            IDLE:if(cmd_valid) begin
                done_tag<=cmd_tag;done_written<=0;done_error<=0;index<=0;row<=0;col<=0;term<=0;issued<=0;
                a_base<=cmd_a_base;b_base<=cmd_b_base;a_stride<=cmd_a_stride;b_stride<=cmd_b_stride;
                rows<=cmd_rows;cols<=cmd_cols;terms<=cmd_terms;az<=cmd_a_zero;bz<=cmd_b_zero;oz<=cmd_output_zero;
                multiplier<=cmd_multiplier;shift<=cmd_shift;state<=SHAPE;
            end
            SHAPE:if(rows==0||rows>256||cols==0||cols>400||terms==0||terms>2304||
                a_stride<terms||a_stride>65536||b_stride<cols||b_stride>16384||
                multiplier==0||multiplier[31]||shift>62) begin done_error<=1;state<=DONE;end
                else state<=EXTENT;
            EXTENT:begin
                a_extent<=(rows-9'd1)*a_stride;b_extent<=(terms-12'd1)*b_stride;total<=rows*cols;state<=BOUNDS;
            end
            BOUNDS:if(a_end>65536||b_end>16384||total>65536) begin done_error<=1;state<=DONE;end
                else begin a_row<=a_base;b_col<=b_base;a_cursor<=a_base;b_cursor<=b_base;state<=ISSUE;end
            ISSUE:if(dot_ready) begin term<=0;issued<=0;state<=REQUEST;end
            REQUEST,REPLY:begin
                if(req_valid&&req_ready) begin
                    issued<=issued+1'b1;
                    a_cursor<=a_cursor+1'b1;b_cursor<=b_cursor+b_stride;
                    if(issued==terms-1) state<=REPLY;
                end
                if(rsp_valid&&rsp_ready) begin
                    if(rsp_error) begin done_error<=2;state<=DONE;end
                    else if(term==terms-1) state<=RESULT;
                    else term<=term+1'b1;
                end
            end
            RESULT:if(dot_valid) begin
                if(dot_tag!=done_tag) begin done_error<=8'h20;state<=DONE;end
                else if(dot_error!=0) begin done_error<=4;state<=DONE;end
                else begin result_byte<=dot_data;state<=WRITE;end
            end
            WRITE:if(wr_ready) state<=ACK;
            ACK:if(ack_valid) begin
                if(ack_error) begin done_error<=8;state<=DONE;end
                else begin
                    done_written<=done_written+1'b1;
                    if(index==total-1) state<=DONE;
                    else begin
                        index<=index+1'b1;
                        if(col==cols-1) begin
                            row<=row+1'b1;col<=0;a_row<=a_row+a_stride;b_col<=b_base;
                            a_cursor<=a_row+a_stride;b_cursor<=b_base;
                        end else begin col<=col+1'b1;b_col<=b_col+1'b1;a_cursor<=a_row;b_cursor<=b_col+1'b1;end
                        state<=ISSUE;
                    end
                end
            end
            DONE:if(done_ready) state<=IDLE;
            default:begin done_error<=8'h80;state<=DONE;end
        endcase
    end
endmodule
`default_nettype wire
