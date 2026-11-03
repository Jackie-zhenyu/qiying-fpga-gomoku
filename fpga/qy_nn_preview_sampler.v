`timescale 1ns/1ps
`default_nettype none
// Tap the exact unquantized RGB pixels entering the model's640x360 interior.
// Bounded nearest-neighbor256x144 preview: positions0,2 out of each5, both axes.
// No second camera acquisition and no full-frame copy in DDR.
module qy_nn_preview_sampler(
    input wire clk,input wire rst,input wire begin_frame,
    input wire raw_valid,input wire [9:0] raw_x,raw_y,input wire [15:0] raw_rgb565,
    output reg sample_valid,output reg [15:0] sample_index,sample_rgb565,
    output reg complete,output reg error_o
);
    reg active;reg [9:0] x,y;reg [2:0] xm,ym;reg [15:0] samples;
    always @(posedge clk) begin
        if(rst) begin active<=0;x<=0;y<=0;xm<=0;ym<=0;samples<=0;sample_valid<=0;sample_index<=0;sample_rgb565<=0;complete<=0;error_o<=0;end
        else begin
            sample_valid<=0;
            if(begin_frame) begin active<=1;x<=0;y<=0;xm<=0;ym<=0;samples<=0;complete<=0;error_o<=0;end
            else if(raw_valid) begin
                if(!active||raw_x!=x||raw_y!=y) begin error_o<=1;active<=0;complete<=0;end
                else begin
                    if((xm==0||xm==2)&&(ym==0||ym==2)) begin
                        sample_valid<=1;sample_index<=samples;sample_rgb565<=raw_rgb565;samples<=samples+1'b1;
                    end
                    if(x==639) begin
                        x<=0;xm<=0;
                        if(y==359) begin active<=0;complete<=samples==36864;end
                        else begin y<=y+1'b1;ym<=ym==4?0:ym+1'b1;end
                    end else begin x<=x+1'b1;xm<=xm==4?0:xm+1'b1;end
                end
            end
        end
    end
endmodule
`default_nettype wire
