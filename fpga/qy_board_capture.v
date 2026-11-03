`timescale 1ns/1ps
`default_nettype none
// Independent camera-derived binary image. No game-board input exists here.
// Publish complete frames only; two banks prevent capture/display tearing.
module qy_board_capture #(parameter WIDTH=1920, HEIGHT=1080)(
    input wire clk_i,rst_n_i,
    input wire [23:0] rgb_i,
    input wire de_i,vs_i,camera_ready_i,
    input wire [17:0] read_addr_i,
    output wire ink_o,
    output reg image_valid_o
);
    localparam TW=WIDTH/3, TH=HEIGHT/3, PIXELS=TW*TH;
    localparam INTERIOR=(TW-2)*(TH-2);
    reg [11:0] x,y;
    reg de_d,vs_d,armed,bad,front;
    reg [17:0] pooled_count,filtered_count,write_index;
    wire frame_edge=vs_i&&!vs_d;
    // The submodules use synchronous reset only. Flush in-flight work on an
    // early VS so rejected pixels cannot be counted into the next frame.
    wire processing_rst_n=rst_n_i&&!frame_edge;
    wire input_valid=armed&&!bad&&!frame_edge&&de_i&&camera_ready_i&&x<WIDTH&&y<HEIGHT;
    wire pool_valid,filter_valid,filter_ink;
    wire [9:0] pool_x,filter_x;
    wire [8:0] pool_y,filter_y;
    wire [7:0] pool_gray;
    qy_dark_pool3 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) pool(
        .clk_i(clk_i),.rst_n_i(processing_rst_n),.valid_i(input_valid),.x_i(x),.y_i(y),.rgb_i(rgb_i),
        .valid_o(pool_valid),.x_o(pool_x),.y_o(pool_y),.gray_o(pool_gray));
    qy_board_line_filter #(.WIDTH(TW),.HEIGHT(TH)) filter(
        .clk_i(clk_i),.rst_n_i(processing_rst_n),.valid_i(pool_valid),.x_i(pool_x),.y_i(pool_y),
        .rgb_i({pool_gray,pool_gray,pool_gray}),.valid_o(filter_valid),
        .x_o(filter_x),.y_o(filter_y),.ink_o(filter_ink));

    (* ram_style="bram" *) reg bank0[0:PIXELS-1];
    (* ram_style="bram" *) reg bank1[0:PIXELS-1];
    (* keep="true" *) reg [17:0] read_addr_q,write_addr_q;
    (* keep="true" *) reg write_en0_q,write_en1_q,write_data_q;
    reg read0,read1,read_bank_q,read_bank_d;
    assign ink_o=read_bank_d?read1:read0;
    always @(posedge clk_i) begin
        if(write_en0_q)bank0[write_addr_q]<=write_data_q;
        if(write_en1_q)bank1[write_addr_q]<=write_data_q;
        read0<=bank0[read_addr_q];
        read1<=bank1[read_addr_q];
    end
    always @(posedge clk_i) begin
        if(!rst_n_i) begin
            read_addr_q<=0;write_addr_q<=0;write_en0_q<=0;write_en1_q<=0;write_data_q<=0;
            read_bank_q<=0;read_bank_d<=0;
            x<=0;y<=0;de_d<=0;vs_d<=0;armed<=0;bad<=0;front<=0;image_valid_o<=0;
            pooled_count<=0;filtered_count<=0;write_index<=TW+1;
        end else begin
            read_addr_q<=(read_addr_i<PIXELS)?read_addr_i:18'd0;
            read_bank_q<=front;read_bank_d<=read_bank_q;
            // Capture always writes the back bank. A private pending write may
            // retire after an invalidation, but that bank is never published.
            write_en0_q<=filter_valid&&armed&&!bad&&front&&!frame_edge;
            write_en1_q<=filter_valid&&armed&&!bad&&!front&&!frame_edge;
            write_addr_q<=write_index;write_data_q<=filter_ink;
            de_d<=de_i;vs_d<=vs_i;
            if(!camera_ready_i)image_valid_o<=0;
            if(frame_edge)begin
                if(armed&&!bad&&camera_ready_i&&!de_i&&y==HEIGHT&&
                   pooled_count==PIXELS&&filtered_count==INTERIOR&&
                   !pool_valid&&!filter_valid&&!write_en0_q&&!write_en1_q)begin
                    front<=!front;image_valid_o<=1;
                end else image_valid_o<=0;
                x<=0;y<=0;armed<=1;bad<=0;
                pooled_count<=0;filtered_count<=0;write_index<=TW+1;
            end else begin
                if(armed&&!camera_ready_i)bad<=1;
                if(pool_valid)begin
                    if(pooled_count<PIXELS)pooled_count<=pooled_count+1'b1;
                    else bad<=1;
                end
                if(filter_valid)begin
                    if(filtered_count<INTERIOR&&filter_x>0&&filter_x<TW-1&&filter_y>0&&filter_y<TH-1)
                        filtered_count<=filtered_count+1'b1;
                    else bad<=1;
                    write_index<=write_index+((filter_x==TW-2)?18'd3:18'd1);
                end
                if(de_i)begin
                    if(x<4095)x<=x+1'b1;
                    if(x>=WIDTH||y>=HEIGHT)bad<=1;
                end else begin
                    x<=0;
                    if(de_d)begin
                        if(x!=WIDTH)bad<=1;
                        if(y<4095)y<=y+1'b1;
                    end
                end
            end
        end
    end
    // synthesis translate_off
    initial if(WIDTH<9||HEIGHT<9||WIDTH>1920||HEIGHT>1080||WIDTH%3!=0||HEIGHT%3!=0)
        $fatal(1,"CONFIG_ERROR board capture dimensions");
    // synthesis translate_on
endmodule
`default_nettype wire
