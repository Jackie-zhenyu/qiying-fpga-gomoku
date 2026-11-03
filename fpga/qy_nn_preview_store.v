`timescale 1ns/1ps
`default_nettype none
// Two bounded256x1449bit banks: flag0+RGB332 or flag1+2bit box class.
// A marked pixel is opaque, so its underlying color need not be retained.
// This halves36,864x18 double-bank ERAM cost without changing geometry or
// inference pixels. Only the secondary UI photo is color-quantized.
// One belongs to the pixel reader;
// the other belongs to the active inference. Publish only after all image
// samples,256 decoded records and successful inference completion. Swap only
// at video blanking, then acknowledge before reusing the retired bank.
// All RAM address/write registers use synchronous resets. Paired CDC resets
// must assert together; each deasserts synchronously in its own domain.
module qy_nn_preview_store(
    input wire clk,input wire rst,input wire video_clk,input wire video_rst,
    output wire perf_display_ack,
    input wire begin_valid,output wire begin_ready,input wire [31:0] begin_tag,begin_frame,
    input wire sample_valid,input wire [15:0] sample_index,sample_rgb565,
    input wire box_valid,output wire box_ready,input wire [31:0] box_tag,
    input wire [8:0] box_index,input wire [191:0] box_data,input wire box_last,
    input wire finish_valid,input wire finish_success,input wire [31:0] finish_tag,
    output reg [7:0] error_o,
    input wire video_blank,input wire [15:0] read_address,
    output wire [15:0] read_rgb565,output wire [1:0] read_mask,
    output wire read_valid,output reg [31:0] display_tag,display_frame
);
    (* ram_style="bram" *) reg [8:0] bank0[0:36863];
    (* ram_style="bram" *) reg [8:0] bank1[0:36863];
    (* keep="true" *) reg [15:0] nn_address,video_address;
    reg nn_write,nn_bank;reg [8:0] nn_data;
    reg [8:0] nn_q0,nn_q1,video_q0,video_q1;
    reg read_bank_q,read_bank,read_good_q,read_good;
    reg front_bank,front_valid;
    always @(posedge clk) begin
        if(nn_write&&!nn_bank) bank0[nn_address]<=nn_data;
        if(nn_write&&nn_bank) bank1[nn_address]<=nn_data;
        nn_q0<=bank0[nn_address];nn_q1<=bank1[nn_address];
    end
    always @(posedge video_clk) begin
        video_q0<=bank0[video_address];video_q1<=bank1[video_address];
    end
    wire [8:0] selected=read_bank?video_q1:video_q0;
    assign read_rgb565={selected[7:5],selected[7:6],selected[4:2],selected[4:2],selected[1:0],selected[1:0],selected[1]};
    assign read_mask=selected[8]?selected[1:0]:2'b00;assign read_valid=read_good;
    wire [8:0] prior_pixel=nn_bank?nn_q1:nn_q0;
    wire [1:0] prior_stroke=prior_pixel[8]?prior_pixel[1:0]:2'b00;
    localparam [3:0] IDLE=0,ACTIVE=1,MASK_READ=2,MASK_WRITE=3,MASK_DRAIN=4,PUBLISH=5,WAIT_ACK=6;
    reg [3:0] state;reg source_front;
    reg [31:0] tag,frame;reg [15:0] samples;reg [8:0] boxes;
    reg finishing,finished_success,raster_busy;reg [1:0] stroke;
    wire raster_ready,raster_valid,raster_done,raster_drawn;
    wire [15:0] raster_address;wire [1:0] raster_class;wire [31:0] raster_tag,raster_done_tag;wire [2:0] raster_error;
    assign begin_ready=!rst&&state==IDLE;
    assign box_ready=!rst&&state==ACTIVE&&!finishing&&!sample_valid&&!raster_busy&&raster_ready;
    wire accepted_box=box_valid&&box_ready;
    qy_detection_raster raster(
        .clk(clk),.rst(rst),.cancel(1'b0),.cmd_valid(accepted_box),.cmd_ready(raster_ready),.cmd_tag(box_tag),.cmd_box(box_data),
        .pixel_valid(raster_valid),.pixel_ready(state==ACTIVE&&!sample_valid),.pixel_address(raster_address),
        .pixel_class(raster_class),.pixel_tag(raster_tag),.done_valid(raster_done),.done_ready(1'b1),
        .done_tag(raster_done_tag),.done_error(raster_error),.drawn(raster_drawn));
    wire publish_ready,ack_valid,ack_data,m_valid,m_response_ready;
    assign perf_display_ack=state==WAIT_ACK&&ack_valid;wire [64:0] m_data;
    qy_cdc_request_response #(.REQUEST_BITS(65),.RESPONSE_BITS(1)) publication(
        .s_clk(clk),.s_rst(rst),.s_valid(state==PUBLISH),.s_ready(publish_ready),.s_data({tag,frame,nn_bank}),
        .s_response_valid(ack_valid),.s_response_ready(state==WAIT_ACK),.s_response_data(ack_data),
        .m_clk(video_clk),.m_rst(video_rst),.m_valid(m_valid),.m_ready(video_blank),.m_data(m_data),
        .m_response_valid(1'b1),.m_response_ready(m_response_ready),.m_response_data(m_data[0]));
    always @(posedge video_clk) begin
        if(video_rst) begin
            front_bank<=0;front_valid<=0;display_tag<=0;display_frame<=0;
            video_address<=0;read_bank_q<=0;read_bank<=0;read_good_q<=0;read_good<=0;
        end else begin
            if(m_valid&&video_blank) begin front_bank<=m_data[0];display_frame<=m_data[32:1];display_tag<=m_data[64:33];front_valid<=1;end
            video_address<=read_address<36864?read_address:16'd0;
            read_bank_q<=front_bank;read_bank<=read_bank_q;
            read_good_q<=front_valid&&read_address<36864;read_good<=read_good_q;
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;source_front<=0;nn_address<=0;nn_write<=0;nn_bank<=1;nn_data<=0;
            tag<=0;frame<=0;samples<=0;boxes<=0;finishing<=0;finished_success<=0;raster_busy<=0;stroke<=0;error_o<=0;
        end else begin
            nn_write<=0;
            if(finish_valid&&state!=IDLE&&state!=PUBLISH&&state!=WAIT_ACK) begin
                finishing<=1;finished_success<=finish_success;
                if(finish_tag!=tag) error_o[4]<=1;
            end
            if(raster_done) begin
                raster_busy<=0;
                if(raster_error!=0||raster_done_tag!=tag) error_o[3]<=1;
            end
            case(state)
                IDLE:if(begin_valid&&begin_ready) begin
                    tag<=begin_tag;frame<=begin_frame;nn_bank<=!source_front;samples<=0;boxes<=0;
                    finishing<=0;finished_success<=0;error_o<=0;state<=ACTIVE;
                end
                ACTIVE:begin
                    if(sample_valid) begin
                        if(sample_index!=samples||samples>=36864||boxes!=0) error_o[1]<=1;
                        else begin nn_address<=sample_index;nn_data<={1'b0,sample_rgb565[15:13],sample_rgb565[10:8],sample_rgb565[4:3]};nn_write<=1;samples<=samples+1'b1;end
                    end else if(raster_valid) begin
                        if(raster_tag!=tag||raster_address>=36864) error_o[3]<=1;
                        else begin nn_address<=raster_address;stroke<=raster_class;state<=MASK_READ;end
                    end
                    if(accepted_box) begin
                        raster_busy<=1;
                        if(box_tag!=tag||box_index!=boxes||box_last!=(box_index==255)||boxes>=256) error_o[2]<=1;
                        if(boxes<256) boxes<=boxes+1'b1;
                    end
                    if(finishing&&!raster_busy&&!raster_valid&&!raster_done&&!nn_write) begin
                        if(!finished_success||samples!=36864||boxes!=256||error_o!=0) begin
                            if(!finished_success) error_o[0]<=1;
                            if(samples!=36864) error_o[1]<=1;
                            if(boxes!=256) error_o[2]<=1;
                            state<=IDLE;
                        end else state<=PUBLISH;
                    end
                end
                MASK_READ:state<=MASK_WRITE;
                MASK_WRITE:begin nn_data<={1'b1,6'd0,prior_stroke|stroke};nn_write<=1;state<=MASK_DRAIN;end
                MASK_DRAIN:state<=ACTIVE;
                PUBLISH:if(publish_ready) state<=WAIT_ACK;
                WAIT_ACK:if(ack_valid) begin
                    if(ack_data!=nn_bank) begin error_o[6]<=1;state<=7;end
                    else begin source_front<=ack_data;state<=IDLE;end
                end
                7:state<=7; // Publication ownership is uncertain: require paired reset.
                default:begin error_o[7]<=1;state<=IDLE;end
            endcase
        end
    end
endmodule
`default_nettype wire
