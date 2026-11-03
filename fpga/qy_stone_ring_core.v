`timescale 1ns/1ps
`default_nettype none
// Integer, image-only radial detector. A complete 320x180 input stays frozen
// from start through done. All RAM reads are synchronous. No game-state writes.
module qy_stone_ring_core #(
    parameter OFFSET_FILE="stone_ring_offsets.hex"
)(
    input wire clk,rst_n,start,
    output reg busy,done,overflow,
    output reg [15:0] raw_address,
    input wire [8:0] raw_data,
    output reg [1023:0] boxes,
    output reg [5:0] box_count,
    output reg [31:0] cycles
);
    localparam IDLE=0,B_ADDR=1,B_WAIT=2,B_USE=3,B_WRITE=4,B_NEXT=5,
        R_INIT=6,R_RUN=7,R_CLASS=8,R_DECIDE=9,NMS=10,R_NEXT=11,
        PACK=12,FINISH=13,PRUNE_INIT=14,PRUNE_CHECK=15;
    reg [3:0] state;
    (* ram_style="bram" *) reg [8:0] smooth[0:65535];
    (* keep="true" *) reg [15:0] smooth_read_address,smooth_write_address;
    reg [8:0] smooth_read_data,smooth_write_data;
    reg smooth_write;
    (* ram_style="bram" *) reg [15:0] offsets[0:511];
    (* keep="true" *) reg [8:0] offset_address;
    reg [15:0] offset_data;
    initial $readmemh(OFFSET_FILE,offsets);
    always @(posedge clk) begin
        if(smooth_write)smooth[smooth_write_address]<=smooth_write_data;
        smooth_read_data<=smooth[smooth_read_address];
        offset_data<=offsets[offset_address];
    end

    reg [8:0] bx,cx;
    reg [7:0] by,cy;
    reg [15:0] bcenter,center;
    reg [3:0] bphase,radius;
    reg [11:0] bsum;
    reg bpaper;
    reg [8:0] radius_base;
    reg [6:0] issued;
    reg [2:0] issue_phase,p0,p1,p2,p3;
    reg v0,v1,v2,v3,l0,l1,l2,l3;
    reg [7:0] edge_min,outside;
    reg outside_paper;
    reg [4:0] edge_votes,white_votes,paper_votes;
    reg [10:0] score;
    reg [4:0] bright_votes,inner_paper_votes;
    reg [10:0] bright_score;
    reg bright_good,probe_pass;
    reg [5:0] packed_count;
    reg [11:0] inner_sum,outer_sum;
    reg common_good,black_good,white_good;
    reg [1:0] candidate_color;
    reg [5:0] nms_index,pack_index,count;
    reg [8:0] found_x[0:31];
    reg [7:0] found_y[0:31];
    reg [3:0] found_r[0:31];
    reg [10:0] found_score[0:31];
    reg [1:0] found_color[0:31];
    wire [8:0] contrast={1'b0,outside}-{1'b0,edge_min};
    wire edge_good=outside>=edge_min && contrast>=9;
    wire white_edge=smooth_read_data[7:0]>=edge_min &&
        ({1'b0,smooth_read_data[7:0]}-{1'b0,edge_min})>=4 && edge_good;
    wire [6:0] clipped=outside<edge_min?7'd0:contrast>64?7'd64:contrast[6:0];
    wire [8:0] bright_contrast={1'b0,smooth_read_data[7:0]}-{1'b0,outside};
    wire bright_edge=smooth_read_data[7:0]>=outside && bright_contrast>=20;
    wire [6:0] bright_clipped=smooth_read_data[7:0]<outside?7'd0:bright_contrast>64?7'd64:bright_contrast[6:0];
    wire [8:0] nx=found_x[nms_index[4:0]];
    wire [7:0] ny=found_y[nms_index[4:0]];
    wire [3:0] nr=found_r[nms_index[4:0]];
    wire [8:0] dx=cx>=nx?cx-nx:nx-cx;
    wire [7:0] dy=cy>=ny?cy-ny:ny-cy;
    wire [4:0] merge_radius=(radius>nr?{1'b0,radius}:{1'b0,nr})+5'd3;
    // Constant products are evaluated in their complete unsigned widths.
    wire [18:0] inner100={7'd0,inner_sum}*19'd100;
    wire [18:0] outer40={7'd0,outer_sum}*19'd40;
    wire [18:0] outer55={7'd0,outer_sum}*19'd55;
    wire [18:0] outer85={7'd0,outer_sum}*19'd85;
    wire [16:0] inner20={5'd0,inner_sum}*17'd20;
    wire [16:0] outer19={5'd0,outer_sum}*17'd19;
    wire [15:0] bleft=bx==0?bcenter:bcenter-16'd1;
    wire [15:0] bright=bx==319?bcenter:bcenter+16'd1;
    wire [15:0] bup=by==0?16'd0:16'd320;
    wire [15:0] bdown=by==179?16'd0:16'd320;
    // floor(n/9), exact for every possible 9-pixel u8 sum (0..2295).
    wire [27:0] blur_product={16'd0,bsum}*28'd7282;
    integer k;
    always @(posedge clk) begin
        if(!rst_n)begin
            state<=IDLE;busy<=0;done<=0;overflow<=0;raw_address<=0;
            boxes<=0;box_count<=0;cycles<=0;
            smooth_read_address<=0;smooth_write_address<=0;smooth_write_data<=0;smooth_write<=0;
            offset_address<=0;bx<=0;by<=0;bcenter<=0;bphase<=0;bsum<=0;bpaper<=0;
            cx<=0;cy<=0;center<=0;radius<=6;radius_base<=0;issued<=0;issue_phase<=0;
            v0<=0;v1<=0;v2<=0;v3<=0;l0<=0;l1<=0;l2<=0;l3<=0;p0<=0;p1<=0;p2<=0;p3<=0;
            edge_min<=0;outside<=0;outside_paper<=0;edge_votes<=0;white_votes<=0;paper_votes<=0;
            score<=0;inner_sum<=0;outer_sum<=0;common_good<=0;black_good<=0;white_good<=0;
            candidate_color<=0;nms_index<=0;pack_index<=0;count<=0;
            bright_votes<=0;inner_paper_votes<=0;bright_score<=0;bright_good<=0;probe_pass<=0;packed_count<=0;
        end else begin
            done<=0;smooth_write<=0;
            if(busy)cycles<=cycles+1'b1;
            v0<=0;v1<=v0;v2<=v1;v3<=v2;
            p1<=p0;p2<=p1;p3<=p2;l1<=l0;l2<=l1;l3<=l2;
            if(v1)smooth_read_address<=center+offset_data;
            case(state)
                IDLE:if(start)begin
                    busy<=1;overflow<=0;cycles<=0;count<=0;boxes<=0;box_count<=0;
                    bx<=0;by<=0;bcenter<=0;bphase<=0;bsum<=0;state<=B_ADDR;
                end
                B_ADDR:begin
                    case(bphase)
                        0:raw_address<=bleft-bup;
                        1:raw_address<=bcenter-bup;
                        2:raw_address<=bright-bup;
                        3:raw_address<=bleft;
                        4:raw_address<=bcenter;
                        5:raw_address<=bright;
                        6:raw_address<=bleft+bdown;
                        7:raw_address<=bcenter+bdown;
                        default:raw_address<=bright+bdown;
                    endcase
                    state<=B_WAIT;
                end
                B_WAIT:state<=B_USE;
                B_USE:begin
                    bsum<=bsum+{4'd0,raw_data[7:0]};
                    if(bphase==4)bpaper<=raw_data[8];
                    if(bphase==8)state<=B_WRITE;
                    else begin bphase<=bphase+1'b1;state<=B_ADDR;end
                end
                B_WRITE:begin
                    smooth_write<=1;smooth_write_address<=bcenter;
                    smooth_write_data<={bpaper,blur_product[23:16]};state<=B_NEXT;
                end
                B_NEXT:begin
                    bphase<=0;bsum<=0;
                    if(bcenter==57599)begin
                        radius<=6;radius_base<=0;cx<=9;cy<=9;center<=16'd2889;state<=R_INIT;
                    end else begin
                        bcenter<=bcenter+1'b1;
                        if(bx==319)begin bx<=0;by<=by+1'b1;end else bx<=bx+1'b1;
                        state<=B_ADDR;
                    end
                end
                R_INIT:begin
                    issued<=0;issue_phase<=0;edge_votes<=0;white_votes<=0;paper_votes<=0;
                    bright_votes<=0;inner_paper_votes<=0;bright_score<=0;probe_pass<=0;
                    score<=0;inner_sum<=0;outer_sum<=0;state<=R_RUN;
                end
                R_RUN:begin
                    // Four directions are an exact rejection bound: with no
                    // dark-edge votes at most12 of16 can pass (need13); with
                    // fewer than3 bright votes at most14 can pass (need15).
                    // Pause the issue pipeline after20 reads until that test.
                    if(issued<20 || (issued<80 && probe_pass))begin
                        offset_address<=radius_base+issued;issued<=issued+1'b1;
                        p0<=issue_phase;issue_phase<=issue_phase==4?0:issue_phase+1'b1;
                        l0<=issued==79;v0<=1;
                    end
                    if(v3)begin
                        case(p3)
                            0:edge_min<=smooth_read_data[7:0];
                            1,2:if(smooth_read_data[7:0]<edge_min)edge_min<=smooth_read_data[7:0];
                            3:begin outside<=smooth_read_data[7:0];outside_paper<=smooth_read_data[8];end
                            4:begin
                                edge_votes<=edge_votes+edge_good;white_votes<=white_votes+white_edge;
                                paper_votes<=paper_votes+outside_paper;score<=score+clipped;
                                inner_sum<=inner_sum+{4'd0,smooth_read_data[7:0]};
                                outer_sum<=outer_sum+{4'd0,outside};
                                bright_votes<=bright_votes+bright_edge;
                                bright_score<=bright_score+bright_clipped;
                                inner_paper_votes<=inner_paper_votes+smooth_read_data[8];
                                if(issued==20)begin
                                    if(edge_votes!=0 || edge_good || bright_votes>=3 || (bright_votes==2 && bright_edge))probe_pass<=1;
                                    else state<=R_NEXT;
                                end
                            end
                        endcase
                        if(l3)state<=R_CLASS;
                    end
                end
                R_CLASS:begin
                    common_good<=edge_votes>=13 && score>=180 && outer_sum>=1040 && paper_votes>=10;
                    black_good<=inner100<outer40 && score>=300;
                    white_good<=inner100>=outer55 && inner20<=outer19 && white_votes>=3 &&
                        (white_votes>=4 || inner100>=outer85) &&
                        (white_votes>=8 || (edge_votes>=13 && score>=320)) && inner_paper_votes>=15;
                    bright_good<=bright_votes>=15 && bright_score>=450 && inner_sum>=1440 && inner_paper_votes>=14;
                    state<=R_DECIDE;
                end
                R_DECIDE:begin
                    if((common_good && (black_good||white_good)) || bright_good)begin
                        candidate_color<=bright_good?2'd2:black_good?2'd1:2'd2;
                        if(bright_good)score<=bright_score;
                        nms_index<=0;state<=NMS;
                    end else state<=R_NEXT;
                end
                NMS:begin
                    if(nms_index<count)begin
                        if(dx<=merge_radius && dy<=merge_radius)begin
                            if(score>found_score[nms_index[4:0]])begin
                                found_x[nms_index[4:0]]<=cx;found_y[nms_index[4:0]]<=cy;
                                found_r[nms_index[4:0]]<=radius;found_color[nms_index[4:0]]<=candidate_color;
                                found_score[nms_index[4:0]]<=score;
                            end
                            state<=R_NEXT;
                        end else nms_index<=nms_index+1'b1;
                    end else begin
                        if(count<32)begin
                            found_x[count[4:0]]<=cx;found_y[count[4:0]]<=cy;found_r[count[4:0]]<=radius;
                            found_score[count[4:0]]<=score;found_color[count[4:0]]<=candidate_color;count<=count+1'b1;
                        end else overflow<=1;
                        state<=R_NEXT;
                    end
                end
                R_NEXT:begin
                    if(cx<316-radius)begin cx<=cx+1'b1;center<=center+1'b1;state<=R_INIT;end
                    else if(cy<176-radius)begin
                        cx<=radius+3;cy<=cy+1'b1;center<=center+{11'd0,radius,1'b0}+16'd7;state<=R_INIT;
                    end else if(radius<11)begin
                        radius<=radius+1'b1;radius_base<=radius_base+9'd80;
                        cx<=radius+4;cy<=radius+4;
                        center<=({12'd0,radius}+16'd4)*16'd321;state<=R_INIT;
                    end else begin pack_index<=0;state<=PRUNE_INIT;end
                end
                // Online updates may move two earlier clusters into overlap.
                // Remove those duplicates by score before publishing boxes.
                PRUNE_INIT:begin
                    if(pack_index<count)begin
                        cx<=found_x[pack_index[4:0]];cy<=found_y[pack_index[4:0]];
                        radius<=found_r[pack_index[4:0]];score<=found_score[pack_index[4:0]];
                        candidate_color<=found_color[pack_index[4:0]];
                        nms_index<=pack_index+1'b1;state<=PRUNE_CHECK;
                    end else begin pack_index<=0;packed_count<=0;state<=PACK;end
                end
                PRUNE_CHECK:begin
                    if(candidate_color!=0 && nms_index<count)begin
                        if(found_color[nms_index[4:0]]!=0 && dx<=merge_radius && dy<=merge_radius)begin
                            if(score>=found_score[nms_index[4:0]])found_color[nms_index[4:0]]<=0;
                            else begin found_color[pack_index[4:0]]<=0;candidate_color<=0;end
                        end
                        nms_index<=nms_index+1'b1;
                    end else begin pack_index<=pack_index+1'b1;state<=PRUNE_INIT;end
                end
                PACK:begin
                    if(pack_index<count && !overflow && found_color[pack_index[4:0]]!=0)begin
                        boxes[packed_count*32+:32]<={8'd0,1'b1,found_color[pack_index[4:0]],
                            found_r[pack_index[4:0]],found_y[pack_index[4:0]],found_x[pack_index[4:0]]};
                        packed_count<=packed_count+1'b1;
                    end
                    if(pack_index==31)state<=FINISH;
                    else pack_index<=pack_index+1'b1;
                end
                FINISH:begin box_count<=overflow?0:packed_count;done<=1;busy<=0;state<=IDLE;end
                default:begin busy<=0;state<=IDLE;overflow<=1;end
            endcase
        end
    end
endmodule
`default_nettype wire
