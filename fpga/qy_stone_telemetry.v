`timescale 1ns/1ps
`default_nettype none
// Read-only SBX1 diagnostics over the existing CRC-protected QYND transport.
// Four pages describe one immutable result. No host computation or command is
// needed to detect/draw. Both mailbox reset domains share common_reset_n.
module qy_stone_telemetry(
    input wire video_clk,bus_clk,common_reset_n,
    input wire result_valid,input wire [1023:0] boxes,
    input wire [5:0] box_count,input wire [7:0] error,
    input wire [31:0] result_sequence,source_frame,compute_cycles,total_cycles,
    output wire diag_valid,input wire diag_ready,output wire [639:0] diag_data
);
    wire video_reset_n,bus_reset_n;
    qy_reset_sync vr(.clk_i(video_clk),.arst_n_i(common_reset_n),.rst_n_o(video_reset_n));
    qy_reset_sync br(.clk_i(bus_clk),.arst_n_i(common_reset_n),.rst_n_o(bus_reset_n));
    reg [2:0] state;
    reg [1:0] page;
    reg [1023:0] snapshot;
    reg [31:0] sequence_q,frame_q,compute_q,total_q,dropped,dropped_q;
    reg [7:0] error_q;
    reg [5:0] count_q;
    reg [639:0] packet;
    wire request_ready,response_valid;
    wire response_unused,m_response_ready;
    qy_cdc_request_response #(.REQUEST_BITS(640),.RESPONSE_BITS(1)) mailbox(
        .s_clk(video_clk),.s_rst(!video_reset_n),.s_valid(state==2),.s_ready(request_ready),.s_data(packet),
        .s_response_valid(response_valid),.s_response_ready(1'b1),.s_response_data(response_unused),
        .m_clk(bus_clk),.m_rst(!bus_reset_n),.m_valid(diag_valid),.m_ready(diag_ready),.m_data(diag_data),
        .m_response_valid(1'b1),.m_response_ready(m_response_ready),.m_response_data(1'b0));
    always @(posedge video_clk)begin
        if(!video_reset_n)begin
            state<=0;page<=0;snapshot<=0;sequence_q<=0;frame_q<=0;compute_q<=0;total_q<=0;
            dropped<=0;dropped_q<=0;error_q<=0;count_q<=0;packet<=0;
        end else begin
            if(result_valid&&state!=0)dropped<=dropped+1'b1;
            case(state)
                0:if(result_valid)begin
                    snapshot<=boxes;sequence_q<=result_sequence;frame_q<=source_frame;
                    compute_q<=compute_cycles;total_q<=total_cycles;error_q<=error;count_q<=box_count;
                    dropped_q<=dropped;page<=0;state<=1;
                end
                1:begin
                    packet<={128'd0,snapshot[page*256+:256],dropped_q,
                        8'd4,6'd0,page,2'd0,count_q,error_q,32'd137500000,
                        total_q,compute_q,frame_q,sequence_q,32'h31584253};state<=2;
                end
                2:if(request_ready)state<=3;
                3:if(response_valid)begin
                    if(page==3)state<=0;else begin page<=page+1'b1;state<=1;end
                end
                default:state<=0;
            endcase
        end
    end
endmodule
`default_nettype wire

