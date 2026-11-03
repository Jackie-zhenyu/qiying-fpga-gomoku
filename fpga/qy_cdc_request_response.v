`timescale 1ns/1ps
`default_nettype none
// One outstanding request per channel, bundled-data toggle handshake.
// Payload is held from request acceptance until its response is consumed.
// Two synchronizer stages precede each cross-domain payload capture.
// Both reset domains MUST assert together with the downstream bus reset;
// deassert each locally in synchrony. Job cancellation drains this channel
// and never independently resets it. Physical CDC constraints are required.
module qy_cdc_request_response #(
    parameter integer REQUEST_BITS=32,RESPONSE_BITS=257,
    parameter integer REQUEST_BANK_BITS=0
) (
    input wire s_clk,input wire s_rst,
    input wire s_valid,output wire s_ready,input wire [REQUEST_BITS-1:0] s_data,
    output wire s_response_valid,input wire s_response_ready,output reg [RESPONSE_BITS-1:0] s_response_data,
    input wire m_clk,input wire m_rst,
    output wire m_valid,input wire m_ready,output reg [REQUEST_BITS-1:0] m_data,
    input wire m_response_valid,output wire m_response_ready,input wire [RESPONSE_BITS-1:0] m_response_data
);
    reg [REQUEST_BITS-1:0] source_payload;
    reg [RESPONSE_BITS-1:0] memory_payload;
    reg request_toggle,response_toggle,source_busy,source_complete,memory_seen;
    (* ASYNC_REG="TRUE" *) reg response_meta,response_sync;
    (* ASYNC_REG="TRUE" *) reg request_meta,request_sync;
    reg [1:0] memory_state;
    localparam integer BANK_BITS=REQUEST_BANK_BITS>0?REQUEST_BANK_BITS:REQUEST_BITS;
    localparam integer BANKS=(REQUEST_BITS+BANK_BITS-1)/BANK_BITS;
    reg [(BANKS>1?$clog2(BANKS):1)-1:0] capture_bank;
    assign s_ready=!s_rst&&!source_busy;
    assign s_response_valid=!s_rst&&source_complete;
    assign m_valid=!m_rst&&memory_state==1;
    assign m_response_ready=!m_rst&&memory_state==2;
    always @(posedge s_clk or posedge s_rst) begin
        if(s_rst) begin
            source_payload<=0;s_response_data<=0;request_toggle<=0;source_busy<=0;source_complete<=0;response_meta<=0;response_sync<=0;
        end else begin
            response_meta<=response_toggle;response_sync<=response_meta;
            if(s_valid&&s_ready) begin source_payload<=s_data;request_toggle<=~request_toggle;source_busy<=1;end
            else if(source_busy&&!source_complete&&response_sync==request_toggle) begin s_response_data<=memory_payload;source_complete<=1;end
            if(s_response_valid&&s_response_ready) begin source_complete<=0;source_busy<=0;end
        end
    end
    always @(posedge m_clk or posedge m_rst) begin
        if(m_rst) begin memory_payload<=0;response_toggle<=0;memory_seen<=0;request_meta<=0;request_sync<=0;memory_state<=0;capture_bank<=0;end
        else begin
            request_meta<=request_toggle;request_sync<=request_meta;
            case(memory_state)
                0:if(request_sync!=memory_seen) begin
                    memory_seen<=request_sync;capture_bank<=0;
                    memory_state<=REQUEST_BANK_BITS>0?2'd3:2'd1;
                end
                1:if(m_ready) memory_state<=2;
                2:if(m_response_valid) begin memory_payload<=m_response_data;response_toggle<=memory_seen;memory_state<=0;end
                3:if(capture_bank==BANKS-1) memory_state<=1;
                  else capture_bank<=capture_bank+1'b1;
                default:memory_state<=0;
            endcase
        end
    end
    // source_payload stays immutable until the response is consumed. Only
    // publish m_valid after every bank has arrived, preserving one coherent
    // request under backpressure. Banking reduces the 640-bit capture-enable
    // fanout without relaxing the bundled-data physical delay constraint.
    generate if(REQUEST_BANK_BITS==0) begin:direct_capture
        always @(posedge m_clk or posedge m_rst)
            if(m_rst) m_data<=0;
            else if(memory_state==0&&request_sync!=memory_seen) m_data<=source_payload;
    end else begin:banked_capture
        genvar k;
        for(k=0;k<BANKS;k=k+1) begin:bank
            localparam integer BOTTOM=k*BANK_BITS;
            localparam integer WIDTH=(REQUEST_BITS-BOTTOM<BANK_BITS)?REQUEST_BITS-BOTTOM:BANK_BITS;
            always @(posedge m_clk or posedge m_rst)
                if(m_rst) m_data[BOTTOM+:WIDTH]<=0;
                else if(memory_state==3&&capture_bank==k)
                    m_data[BOTTOM+:WIDTH]<=source_payload[BOTTOM+:WIDTH];
        end
    end endgenerate
endmodule
`default_nettype wire
