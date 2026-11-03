`timescale 1ns/1ps
`default_nettype none
// Camera observations propose moves; only the rules engine owns the board.
// An AI result is a placement request, never an automatic rules submission.
// Observation context, safety epoch and timestamp MUST be captured with pixels.
module qy_human_ai_game #(
    parameter MIN_FRAMES=3, parameter DYNAMIC_SIZE=0, parameter ORIGIN_OPENING=0,
    parameter [63:0] STABLE_US=250000,
    parameter SEARCH_DEPTH=3, SEARCH_NODES=20000,
    parameter MAX_AI_CYCLES=800000000
)(
    input wire clk,rst_n,
    input wire new_game_request, human_white, paused,
    input wire anchor_seed_valid,
    input wire [7:0] anchor_seed_index,
    input wire calibrated,safety_clear,
    input wire [3:0] board_size_i,
    input wire [31:0] calibration_version,safety_epoch,
    input wire [63:0] now_us,
    input wire obs_valid, output wire obs_ready,
    input wire [191:0] obs_context,
    input wire [31:0] obs_safety_epoch,
    input wire [63:0] obs_frame,obs_capture_us,
    input wire obs_complete,obs_board_observable,
    input wire [15:0] obs_quality,
    input wire [337:0] obs_cells,
    input wire [168:0] obs_observable,
    input wire [1351:0] obs_confidence,
    output wire [191:0] context_o,
    output wire [337:0] board_o,
    output wire [7:0] last_index_o,move_count_o,
    output wire last_valid_o,game_over_o,draw_o,
    output wire [1:0] next_color_o,winner_o,
    output reg [1:0] human_color_o,
    output reg origin_pending,origin_valid,
    output reg [7:0] origin_index,
    output reg [3:0] formal_board_size,
    output reg ai_target_valid,
    output reg [7:0] ai_target_index,
    output reg [1:0] ai_target_reason,
    output reg [3:0] phase,
    output wire [7:0] observation_reason,
    output reg fault,
    output reg event_valid,event_is_ai,
    output reg [7:0] event_index,
    output reg [1:0] event_color,
    output wire [31:0] state_version_o
);
    localparam CLEAR_BOARD=0,RESET_RULES=1,SELECT_TURN=2,HUMAN_TURN=3,
        AI_START=4,AI_SEARCH=5,AI_PLACE=6,WAIT_ACCEPT=7,WAIT_RULES=8,ENDED=9,FAULT=10,
        ORIGIN_CONFIRM=11;
    reg [63:0] session_id;
    wire [3:0] board_size=DYNAMIC_SIZE?board_size_i:4'd13;
    wire [15:0] active_count=board_size*board_size;
    reg rules_new,move_valid,ai_start,ai_cancel;
    reg [3:0] move_row,move_col;
    reg [1:0] move_color;
    reg move_is_ai,move_is_origin;
    reg [31:0] age,search_version;
    reg pending_white;
    reg origin_mode,seed_valid,seed_revoked;
    reg [3:0] seed_board_size;
    reg [3:0] reset_board_size;
    reg [31:0] seed_calibration;
    // The first calibration proposes an identity; only a new-game request can
    // bind it. Later input changes never retarget a pending or committed origin.
    wire seed_bound=seed_valid&&!seed_revoked&&origin_index<169&&
        seed_board_size>=5&&seed_board_size<=13&&
        origin_index/13<seed_board_size&&origin_index%13<seed_board_size&&
        seed_board_size==board_size&&seed_calibration==calibration_version&&
        seed_calibration!=0&&seed_calibration!=32'hffffffff;
    wire origin_permission=!origin_pending||seed_bound;
    reg [337:0] expected_origin_board;
    always @* begin
        expected_origin_board=0;
        if(origin_index<169)expected_origin_board[origin_index*2+:2]=2'd1;
    end
    wire [449:0] full_board;
    wire [7:0] full_last_index;
    wire rules_ready,accepted,rejected;
    wire reset_commit;
    wire proposal_valid,proposal_allowed,guard_ready,guard_busy;
    wire ai_busy,ai_done,ai_valid;
    wire [3:0] ai_row,ai_col;
    wire [31:0] ai_version,ai_score,ai_nodes;
    wire [1:0] ai_reason;
    wire [2:0] ai_depth;
    wire ai_budget,ai_fallback;
    wire [1:0] ai_color=human_color_o==1?2'd2:2'd1;
    assign context_o={state_version_o,calibration_version,{60'd0,board_size},session_id};
    assign last_index_o=(full_last_index/15)*13+full_last_index%15;
    genvar r,c;
    generate for(r=0;r<13;r=r+1)begin:rows
        for(c=0;c<13;c=c+1)begin:cols
            assign board_o[(r*13+c)*2+:2]=full_board[(r*15+c)*2+:2];
        end
    end endgenerate
    qy_gomoku_rules #(.BOARD_SIZE(13),.DYNAMIC_SIZE(DYNAMIC_SIZE)) rules(
        .clk_i(clk),.rst_n_i(rst_n),.new_game_i(reset_commit),.board_size_i(reset_commit?reset_board_size:board_size),
        .move_valid_i(move_valid&&proposal_allowed&&!new_game_request),.move_row_i(move_row),.move_col_i(move_col),.move_color_i(move_color),
        .move_ready_o(rules_ready),.accepted_o(accepted),.rejected_o(rejected),.board_o(full_board),
        .next_color_o(next_color_o),.winner_o(winner_o),.game_over_o(game_over_o),.draw_o(draw_o),
        .move_count_o(move_count_o),.last_index_o(full_last_index),.last_valid_o(last_valid_o),.state_version_o(state_version_o));
    qy_gomoku_search #(.BOARD_SIZE(13),.DYNAMIC_SIZE(DYNAMIC_SIZE),.MAX_DEPTH(SEARCH_DEPTH),.NODE_BUDGET(SEARCH_NODES)) ai(
        .clk_i(clk),.rst_n_i(rst_n),.start_i(ai_start),.cancel_i(ai_cancel),
        .board_i(full_board),.board_size_i(board_size),.color_i(ai_color),.state_version_i(state_version_o),
        .busy_o(ai_busy),.done_o(ai_done),.result_valid_o(ai_valid),
        .row_o(ai_row),.col_o(ai_col),.score_o(ai_score),.result_version_o(ai_version),.reason_o(ai_reason),
        .completed_depth_o(ai_depth),.nodes_o(ai_nodes),.budget_exhausted_o(ai_budget),.fallback_used_o(ai_fallback));

    wire playing=(phase==HUMAN_TURN||phase==AI_PLACE||phase==ORIGIN_CONFIRM||phase==WAIT_ACCEPT)&&
        !fault&&origin_permission;
    wire [191:0] proposal_context;
    wire [31:0] proposal_epoch;
    wire [63:0] proposal_frame,proposal_time;
    wire [7:0] proposal_row,proposal_col,guard_reason;
    wire [1:0] proposal_color;
    wire [15:0] stable_count;
    reg [337:0] expected_ai_board;
    always @* begin
        expected_ai_board=board_o;
        if(ai_target_valid&&ai_target_index<169)
            expected_ai_board[ai_target_index*2+:2]=ai_color;
    end
    // Reject a misplaced AI stone at observation ingress. The guard cannot
    // consume its one-shot proposal until an exact target board is observed.
    wire wrong_ai_board=phase==AI_PLACE && obs_cells!=board_o && obs_cells!=expected_ai_board;
    // A wrong seed must never leave a valid one-shot proposal waiting forever
    // in PUBLISH. Reject it before the unchanged guard observes the frame.
    wire wrong_origin_board=origin_pending&&
        (phase==CLEAR_BOARD||phase==ORIGIN_CONFIRM)&&obs_cells!=expected_origin_board;
    wire opening_guard_bad=phase==ORIGIN_CONFIRM&&wrong_origin_board;
    assign observation_reason=origin_pending&&!seed_bound?8'd34:
        wrong_origin_board?8'd33:wrong_ai_board?8'd32:guard_reason;
    // The producer holds the queued observation while ready is low. Register
    // the large board/confidence reductions first; current context, safety,
    // age and final reset authority are still checked on the consuming edge.
    reg opening_evaluated,opening_matches_q,empty_confident_q;
    assign obs_ready=phase==CLEAR_BOARD?opening_evaluated:guard_ready;
    qy_observation_guard #(.BOARD_SIZE(13),.DYNAMIC_SIZE(DYNAMIC_SIZE),.MIN_FRAMES(MIN_FRAMES),.STABLE_US(STABLE_US)) guard(
        .clk(clk),.rst(!rst_n),.cancel(new_game_request),
        .board_size_i(board_size),.session_ready(playing&&rules_ready&&!paused),.calibrated(calibrated),.safety_clear(safety_clear),
        .current_context(context_o),.safety_epoch(safety_epoch),.now_us(now_us),
        .confirmed_cells(board_o),.next_color(next_color_o),.terminal(game_over_o),
        .obs_valid(obs_valid&&playing),.obs_ready(guard_ready),.obs_context(obs_context),
        .obs_safety_epoch(obs_safety_epoch),.obs_frame_id(obs_frame),.obs_capture_us(obs_capture_us),
        .obs_board_size(board_size),.obs_cell_count(active_count),
        .obs_quality_flags(obs_quality|{9'd0,(wrong_ai_board||opening_guard_bad),6'd0}),
        .obs_frame_complete(obs_complete),.obs_board_observable(obs_board_observable),
        .obs_cells(obs_cells),.obs_observable(obs_observable),.obs_confidence(obs_confidence),
        .proposal_valid(proposal_valid),
        // Drain only consumed or already-revoked proposals. Revocation still
        // gates the rules write port through proposal_allowed above.
        .proposal_ready(new_game_request||(proposal_valid&&!proposal_allowed)||
            (phase==WAIT_ACCEPT&&(accepted||rejected))),
        .proposal_commit_allowed(proposal_allowed),
        .proposal_context(proposal_context),.proposal_safety_epoch(proposal_epoch),
        .proposal_frame_id(proposal_frame),.proposal_capture_us(proposal_time),
        .proposal_row(proposal_row),.proposal_col(proposal_col),.proposal_color(proposal_color),
        .reason(guard_reason),.busy(guard_busy),.stable_count(stable_count));

    reg [15:0] empty_count;
    reg [63:0] empty_first,empty_last,empty_frame;
    reg [31:0] empty_calibration,empty_epoch;
    reg have_empty_frame;
    reg empty_confident;
    integer ec;
    always @* begin
        empty_confident=1;
        for(ec=0;ec<169;ec=ec+1)
            if(ec/13<board_size&&ec%13<board_size)begin
                if(obs_confidence[ec*8+:8]<160||!obs_observable[ec])empty_confident=0;
            end
    end
    wire opening_matches=origin_mode?
        (origin_pending&&seed_bound&&obs_cells==expected_origin_board):obs_cells==0;
    always @(posedge clk)begin
        if(!rst_n||new_game_request||phase!=CLEAR_BOARD)begin
            opening_evaluated<=0;opening_matches_q<=0;empty_confident_q<=0;
        end else if(!obs_valid)opening_evaluated<=0;
        else if(!opening_evaluated)begin
            opening_matches_q<=opening_matches;empty_confident_q<=empty_confident;opening_evaluated<=1;
        end else opening_evaluated<=0;
    end
    wire empty_good=calibrated&&safety_clear&&!paused&&obs_complete&&obs_board_observable&&
        board_size>=5&&board_size<=13&&obs_quality==0&&opening_matches_q&&empty_confident_q&&
        obs_context==context_o&&obs_safety_epoch==safety_epoch&&
        obs_frame!=0&&obs_frame!=64'hffffffffffffffff&&now_us>=obs_capture_us&&
        now_us-obs_capture_us<=500000&&(!have_empty_frame||(obs_frame>empty_frame&&obs_capture_us>empty_last));
    wire empty_continues=empty_count!=0&&obs_capture_us>=empty_last&&obs_capture_us-empty_last<=250000&&
        empty_calibration==calibration_version&&empty_epoch==safety_epoch;
    // A complete opening certificate is a pending request for one clock. Its
    // authority must still hold on the edge that actually clears the board.
    assign reset_commit=rules_new&&!new_game_request&&calibrated&&safety_clear&&!paused&&
        origin_permission&&board_size==reset_board_size&&
        calibration_version==empty_calibration&&safety_epoch==empty_epoch&&
        now_us!=64'hffffffffffffffff&&now_us>=empty_last&&now_us-empty_last<=500000;
    always @(posedge clk)begin
        if(!rst_n)begin
            phase<=CLEAR_BOARD;session_id<=1;rules_new<=0;move_valid<=0;ai_start<=0;ai_cancel<=0;
            human_color_o<=1;pending_white<=0;move_row<=0;move_col<=0;move_color<=0;move_is_ai<=0;move_is_origin<=0;
            origin_mode<=0;origin_pending<=0;origin_valid<=0;origin_index<=8'hff;
            seed_valid<=0;seed_revoked<=0;seed_board_size<=13;seed_calibration<=0;reset_board_size<=13;formal_board_size<=13;
            age<=0;search_version<=0;ai_target_valid<=0;ai_target_index<=0;ai_target_reason<=0;fault<=0;
            event_valid<=0;event_is_ai<=0;event_index<=0;event_color<=0;
            empty_count<=0;empty_first<=0;empty_last<=0;empty_frame<=0;empty_calibration<=0;empty_epoch<=0;have_empty_frame<=0;
        end else begin
            rules_new<=0;move_valid<=0;ai_start<=0;ai_cancel<=0;event_valid<=0;
            // Session, human ownership and formal N become visible together
            // with the rules reset; a revoked certificate changes none of them.
            if(reset_commit)begin
                formal_board_size<=reset_board_size;session_id<=session_id+1'b1;
                human_color_o<=pending_white?2'd2:2'd1;
            end
            if(origin_pending&&(seed_board_size!=board_size||seed_calibration!=calibration_version))
                seed_revoked<=1;
            if(accepted)begin
                event_valid<=1;event_is_ai<=move_is_ai;event_index<=move_row*13+move_col;event_color<=move_color;
            end
            if(phase==AI_SEARCH||phase==WAIT_ACCEPT||phase==WAIT_RULES)age<=age+1'b1;else age<=0;
            if(new_game_request)begin
                pending_white<=human_white;phase<=CLEAR_BOARD;ai_cancel<=1;ai_target_valid<=0;
                origin_mode<=ORIGIN_OPENING&&!human_white;
                origin_pending<=ORIGIN_OPENING&&!human_white;origin_valid<=0;
                origin_index<=ORIGIN_OPENING&&!human_white?anchor_seed_index:8'hff;
                seed_valid<=anchor_seed_valid;seed_revoked<=0;seed_board_size<=board_size;seed_calibration<=calibration_version;
                move_is_origin<=0;
                empty_count<=0;fault<=0;
            end else case(phase)
                CLEAR_BOARD:begin
                    ai_target_valid<=0;
                    if(!calibrated||!safety_clear||paused||!origin_permission)empty_count<=0;
                    if(obs_valid&&obs_ready)begin
                        if(!empty_good)empty_count<=0;
                        else begin
                            have_empty_frame<=1;empty_frame<=obs_frame;empty_last<=obs_capture_us;
                            empty_calibration<=calibration_version;empty_epoch<=safety_epoch;
                            if(!empty_continues)begin empty_count<=1;empty_first<=obs_capture_us;end
                            else if(empty_count>=MIN_FRAMES-1 && obs_capture_us-empty_first>=STABLE_US)begin
                                // The previous official board survives until
                                // this complete, stable opening certificate.
                                rules_new<=1;reset_board_size<=board_size;
                                phase<=RESET_RULES;empty_count<=0;
                            end else empty_count<=empty_count+1'b1;
                        end
                    end
                end
                RESET_RULES:phase<=reset_commit?SELECT_TURN:CLEAR_BOARD;
                SELECT_TURN:if(rules_ready)begin
                    if(origin_pending)phase<=ORIGIN_CONFIRM;
                    else if(game_over_o)phase<=ENDED;
                    else if(next_color_o==human_color_o)phase<=HUMAN_TURN;
                    else phase<=AI_START;
                end
                AI_START:if(!ai_busy&&!paused&&calibrated&&safety_clear)begin
                    search_version<=state_version_o;ai_start<=1;phase<=AI_SEARCH;
                end
                AI_SEARCH:if(ai_done)begin
                    if(ai_valid&&ai_version==search_version&&state_version_o==search_version&&
                       ai_row<board_size&&ai_col<board_size&&board_o[(ai_row*13+ai_col)*2+:2]==0)begin
                        ai_target_index<=ai_row*13+ai_col;ai_target_reason<=ai_reason;
                        ai_target_valid<=1;phase<=AI_PLACE;
                    end else begin fault<=1;phase<=FAULT;end
                end
                HUMAN_TURN,AI_PLACE,ORIGIN_CONFIRM:if(proposal_valid&&proposal_allowed&&!paused&&calibrated&&safety_clear)begin
                    if(proposal_context==context_o&&proposal_epoch==safety_epoch&&
                       proposal_color==next_color_o&&
                       (phase==HUMAN_TURN||
                        (phase==AI_PLACE&&ai_target_valid&&proposal_row*13+proposal_col==ai_target_index)||
                        (phase==ORIGIN_CONFIRM&&origin_pending&&seed_bound&&proposal_color==1&&
                         proposal_row*13+proposal_col==origin_index)))begin
                        move_row<=proposal_row[3:0];move_col<=proposal_col[3:0];move_color<=proposal_color;
                        move_is_ai<=phase==AI_PLACE;move_is_origin<=phase==ORIGIN_CONFIRM;
                        move_valid<=1;phase<=WAIT_ACCEPT;
                    end
                end
                WAIT_ACCEPT:if(accepted)begin
                    if(move_is_origin)begin origin_valid<=1;origin_pending<=0;end
                    ai_target_valid<=0;phase<=WAIT_RULES;
                end else if(rejected)begin fault<=1;phase<=FAULT;end
                else if(!proposal_allowed)phase<=SELECT_TURN;
                WAIT_RULES:if(rules_ready)phase<=SELECT_TURN;
                ENDED:ai_target_valid<=0;
                FAULT:begin ai_target_valid<=0;ai_cancel<=1;end
                default:begin fault<=1;phase<=FAULT;end
            endcase
            if(!new_game_request && ((phase==AI_SEARCH&&age>=MAX_AI_CYCLES)||
                ((phase==WAIT_ACCEPT||phase==WAIT_RULES)&&age>=2000000)))begin
                phase<=FAULT;fault<=1;ai_cancel<=1;ai_target_valid<=0;
            end
        end
    end
endmodule
`default_nettype wire
