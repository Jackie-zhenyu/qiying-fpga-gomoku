`timescale 1ns/1ps
`default_nettype none
// Frozen three-head, two-class YOLO26 decoder. Confidence/coordinate values
// are exact offline-generated FP32 bit patterns, manipulated as integers.
// Reads completed U8 heads and coordinate tables from DDR; only a two-line
// read cache and the top256 heap are retained. No host inference or floats.
// Output is provisional until the last successful record; the UI/mailbox
// owner must discard the whole job on a terminal error or stale frame tag.
module qy_yolo_postprocess #(parameter SCORE_FILE="yolo_scores.hex") (
    input wire clk,input wire rst,input wire cancel,
    input wire cmd_valid,output wire cmd_ready,input wire [31:0] cmd_tag,
    input wire [95:0] cmd_class_bases,input wire [95:0] cmd_box_bases,input wire [191:0] cmd_coord_bases,
    output wire m_valid,input wire m_ready,output reg [31:0] m_tag,output reg [8:0] m_index,
    output wire [191:0] m_data,output reg m_last,output reg [7:0] m_error,
    output wire rd_valid,input wire rd_ready,output wire [31:0] rd_addr,
    input wire rsp_valid,output wire rsp_ready,input wire [255:0] rsp_data,input wire rsp_error
);
    localparam [4:0] IDLE=0,START=1,CLASS0=2,WAIT_CLASS0=3,CLASS1=4,WAIT_CLASS1=5,
        SCORE0=6,GET_SCORE0=7,SCORE1=8,GET_SCORE1=9,MAX_SCORE=10,PUSH0=11,PUSH1=12,
        WAIT_TOP=13,ANCHOR=14,POSITION=15,BOX=16,WAIT_BOX=17,COORDINATE=18,TABLE=19,
        WAIT_TABLE=20,OUTPUT=21,ABORT=22;
    reg [4:0] state;
    reg [95:0] class_bases,box_bases;reg [191:0] coord_bases;
    reg [13:0] anchor,selected_anchor;reg [12:0] position,plane_size,selected_position,selected_local,selected_plane;
    reg [1:0] branch,selected_branch,component;
    reg [7:0] class0,class1,box_code;
    reg [6:0] selected_width,selected_x,selected_y;
    reg [31:0] score0,score1,max_score,score_q,output_score,output_class,coordinate_addr;
    reg [14:0] plane_offset;
    reg [127:0] box_coordinates;
    reg [7:0] fault;
    reg [31:0] scores[0:1023];initial $readmemh(SCORE_FILE,scores);
    always @(posedge clk) begin
        if(state==SCORE0) score_q<=scores[{branch,class0}];
        if(state==SCORE1) score_q<=scores[{branch,class1}];
    end
    wire cache_cmd_ready,cache_out_valid,cache_busy;wire [31:0] cache_data,cache_tag;wire [2:0] cache_error;
    wire cache_command=state==CLASS0||state==CLASS1||state==BOX||state==TABLE;
    wire cache_response=state==WAIT_CLASS0||state==WAIT_CLASS1||state==WAIT_BOX||state==WAIT_TABLE||state==ABORT;
    wire [31:0] class_base=class_bases[branch*32+:32],box_base=box_bases[selected_branch*32+:32];
    wire [2:0] coordinate_table={selected_branch,component[1]};
    wire [31:0] coordinate_base=coord_bases[coordinate_table*32+:32];
    wire [31:0] cache_addr=state==TABLE?coordinate_addr:state==BOX?box_base+{17'd0,plane_offset}+{19'd0,selected_local}:
        class_base+{19'd0,position}+(state==CLASS1?{19'd0,plane_size}:32'd0);
    qy_read_cache256 reader(
        .clk(clk),.rst(rst||state==IDLE),.cancel(cancel),.cmd_valid(!rst&&!cancel&&cache_command),.cmd_ready(cache_cmd_ready),
        .cmd_tag(m_tag),.cmd_addr(cache_addr),.cmd_word(state==TABLE),
        .out_valid(cache_out_valid),.out_ready(cache_response),.out_tag(cache_tag),.out_data(cache_data),.out_error(cache_error),
        .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_addr(rd_addr),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_error(rsp_error),.busy(cache_busy));
    wire heap_ready,heap_s_ready,heap_valid,heap_last;wire [31:0] heap_tag;wire [8:0] heap_index,heap_count;
    wire [78:0] heap_key;wire [2:0] heap_error;
    wire [78:0] input_key={state==PUSH0?score0:score1,max_score,~anchor,state==PUSH0};
    qy_topk256_heap heap(
        .clk(clk),.rst(rst||state==IDLE),.cancel(cancel||state==ABORT),
        .cmd_valid(!rst&&!cancel&&state==START),.cmd_ready(heap_ready),.cmd_tag(m_tag),.cmd_count(15'd16800),
        .s_valid(!rst&&!cancel&&(state==PUSH0||state==PUSH1)),.s_ready(heap_s_ready),.s_key(input_key),.s_last(state==PUSH1&&anchor==8399),
        .m_valid(heap_valid),.m_ready(!cancel&&state==WAIT_TOP),.m_tag(heap_tag),.m_index(heap_index),.m_count(heap_count),.m_key(heap_key),.m_last(heap_last),.m_error(heap_error));
    assign cmd_ready=!rst&&!cancel&&state==IDLE;
    assign m_valid=!rst&&!cancel&&state==OUTPUT;
    assign m_data={output_class,output_score,box_coordinates};
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;class_bases<=0;box_bases<=0;coord_bases<=0;anchor<=0;position<=0;plane_size<=0;branch<=0;
            class0<=0;class1<=0;box_code<=0;score0<=0;score1<=0;max_score<=0;selected_anchor<=0;selected_branch<=0;
            selected_position<=0;selected_local<=0;selected_plane<=0;selected_width<=0;selected_x<=0;selected_y<=0;
            component<=0;plane_offset<=0;box_coordinates<=0;output_score<=0;output_class<=0;coordinate_addr<=0;fault<=0;
            m_tag<=0;m_index<=0;m_last<=0;m_error<=0;
        end else if(cancel&&state!=IDLE) begin fault<=8'h80;state<=ABORT;end
        else case(state)
            IDLE:if(cmd_valid&&cmd_ready) begin
                class_bases<=cmd_class_bases;box_bases<=cmd_box_bases;coord_bases<=cmd_coord_bases;
                anchor<=0;position<=0;plane_size<=6400;branch<=0;m_tag<=cmd_tag;m_index<=0;m_last<=0;m_error<=0;
                output_score<=0;output_class<=0;box_coordinates<=0;fault<=0;state<=START;
            end
            START:if(heap_ready) state<=CLASS0;
            CLASS0:if(cache_cmd_ready) state<=WAIT_CLASS0;
            WAIT_CLASS0:if(cache_out_valid) begin
                if(cache_error!=0||cache_tag!=m_tag) begin fault<=8'h01;state<=ABORT;end
                else begin class0<=cache_data[7:0];state<=CLASS1;end
            end
            CLASS1:if(cache_cmd_ready) state<=WAIT_CLASS1;
            WAIT_CLASS1:if(cache_out_valid) begin
                if(cache_error!=0||cache_tag!=m_tag) begin fault<=8'h02;state<=ABORT;end
                else begin class1<=cache_data[7:0];state<=SCORE0;end
            end
            SCORE0:state<=GET_SCORE0;
            GET_SCORE0:begin score0<=score_q;state<=SCORE1;end
            SCORE1:state<=GET_SCORE1;
            GET_SCORE1:begin score1<=score_q;state<=MAX_SCORE;end
            MAX_SCORE:begin
                if(score0>32'h3f800000||score1>32'h3f800000) begin fault<=8'h04;state<=ABORT;end
                else begin max_score<=score0>score1?score0:score1;state<=PUSH0;end
            end
            PUSH0:if(heap_s_ready) state<=PUSH1;
            PUSH1:if(heap_s_ready) begin
                if(anchor==8399) state<=WAIT_TOP;
                else begin
                    anchor<=anchor+1'b1;
                    if(position==plane_size-1'b1) begin position<=0;branch<=branch+1'b1;plane_size<=branch==0?13'd1600:13'd400;end
                    else position<=position+1'b1;
                    state<=CLASS0;
                end
            end
            WAIT_TOP:if(heap_valid) begin
                if(heap_error!=0||heap_tag!=m_tag||heap_count!=256||heap_key[14:1]<14'd7984) begin fault<=8'h08;state<=ABORT;end
                else begin
                    selected_anchor<=~heap_key[14:1];output_score<=heap_key[78:47];output_class<=heap_key[0]?32'd0:32'h3f800000;
                    m_index<=heap_index;m_last<=heap_last;box_coordinates<=0;state<=ANCHOR;
                end
            end
            ANCHOR:begin
                if(selected_anchor>=8000) begin selected_branch<=2;selected_local<=selected_anchor-14'd8000;selected_position<=selected_anchor-14'd8000;selected_plane<=400;selected_width<=20;end
                else if(selected_anchor>=6400) begin selected_branch<=1;selected_local<=selected_anchor-14'd6400;selected_position<=selected_anchor-14'd6400;selected_plane<=1600;selected_width<=40;end
                else begin selected_branch<=0;selected_local<=selected_anchor[12:0];selected_position<=selected_anchor[12:0];selected_plane<=6400;selected_width<=80;end
                selected_y<=0;component<=0;plane_offset<=0;state<=POSITION;
            end
            POSITION:if(selected_position>={6'd0,selected_width}) begin selected_position<=selected_position-{6'd0,selected_width};selected_y<=selected_y+1'b1;end
                else begin selected_x<=selected_position[6:0];state<=BOX;end
            BOX:if(cache_cmd_ready) state<=WAIT_BOX;
            WAIT_BOX:if(cache_out_valid) begin
                if(cache_error!=0||cache_tag!=m_tag) begin fault<=8'h10;state<=ABORT;end
                else begin box_code<=cache_data[7:0];state<=COORDINATE;end
            end
            COORDINATE:begin coordinate_addr<=coordinate_base+{15'd0,(component[0]?selected_y:selected_x),box_code,2'b00};state<=TABLE;end
            TABLE:if(cache_cmd_ready) state<=WAIT_TABLE;
            WAIT_TABLE:if(cache_out_valid) begin
                if(cache_error!=0||cache_tag!=m_tag) begin fault<=8'h20;state<=ABORT;end
                else begin
                    box_coordinates[component*32+:32]<=cache_data;
                    if(component==3) state<=OUTPUT;
                    else begin component<=component+1'b1;plane_offset<=plane_offset+selected_plane;state<=BOX;end
                end
            end
            OUTPUT:if(m_ready) state<=m_last?IDLE:WAIT_TOP;
            ABORT:if(!cache_busy) begin m_error<=fault;m_index<=0;m_last<=1;box_coordinates<=0;output_score<=0;output_class<=0;state<=OUTPUT;end
            default:begin fault<=8'h40;state<=ABORT;end
        endcase
    end
endmodule
`default_nettype wire
