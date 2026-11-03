`timescale 1ns/1ps
`default_nettype none
// Bounded diagnostic recording only; never an official game-state producer.
// Commands: nonce[63:48]=16'h434c, opcode[47:40] 1 ARM/2 META/3 READ,
// argument[39:32]=frame count or index, token[31:0] chosen by host.
// Recorders retain at most32 immutable full camera frames; UART export follows.
module qy_clip_controller #(
    parameter [31:0] BUS_HZ=233372000,
    parameter [63:0] PERIOD_TICKS=46674400,
    parameter [63:0] DELAY_TICKS=466744000
)(
    input wire clk,rst,
    input wire cmd_valid,output wire cmd_ready,input wire [63:0] cmd_nonce,
    output reg reply_valid,input wire reply_ready,output reg [639:0] reply_data,
    input wire [63:0] current_tick,
    output wire lock_new_clients,
    output wire clear_clip,
    input wire memory_idle,
    output wire request_valid,input wire request_ready,
    output wire request_retain,request_replay,request_export,request_subsample,
    output wire [63:0] request_nonce,
    output wire [5:0] request_slot,output wire [31:0] request_frame,
    input wire response_valid,output wire response_ready,
    input wire [7:0] response_status,
    input wire [31:0] response_frame,response_base,
    input wire [63:0] response_start_tick,response_end_tick,response_ready_tick,
    output wire release_frame,
    input wire replay_packet_done,
    output wire [5:0] captured_count,
    output wire [31:0] clip_epoch,
    output wire [7:0] clip_error,
    output wire recording
);
    localparam IDLE=0,ARM_REPLY=1,CLEAR=2,DELAY=3,WAIT_DUE=4,
        CAP_REQUEST=5,CAP_RESPONSE=6,CAP_RELEASE=7,CAP_DRAIN=8,HOLD=9,
        READ_REQUEST=10,READ_RESPONSE=11,READ_STREAM=12,READ_DRAIN=13,CAP_COMMIT=14,CMD_EXEC=15;
    reg [3:0] state;
    reg [5:0] count,target_count;
    reg [31:0] epoch;
    reg [7:0] error_code;
    reg [63:0] active_nonce,last_arm_nonce,due_tick;
    reg have_arm;
    reg [4:0] read_index;
    reg [63:0] accepted_nonce;
    reg accepted_bad_command,accepted_arm,accepted_meta;
    reg accepted_duplicate_arm,accepted_bad_arm,accepted_index_valid,command_from_hold;
    reg [31:0] last_good_frame,pending_frame,pending_base;
    reg [63:0] last_good_start,pending_start,pending_end,pending_ready;
    reg [7:0] pending_status;
    reg invalid_frame,invalid_span,invalid_ready,invalid_order;
    reg [5:0] slots[0:31];
    reg [31:0] frames[0:31];
    reg [63:0] starts[0:31],ends[0:31],ready_times[0:31];
    wire [7:0] opcode=accepted_nonce[47:40],argument=accepted_nonce[39:32];
    wire usable=(state==HOLD || state==IDLE);
    assign cmd_ready=!rst&&usable&&!reply_valid;
    assign lock_new_clients=!usable;
    assign recording=(state>=ARM_REPLY&&state<=CAP_DRAIN)||state==CAP_COMMIT;
    assign clear_clip=!rst&&state==CLEAR&&memory_idle;
    assign request_valid=!rst&&(state==CAP_REQUEST||state==READ_REQUEST);
    assign request_retain=state==CAP_REQUEST;
    assign request_replay=state==READ_REQUEST;
    assign request_export=state==READ_REQUEST;
    assign request_subsample=state==READ_REQUEST;
    assign request_nonce=active_nonce;
    assign request_slot=slots[read_index];
    assign request_frame=frames[read_index];
    // READ responses are consumed by the image packet, not this port.
    assign response_ready=!rst&&state==CAP_RESPONSE;
    assign release_frame=!rst&&state==CAP_RELEASE;
    assign captured_count=count;assign clip_epoch=epoch;assign clip_error=error_code;
    task queue_reply;
        input [7:0] code;
        input [63:0] nonce_value;
        input [7:0] op,index;
        input include_descriptor;
        begin
            reply_valid<=1;reply_data<=0;
            reply_data[31:0]<=32'h314c4351; // QCL1 inside standard QYND+CRC
            reply_data[95:32]<=nonce_value;
            reply_data[103:96]<=op;reply_data[111:104]<=code;
            reply_data[119:112]<={2'b0,count};reply_data[127:120]<=index;
            if(include_descriptor) begin
                reply_data[159:128]<=frames[index[4:0]];
                reply_data[191:160]<={2'b0,slots[index[4:0]],24'd0};
                reply_data[255:192]<=starts[index[4:0]];
                reply_data[319:256]<=ends[index[4:0]];
                reply_data[383:320]<=ready_times[index[4:0]];
            end
            reply_data[447:384]<=current_tick;
            reply_data[479:448]<=BUS_HZ;
            reply_data[543:480]<=PERIOD_TICKS;
            reply_data[575:544]<=epoch;
            reply_data[583:576]<=error_code;
            reply_data[591:584]<=command_from_hold?8'd9:8'd0;
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;count<=0;target_count<=0;epoch<=0;error_code<=0;
            active_nonce<=0;last_arm_nonce<=0;due_tick<=0;have_arm<=0;read_index<=0;
            reply_valid<=0;reply_data<=0;
            accepted_nonce<=0;accepted_bad_command<=0;accepted_arm<=0;accepted_meta<=0;
            accepted_duplicate_arm<=0;accepted_bad_arm<=0;accepted_index_valid<=0;command_from_hold<=0;
            last_good_frame<=0;last_good_start<=0;
            pending_frame<=0;pending_base<=0;pending_start<=0;pending_end<=0;pending_ready<=0;
            pending_status<=0;invalid_frame<=0;invalid_span<=0;invalid_ready<=0;invalid_order<=0;
        end else begin
            if(reply_valid&&reply_ready)reply_valid<=0;
            if(cmd_valid&&cmd_ready) begin
                accepted_nonce<=cmd_nonce;command_from_hold<=state==HOLD;
                accepted_bad_command<=cmd_nonce[63:48]!=16'h434c ||
                    (cmd_nonce[47:40]!=1 && cmd_nonce[47:40]!=2 && cmd_nonce[47:40]!=3);
                accepted_arm<=cmd_nonce[47:40]==1;accepted_meta<=cmd_nonce[47:40]==2;
                accepted_duplicate_arm<=have_arm&&last_arm_nonce==cmd_nonce;
                accepted_bad_arm<=cmd_nonce[39:32]==0||cmd_nonce[39:32]>32||epoch==32'hfffffffe;
                accepted_index_valid<=cmd_nonce[39:32]<{2'b0,count};
                state<=CMD_EXEC;
            end
            if(state==CMD_EXEC) begin
                state<=command_from_hold?HOLD:IDLE;
                if(accepted_bad_command)queue_reply(2,accepted_nonce,opcode,argument,accepted_index_valid);
                else if(accepted_arm) begin
                    if(accepted_duplicate_arm)queue_reply(0,accepted_nonce,opcode,8'hff,1'b0);
                    else if(accepted_bad_arm)queue_reply(3,accepted_nonce,opcode,argument,accepted_index_valid);
                    else begin
                        active_nonce<=accepted_nonce;last_arm_nonce<=accepted_nonce;have_arm<=1;
                        count<=0;target_count<=argument[5:0];epoch<=epoch+1'b1;error_code<=0;
                        last_good_frame<=0;last_good_start<=0;
                        state<=ARM_REPLY;
                        queue_reply(0,accepted_nonce,opcode,8'hff,1'b0);
                        reply_data[119:112]<=0;reply_data[575:544]<=epoch+1'b1;
                        reply_data[583:576]<=0;reply_data[591:584]<=ARM_REPLY;
                    end
                end else if(accepted_meta)queue_reply(0,accepted_nonce,opcode,argument,accepted_index_valid);
                else if(!accepted_index_valid)queue_reply(4,accepted_nonce,opcode,argument,1'b0);
                else begin
                    read_index<=argument[4:0];active_nonce<=accepted_nonce;state<=READ_REQUEST;
                end
            end
            case(state)
                ARM_REPLY: if(reply_valid&&reply_ready)state<=CLEAR;
                CLEAR: if(memory_idle) begin due_tick<=current_tick+DELAY_TICKS;state<=DELAY;end
                DELAY,WAIT_DUE: if(current_tick>=due_tick)state<=CAP_REQUEST;
                CAP_REQUEST: if(request_ready)begin due_tick<=current_tick+PERIOD_TICKS;state<=CAP_RESPONSE;end
                CAP_RESPONSE: if(response_valid)begin
                    pending_status<=response_status;
                    pending_frame<=response_frame;pending_base<=response_base;
                    pending_start<=response_start_tick;pending_end<=response_end_tick;pending_ready<=response_ready_tick;
                    invalid_frame<=response_frame==0 || response_frame==32'hffffffff;
                    invalid_span<=response_start_tick>=response_end_tick;
                    invalid_ready<=response_end_tick>response_ready_tick;
                    invalid_order<=count!=0 && (response_frame<=last_good_frame || response_start_tick<=last_good_start);
                    state<=CAP_COMMIT;
                end
                CAP_COMMIT: begin
                    if(pending_status!=0 || invalid_frame || invalid_span || invalid_ready || invalid_order)
                        error_code<=(pending_status!=0)?pending_status:8'h80;
                    else begin
                        slots[count[4:0]]<=pending_base[29:24];frames[count[4:0]]<=pending_frame;
                        starts[count[4:0]]<=pending_start;ends[count[4:0]]<=pending_end;
                        ready_times[count[4:0]]<=pending_ready;count<=count+1'b1;
                        last_good_frame<=pending_frame;last_good_start<=pending_start;
                    end
                    state<=CAP_RELEASE;
                end
                CAP_RELEASE:state<=CAP_DRAIN;
                CAP_DRAIN: if(memory_idle)begin
                    if(error_code!=0 || count>=target_count)state<=HOLD;else state<=WAIT_DUE;
                end
                READ_REQUEST:if(request_ready)state<=READ_RESPONSE;
                READ_RESPONSE:if(response_valid)state<=READ_STREAM;
                READ_STREAM:if(replay_packet_done)state<=READ_DRAIN;
                READ_DRAIN:if(memory_idle)state<=HOLD;
                default:begin end
            endcase
        end
    end
endmodule
`default_nettype wire
