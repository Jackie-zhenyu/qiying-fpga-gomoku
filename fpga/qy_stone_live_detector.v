`timescale 1ns/1ps
`default_nettype none
// Sample a complete source frame; inspect it while the independent live video
// keeps running. Require a matching detection in two successive inspections.
module qy_stone_live_detector #(
    parameter OFFSET_FILE="stone_ring_offsets.hex"
)(
    input wire clk,rst_n,camera_ready,
    input wire [23:0] rgb,
    input wire de,vs,
    output reg result_valid,
    output reg [1023:0] boxes,
    output reg [5:0] box_count,
    output reg [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
    output reg [7:0] error,
    output wire busy
);
    localparam IDLE=0,CAPTURE=1,DETECT=2,CONFIRM_INIT=3,CONFIRM_CHECK=4,PUBLISH=5;
    reg [2:0] state;
    reg [11:0] x,y;
    reg [2:0] xm,ym;
    reg de_d,vs_d,bad;
    reg [16:0] samples;
    reg [31:0] frame_counter,capture_frame,elapsed;
    wire frame_edge=vs&&!vs_d;
    wire sample_now=state==CAPTURE && !bad && !frame_edge && camera_ready && de &&
        x<1920 && y<1080 && xm==1 && ym==1 && samples<57600;
    wire [9:0] gray_sum={2'b0,rgb[23:16]}+{1'b0,rgb[15:8],1'b0}+{2'b0,rgb[7:0]};
    wire paper=({1'b0,rgb[23:16]}+9'd12>={1'b0,rgb[15:8]}) &&
        ({1'b0,rgb[7:0]}<={1'b0,rgb[15:8]}+9'd20) &&
        ({1'b0,rgb[23:16],2'b0} <= {1'b0,rgb[7:0],2'b0}+{3'd0,rgb[15:8]}+11'd16);
    (* ram_style="bram" *) reg [8:0] raw[0:65535];
    (* keep="true" *) reg [15:0] write_address;
    reg [8:0] write_data,raw_data;
    reg write_enable;
    wire [15:0] read_address;
    always @(posedge clk)begin
        if(write_enable)raw[write_address]<=write_data;
        raw_data<=raw[read_address];
    end
    reg core_start;
    wire core_busy,core_done,core_overflow;
    wire [1023:0] core_boxes;
    wire [5:0] core_count;
    wire [31:0] core_cycles;
    qy_stone_ring_core #(.OFFSET_FILE(OFFSET_FILE)) core(
        .clk(clk),.rst_n(rst_n),.start(core_start),.busy(core_busy),.done(core_done),.overflow(core_overflow),
        .raw_address(read_address),.raw_data(raw_data),.boxes(core_boxes),.box_count(core_count),.cycles(core_cycles));
    reg [1023:0] previous,confirmed;
    reg [5:0] current_index,previous_index,confirmed_count;
    reg matched;
    wire [31:0] current_word=core_boxes[current_index[4:0]*32+:32];
    wire [31:0] previous_word=previous[previous_index[4:0]*32+:32];
    wire [8:0] dx=current_word[8:0]>=previous_word[8:0]?current_word[8:0]-previous_word[8:0]:previous_word[8:0]-current_word[8:0];
    wire [7:0] dy=current_word[16:9]>=previous_word[16:9]?current_word[16:9]-previous_word[16:9]:previous_word[16:9]-current_word[16:9];
    wire [3:0] dr=current_word[20:17]>=previous_word[20:17]?current_word[20:17]-previous_word[20:17]:previous_word[20:17]-current_word[20:17];
    wire match_now=current_word[23] && previous_word[23] &&
        current_word[22:21]==previous_word[22:21] && dx<=24 && dy<=24 && dr<=2;
    assign busy=state!=IDLE;
    always @(posedge clk)begin
        if(!rst_n)begin
            state<=IDLE;x<=0;y<=0;xm<=0;ym<=0;de_d<=0;vs_d<=0;bad<=0;samples<=0;
            frame_counter<=0;capture_frame<=0;elapsed<=0;
            write_address<=0;write_data<=0;write_enable<=0;core_start<=0;
            previous<=0;confirmed<=0;current_index<=0;previous_index<=0;confirmed_count<=0;matched<=0;
            result_valid<=0;boxes<=0;box_count<=0;result_sequence<=0;source_frame<=0;
            compute_cycles<=0;total_cycles<=0;error<=0;
        end else begin
            result_valid<=0;core_start<=0;de_d<=de;vs_d<=vs;
            write_enable<=sample_now;write_address<=samples[15:0];write_data<={paper,gray_sum[9:2]};
            if(state!=IDLE)elapsed<=elapsed+1'b1;
            if(frame_edge)begin
                frame_counter<=frame_counter+1'b1;x<=0;y<=0;xm<=0;ym<=0;
            end else if(de)begin
                if(x<4095)x<=x+1'b1;
                xm<=xm==5?0:xm+1'b1;
            end else begin
                x<=0;xm<=0;
                if(de_d)begin if(y<4095)y<=y+1'b1;ym<=ym==5?0:ym+1'b1;end
            end
            case(state)
                IDLE:if(frame_edge && camera_ready)begin
                    samples<=0;bad<=0;elapsed<=0;capture_frame<=frame_counter+1'b1;state<=CAPTURE;
                end
                CAPTURE:begin
                    if(sample_now)samples<=samples+1'b1;
                    if(!camera_ready || (de&&(x>=1920||y>=1080)) || (!de&&de_d&&x!=1920))bad<=1;
                    if(frame_edge)begin
                        if(!bad && camera_ready && !de && y==1080 && samples==57600)begin core_start<=1;state<=DETECT;end
                        else begin
                            previous<=0;boxes<=0;box_count<=0;error<=8'd2;result_valid<=1;
                            result_sequence<=result_sequence+1'b1;source_frame<=capture_frame;
                            compute_cycles<=0;total_cycles<=elapsed;state<=IDLE;
                        end
                    end
                end
                DETECT:if(core_done)begin
                    compute_cycles<=core_cycles;confirmed<=0;confirmed_count<=0;current_index<=0;
                    error<=core_overflow?8'd1:8'd0;
                    state<=CONFIRM_INIT;
                end
                CONFIRM_INIT:begin
                    previous_index<=0;matched<=0;
                    if(current_index==32)state<=PUBLISH;
                    else if(!current_word[23])current_index<=current_index+1'b1;
                    else state<=CONFIRM_CHECK;
                end
                CONFIRM_CHECK:begin
                    if(match_now)matched<=1;
                    if(previous_index==31)begin
                        if(matched||match_now)begin
                            confirmed[current_index[4:0]*32+:32]<=current_word;
                            confirmed_count<=confirmed_count+1'b1;
                        end
                        current_index<=current_index+1'b1;state<=CONFIRM_INIT;
                    end else previous_index<=previous_index+1'b1;
                end
                PUBLISH:begin
                    previous<=camera_ready&&!core_overflow?core_boxes:1024'd0;
                    boxes<=camera_ready&&!core_overflow?confirmed:1024'd0;
                    box_count<=camera_ready&&!core_overflow?confirmed_count:6'd0;
                    if(!camera_ready)error<=8'd4;
                    result_valid<=1;result_sequence<=result_sequence+1'b1;
                    source_frame<=capture_frame;total_cycles<=elapsed;state<=IDLE;
                end
                default:begin state<=IDLE;boxes<=0;previous<=0;box_count<=0;error<=8'd8;end
            endcase
        end
    end
endmodule
`default_nettype wire
