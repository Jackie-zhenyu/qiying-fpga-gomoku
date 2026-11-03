`timescale 1ns/1ps
`default_nettype none
// Experimental, single clock domain. No official-board write port.
// Produces a tagged MOVE proposal; the game controller remains sole committer.
// Context layout and cell codes match contracts/protocol.json v2.
// safety_epoch must change on every interruption (including static occlusion),
// and may never wrap within a session. It is latched at IMAGE ACQUISITION.
// observable inputs need a real pixel-quality detector: this is NOT one.
module qy_observation_guard #(
    parameter integer BOARD_SIZE=13, parameter integer DYNAMIC_SIZE=0,
    parameter integer MIN_FRAMES=3,
    parameter [63:0] STABLE_US=250000,
    parameter [63:0] MAX_GAP_US=250000,
    parameter [63:0] MAX_AGE_US=500000,
    parameter [7:0] MIN_CONFIDENCE=160
)(
    input wire clk, rst, cancel,
    input wire session_ready, calibrated, safety_clear,
    input wire [3:0] board_size_i,
    input wire [191:0] current_context,
    input wire [31:0] safety_epoch,
    input wire [63:0] now_us,
    input wire [BOARD_SIZE*BOARD_SIZE*2-1:0] confirmed_cells,
    input wire [1:0] next_color,
    input wire terminal,
    input wire obs_valid, output wire obs_ready,
    input wire [191:0] obs_context,
    input wire [31:0] obs_safety_epoch,
    input wire [63:0] obs_frame_id, obs_capture_us,
    input wire [3:0] obs_board_size,
    input wire [15:0] obs_cell_count, obs_quality_flags,
    input wire obs_frame_complete, obs_board_observable,
    input wire [BOARD_SIZE*BOARD_SIZE*2-1:0] obs_cells,
    input wire [BOARD_SIZE*BOARD_SIZE-1:0] obs_observable,
    input wire [BOARD_SIZE*BOARD_SIZE*8-1:0] obs_confidence,
    output reg proposal_valid, input wire proposal_ready,
    output wire proposal_commit_allowed,
    output reg [191:0] proposal_context,
    output reg [31:0] proposal_safety_epoch,
    output reg [63:0] proposal_frame_id, proposal_capture_us,
    output reg [7:0] proposal_row, proposal_col,
    output reg [1:0] proposal_color,
    output reg [7:0] reason,
    output wire busy,
    output reg [15:0] stable_count
);
    localparam integer CELLS=BOARD_SIZE*BOARD_SIZE;
    localparam IDLE=0, SCAN=1, DECIDE=2, PUBLISH=3;
    // Diagnostic reason values are local to this candidate, not wire enums.
    localparam WAITING=0, ACCEPTED=1, BLOCKED=2, STALE=3, DUPLICATE=4,
        BAD_FRAME=5, BAD_CELL=6, OLD_CHANGED=7, MULTIPLE=8, WRONG_COLOR=9,
        NO_CHANGE=10, CANDIDATE=11, EXHAUSTED=12;
    reg [1:0] state;
    wire [3:0] active_size=DYNAMIC_SIZE?board_size_i:BOARD_SIZE;
    wire [15:0] active_count=active_size*active_size;
    reg [3:0] frozen_size;
    reg [191:0] active_context;
    reg [31:0] active_epoch;
    reg revoked, issued, have_frame, have_candidate;
    reg [63:0] last_frame, last_capture, first_capture;
    reg [63:0] frame, capture_time;
    reg [CELLS*2-1:0] frozen_cells, frozen_board;
    reg [CELLS-1:0] frozen_observable;
    reg [CELLS*8-1:0] frozen_confidence;
    reg [1:0] frozen_next;
    reg [7:0] index, change_index, candidate_index;
    wire active_cell=(index/BOARD_SIZE)<frozen_size && (index%BOARD_SIZE)<frozen_size;
    reg [1:0] change_color, candidate_color;
    reg [8:0] changes;
    reg bad_cell, old_changed;
    wire valid_context=current_context[63:0]!=0 && current_context[63:0]!=64'hffffffffffffffff &&
        current_context[127:64]!=0 && current_context[127:64]!=64'hffffffffffffffff &&
        current_context[159:128]!=0 && current_context[159:128]!=32'hffffffff &&
        current_context[191:160]!=32'hffffffff;
    wire permission=active_size>=5 && active_size<=BOARD_SIZE && session_ready && calibrated && safety_clear && valid_context &&
        safety_epoch!=32'hffffffff && !terminal && (next_color==1 || next_color==2);
    wire identity_changed=active_context!=current_context || active_epoch!=safety_epoch;
    wire blocked=cancel || !permission || identity_changed;
    wire invalidated=blocked || (state!=IDLE &&
        (confirmed_cells!=frozen_board || next_color!=frozen_next || frozen_size!=active_size));
    wire fresh=now_us!=64'hffffffffffffffff && now_us>=capture_time &&
        now_us-capture_time<=MAX_AGE_US;
    wire incoming_id_good=obs_frame_id!=0 && obs_frame_id!=64'hffffffffffffffff &&
        obs_capture_us!=64'hffffffffffffffff;
    wire incoming_fresh=now_us!=64'hffffffffffffffff && now_us>=obs_capture_us &&
        now_us-obs_capture_us<=MAX_AGE_US;
    wire [1:0] observed=frozen_cells[index*2+:2];
    wire [1:0] official=frozen_board[index*2+:2];
    wire same_candidate=have_candidate && candidate_index==change_index &&
        candidate_color==change_color && capture_time>=last_capture &&
        capture_time-last_capture<=MAX_GAP_US;
    assign obs_ready=!rst && state==IDLE && !blocked && !issued;
    assign busy=state!=IDLE;
    // Packet fields and valid remain held under backpressure. Permission is a
    // live sideband AND a sticky revocation, exactly as in the AI adapter.
    assign proposal_commit_allowed=!rst && proposal_valid && !revoked && !invalidated &&
        fresh && proposal_context==current_context && proposal_safety_epoch==safety_epoch;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;frozen_size<=BOARD_SIZE;active_context<=0;active_epoch<=0;revoked<=0;issued<=0;
            have_frame<=0;have_candidate<=0;last_frame<=0;last_capture<=0;first_capture<=0;
            frame<=0;capture_time<=0;frozen_cells<=0;frozen_board<=0;frozen_observable<=0;
            frozen_confidence<=0;frozen_next<=0;index<=0;change_index<=0;candidate_index<=0;
            change_color<=0;candidate_color<=0;changes<=0;bad_cell<=0;old_changed<=0;
            proposal_valid<=0;proposal_context<=0;proposal_safety_epoch<=0;
            proposal_frame_id<=0;proposal_capture_us<=0;proposal_row<=255;proposal_col<=255;
            proposal_color<=0;reason<=WAITING;stable_count<=0;
        end else begin
            if(identity_changed) begin
                active_context<=current_context;active_epoch<=safety_epoch;
                // Frame high-water resets only on a different session, never
                // on calibration, board version, cancellation or hand motion.
                if(active_context[63:0]!=current_context[63:0]) begin
                    have_frame<=0;last_frame<=0;last_capture<=0;
                end
                if(active_context!=current_context) issued<=0;
            end
            if(state==PUBLISH) begin
                if(invalidated || !fresh) revoked<=1;
                if(proposal_ready) begin
                    proposal_valid<=0;state<=IDLE;issued<=proposal_commit_allowed;
                end
                if(invalidated || !fresh) begin have_candidate<=0;stable_count<=0;reason<=BLOCKED;end
            end else if(invalidated) begin
                state<=IDLE;have_candidate<=0;stable_count<=0;reason<=BLOCKED;
            end else case(state)
                IDLE: if(obs_valid && obs_ready) begin
                    if(obs_context!=current_context || obs_safety_epoch!=safety_epoch ||
                       !incoming_id_good) begin
                        reason<=STALE;have_candidate<=0;stable_count<=0;
                    end else if(have_frame && (obs_frame_id<=last_frame || obs_capture_us<=last_capture)) begin
                        reason<=DUPLICATE;have_candidate<=0;stable_count<=0;
                    end else begin
                        // Consume an authenticated fresh ID even for bad images.
                        have_frame<=1;last_frame<=obs_frame_id;
                        if(!incoming_fresh || !obs_frame_complete || !obs_board_observable ||
                           obs_quality_flags!=0 || obs_board_size!=active_size || obs_cell_count!=active_count) begin
                            last_capture<=obs_capture_us;reason<=BAD_FRAME;
                            have_candidate<=0;stable_count<=0;
                        end else begin
                            frame<=obs_frame_id;capture_time<=obs_capture_us;
                            frozen_cells<=obs_cells;frozen_board<=confirmed_cells;
                            frozen_observable<=obs_observable;frozen_confidence<=obs_confidence;
                            frozen_next<=next_color;frozen_size<=active_size;index<=0;changes<=0;
                            bad_cell<=0;old_changed<=0;state<=SCAN;
                        end
                    end
                end
                SCAN: begin
                    if(active_cell && (observed==3 || official==3 || !frozen_observable[index] ||
                       frozen_confidence[index*8+:8]<MIN_CONFIDENCE)) bad_cell<=1;
                    if(!active_cell && (observed!=0 || official!=0)) bad_cell<=1;
                    if(active_cell && official!=0 && observed!=official) old_changed<=1;
                    if(active_cell && observed!=official) begin
                        changes<=changes+1'b1;change_index<=index;change_color<=observed;
                    end
                    if(index==CELLS-1) state<=DECIDE;else index<=index+1'b1;
                end
                DECIDE: begin
                    last_capture<=capture_time;state<=IDLE;
                    if(!fresh || bad_cell || old_changed || changes!=1 || change_color!=frozen_next) begin
                        have_candidate<=0;stable_count<=0;
                        if(!fresh)reason<=STALE;
                        else if(bad_cell)reason<=BAD_CELL;
                        else if(old_changed)reason<=OLD_CHANGED;
                        else if(changes==0)reason<=NO_CHANGE;
                        else if(changes!=1)reason<=MULTIPLE;
                        else reason<=WRONG_COLOR;
                    end else if(current_context[191:160]==32'hfffffffe) begin
                        have_candidate<=0;stable_count<=0;reason<=EXHAUSTED;
                    end else if(!same_candidate) begin
                        have_candidate<=1;candidate_index<=change_index;candidate_color<=change_color;
                        first_capture<=capture_time;stable_count<=1;reason<=CANDIDATE;
                    end else begin
                        if(stable_count!=65535)stable_count<=stable_count+1'b1;
                        reason<=CANDIDATE;
                        if(stable_count>=MIN_FRAMES-1 && capture_time-first_capture>=STABLE_US) begin
                            proposal_valid<=1;proposal_context<=active_context;
                            proposal_safety_epoch<=active_epoch;proposal_frame_id<=frame;
                            proposal_capture_us<=capture_time;proposal_row<=change_index/BOARD_SIZE;
                            proposal_col<=change_index%BOARD_SIZE;proposal_color<=change_color;
                            reason<=ACCEPTED;revoked<=0;state<=PUBLISH;
                            have_candidate<=0;
                        end
                    end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
