`timescale 1ns/1ps
`default_nettype none
// RGB bytes are row-major R,G,B. Upstream must hold valid/data under stall.
// frame_error is sticky from begin through the final payload handshake; it must
// be known by that handshake (snapshot contents must remain frozen meanwhile).
module qy_capture_packet #(
    parameter integer WIDTH=1920, HEIGHT=1080,
    parameter integer SOURCE_WIDTH=1920, SOURCE_HEIGHT=1080
)(
    input wire bus_clk, input wire bus_reset_n,
    input wire begin_valid, output wire begin_ready,
    input wire [63:0] begin_nonce, input wire [31:0] begin_frame_id,
    input wire [7:0] begin_status,
    input wire rgb_byte_valid, output wire rgb_byte_ready,
    input wire [7:0] rgb_byte, input wire frame_error,
    output reg tx_byte_valid, input wire tx_byte_ready,
    output reg [7:0] tx_byte, output reg packet_done
);
    localparam [31:0] PAYLOAD_BYTES=WIDTH*HEIGHT*3;
    localparam [31:0] PIXELS=WIDTH*HEIGHT;
    reg [1:0] state;
    reg [5:0] header_index;
    reg [2:0] trailer_index;
    reg [31:0] payload_index, header_crc, payload_crc, trailer_status;
    reg [63:0] nonce;
    reg [31:0] frame_id;
    reg [7:0] status;
    reg error_seen;
    wire [31:0] length_field = status==0 ? PAYLOAD_BYTES : 32'd0;
    wire [31:0] pixel_field = status==0 ? PIXELS : 32'd0;
    wire [31:0] final_header_crc=~header_crc;
    wire [31:0] final_payload_crc=~payload_crc;
    function [31:0] crc_byte;
        input [31:0] c; input [7:0] d; reg [31:0] v; integer k;
        begin v=c^{24'd0,d}; for(k=0;k<8;k=k+1)
            v=v[0] ? ((v>>1)^32'hedb88320) : (v>>1);
            crc_byte=v;
        end
    endfunction
    assign begin_ready=state==0;
    assign rgb_byte_ready=state==2 && tx_byte_ready;
    always @* begin
        tx_byte_valid=state!=0; tx_byte=0;
        case(state)
        1: case(header_index)
            0: tx_byte=8'h51; 1: tx_byte=8'h59; 2: tx_byte=8'h46; 3: tx_byte=8'h31;
            4: tx_byte=1; 5: tx_byte=status; 6: tx_byte=1; 7: tx_byte=1;
            8: tx_byte=48; 9: tx_byte=0;
            10: tx_byte=WIDTH&255; 11: tx_byte=(WIDTH>>8)&255;
            12: tx_byte=HEIGHT&255; 13: tx_byte=(HEIGHT>>8)&255;
            14,15: tx_byte=0;
            16,17,18,19: tx_byte=length_field>>((header_index-16)*8);
            20,21,22,23,24,25,26,27: tx_byte=nonce>>((header_index-20)*8);
            28,29,30,31: tx_byte=frame_id>>((header_index-28)*8);
            32: tx_byte=SOURCE_WIDTH&255; 33: tx_byte=(SOURCE_WIDTH>>8)&255;
            34: tx_byte=SOURCE_HEIGHT&255; 35: tx_byte=(SOURCE_HEIGHT>>8)&255;
            36,37,38,39: tx_byte=pixel_field>>((header_index-36)*8);
            40,41,42,43: tx_byte=0;
            44,45,46,47: tx_byte=final_header_crc>>((header_index-44)*8);
            default: tx_byte=0;
        endcase
        2: begin tx_byte_valid=rgb_byte_valid; tx_byte=rgb_byte; end
        3: if(trailer_index<4) tx_byte=trailer_status>>(trailer_index*8);
           else tx_byte=final_payload_crc>>((trailer_index-4)*8);
        default: begin tx_byte_valid=0; tx_byte=0; end
        endcase
    end
    always @(posedge bus_clk or negedge bus_reset_n) begin
        if(!bus_reset_n) begin
            state<=0; header_index<=0; trailer_index<=0; payload_index<=0;
            header_crc<=32'hffffffff; payload_crc<=32'hffffffff;
            nonce<=0; frame_id<=0; status<=0; error_seen<=0;
            trailer_status<=0; packet_done<=0;
        end else begin
            packet_done<=0;
            if(state!=0 && frame_error) error_seen<=1;
            if(state==0 && begin_valid) begin
                nonce<=begin_nonce; frame_id<=begin_frame_id; status<=begin_status;
                header_index<=0; payload_index<=0; trailer_index<=0;
                header_crc<=32'hffffffff; payload_crc<=32'hffffffff;
                error_seen<=frame_error; state<=1;
            end else if(tx_byte_valid && tx_byte_ready) begin
                case(state)
                1: begin
                    if(header_index<44) header_crc<=crc_byte(header_crc,tx_byte);
                    if(header_index==47) begin
                        if(status!=0) begin state<=3; trailer_status<={24'd0,status}; end
                        else state<=2;
                    end else header_index<=header_index+1'b1;
                end
                2: begin
                    payload_crc<=crc_byte(payload_crc,rgb_byte);
                    if(payload_index==PAYLOAD_BYTES-1) begin
                        state<=3; trailer_status<=(error_seen || frame_error) ? 32'd1 : 32'd0;
                    end else payload_index<=payload_index+1'b1;
                end
                3: if(trailer_index==7) begin state<=0; packet_done<=1; end
                   else trailer_index<=trailer_index+1'b1;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
