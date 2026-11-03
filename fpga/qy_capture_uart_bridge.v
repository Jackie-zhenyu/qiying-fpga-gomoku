`timescale 1ns/1ps
`default_nettype none
// Offline diagnostic link only. Both resets must assert for any reset of either
// domain; release each reset synchronously in its own clock domain. Toggle
// mailboxes retain payload until the remote acknowledgement has crossed back.
module qy_capture_uart_bridge #(
    parameter integer CLOCK_HZ = 25000000,
    parameter integer BAUD = 1000000
)(
    input wire bus_clk, input wire bus_reset_n,
    input wire uart_clk, input wire uart_reset_n,
    input wire uart_rx, output reg uart_tx,
    output reg req_valid, input wire req_ready, output reg [63:0] req_nonce,
    input wire tx_byte_valid, output wire tx_byte_ready,
    input wire [7:0] tx_byte
);
    localparam integer DIV = CLOCK_HZ / BAUD;
    function [31:0] crc_byte;
        input [31:0] c; input [7:0] d;
        reg [31:0] v; integer k;
        begin v=c^{24'd0,d}; for(k=0;k<8;k=k+1)
            v=v[0] ? ((v>>1)^32'hedb88320) : (v>>1);
            crc_byte=v;
        end
    endfunction

    reg [63:0] nonce_mailbox;
    reg req_toggle, req_ack;
    (* ASYNC_REG = "TRUE" *) reg req_s1, req_s2, req_ack_s1, req_ack_s2;
    (* ASYNC_REG = "TRUE" *) reg ready_s1, ready_s2;
    reg [7:0] tx_mailbox;
    reg tx_toggle, tx_ack;
    (* ASYNC_REG = "TRUE" *) reg tx_s1, tx_s2, tx_ack_s1, tx_ack_s2;
    assign tx_byte_ready = bus_reset_n && (tx_toggle == tx_ack_s2);
    always @(posedge bus_clk or negedge bus_reset_n) begin
        if(!bus_reset_n) begin
            req_s1<=0; req_s2<=0; req_ack<=0; req_valid<=0; req_nonce<=0;
            tx_ack_s1<=0; tx_ack_s2<=0; tx_toggle<=0; tx_mailbox<=0;
        end else begin
            req_s1<=req_toggle; req_s2<=req_s1;
            tx_ack_s1<=tx_ack; tx_ack_s2<=tx_ack_s1;
            if(!req_valid && req_s2!=req_ack) begin
                req_nonce<=nonce_mailbox; req_valid<=1;
            end
            if(req_valid && req_ready) begin req_valid<=0; req_ack<=req_s2; end
            if(tx_byte_valid && tx_byte_ready) begin
                tx_mailbox<=tx_byte; tx_toggle<=~tx_toggle;
            end
        end
    end

    reg [9:0] tx_shift;
    reg [3:0] tx_bits;
    reg [15:0] tx_count;
    always @(posedge uart_clk or negedge uart_reset_n) begin
        if(!uart_reset_n) begin
            tx_s1<=0; tx_s2<=0; tx_ack<=0; tx_shift<=10'h3ff;
            tx_bits<=0; tx_count<=0; uart_tx<=1;
            req_ack_s1<=0; req_ack_s2<=0; ready_s1<=0; ready_s2<=0;
        end else begin
            tx_s1<=tx_toggle; tx_s2<=tx_s1;
            req_ack_s1<=req_ack; req_ack_s2<=req_ack_s1;
            ready_s1<=req_ready; ready_s2<=ready_s1;
            if(tx_bits==0) begin
                if(tx_s2!=tx_ack) begin
                    tx_shift<={1'b1,tx_mailbox,1'b0}; tx_bits<=10;
                    tx_count<=DIV-1; tx_ack<=tx_s2; uart_tx<=0;
                end
            end else if(tx_count==0) begin
                tx_shift<={1'b1,tx_shift[9:1]}; tx_bits<=tx_bits-1'b1;
                tx_count<=DIV-1; uart_tx<=tx_shift[1];
            end else tx_count<=tx_count-1'b1;
        end
    end

    (* ASYNC_REG = "TRUE" *) reg rx_s1, rx_s2;
    reg [1:0] rx_state;
    reg [15:0] rx_count;
    reg [2:0] rx_bit;
    reg [7:0] rx_shift, rx_data;
    reg rx_valid;
    always @(posedge uart_clk or negedge uart_reset_n) begin
        if(!uart_reset_n) begin
            rx_s1<=1; rx_s2<=1; rx_state<=0; rx_count<=0;
            rx_bit<=0; rx_shift<=0; rx_data<=0; rx_valid<=0;
        end else begin
            rx_s1<=uart_rx; rx_s2<=rx_s1; rx_valid<=0;
            case(rx_state)
            0: if(!rx_s2) begin rx_state<=1; rx_count<=(DIV/2)-1; end
            1: if(rx_count!=0) rx_count<=rx_count-1'b1;
               else if(!rx_s2) begin rx_state<=2; rx_count<=DIV-1; rx_bit<=0; end
               else rx_state<=0;
            2: if(rx_count!=0) rx_count<=rx_count-1'b1;
               else begin rx_shift[rx_bit]<=rx_s2; rx_count<=DIV-1;
                   if(rx_bit==7) rx_state<=3; else rx_bit<=rx_bit+1'b1;
               end
            3: if(rx_count!=0) rx_count<=rx_count-1'b1;
               else begin
                   if(rx_s2) begin rx_data<=rx_shift; rx_valid<=1; end
                   rx_state<=0;
               end
            endcase
        end
    end

    reg [4:0] pos;
    reg [31:0] request_crc, crc_received;
    reg [63:0] nonce_shift;
    reg [15:0] idle_count;
    always @(posedge uart_clk or negedge uart_reset_n) begin
        if(!uart_reset_n) begin
            pos<=0; request_crc<=32'hffffffff; crc_received<=0;
            nonce_shift<=0; nonce_mailbox<=0; req_toggle<=0; idle_count<=0;
        end else begin
            if(pos!=0) begin
                if(idle_count==16'd24999) begin pos<=0; idle_count<=0; end
                else idle_count<=idle_count+1'b1;
            end
            if(rx_valid) begin
                idle_count<=0;
                if(pos==0) begin
                    if(rx_data==8'h51) begin pos<=1; request_crc<=crc_byte(32'hffffffff,rx_data); end
                end else if(pos<4) begin
                    if((pos==1 && rx_data==8'h59) || (pos==2 && rx_data==8'h43) || (pos==3 && rx_data==8'h31)) begin
                        pos<=pos+1'b1; request_crc<=crc_byte(request_crc,rx_data);
                    end else if(rx_data==8'h51) begin pos<=1; request_crc<=crc_byte(32'hffffffff,rx_data); end
                    else pos<=0;
                end else if(pos<12) begin
                    nonce_shift<={rx_data,nonce_shift[63:8]};
                    request_crc<=crc_byte(request_crc,rx_data); pos<=pos+1'b1;
                end else if(pos<15) begin
                    crc_received<={rx_data,crc_received[31:8]}; pos<=pos+1'b1;
                end else begin
                    pos<=0;
                    if({rx_data,crc_received[31:8]}==~request_crc &&
                       req_toggle==req_ack_s2 && ready_s2) begin
                        nonce_mailbox<=nonce_shift; req_toggle<=~req_toggle;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
