// Generated compatible extension; original module preserved.
// Development-only, coherent RGB888 snapshot exporter.  All ports use clk.
// Existing ui_dbuf logical slots and ui_FDMA protocols remain unchanged.
module qy_capture_lease_memory #(
    parameter integer WIDTH=1920, HEIGHT=1080,
    parameter integer ADDR_WIDTH=32,
    parameter integer WAIT_CYCLES=233000000,
    parameter integer READ_WAIT_CYCLES=65536
)(
    input wire clk, input wire rst_n,
    input wire req_valid, output wire req_ready, input wire [63:0] req_nonce,
    input wire req_export, output wire [31:0] begin_frame_base,
    output reg [31:0] perf_capture_start,perf_capture_end,perf_capture_ready,
    output wire begin_valid, input wire begin_ready,
    output wire [63:0] begin_nonce, output wire [31:0] begin_frame_id,
    output wire [7:0] begin_status,
    output wire rgb_byte_valid, input wire rgb_byte_ready,
    output wire [7:0] rgb_byte,
    output reg frame_error, input wire packet_done,
    input wire [ADDR_WIDTH-1:0] dbuf_waddr,
    input wire dbuf_wreq, input wire [15:0] dbuf_wsize,
    input wire fdma_wbusy, input wire fdma_wvalid,
    output wire [ADDR_WIDTH-1:0] mapped_waddr,
    input wire axi_aw_fire, input wire axi_b_fire, input wire axi_b_error,
    input wire [ADDR_WIDTH-1:0] dbuf_raddr,
    input wire dbuf_rreq, input wire [15:0] dbuf_rsize,
    output wire dbuf_rbusy, output wire dbuf_rvalid,
    output wire [255:0] dbuf_rdata,
    output reg [ADDR_WIDTH-1:0] fdma_raddr,
    output wire fdma_rreq, output reg [15:0] fdma_rsize,
    output wire fdma_rready,
    input wire fdma_rbusy, input wire fdma_rvalid,
    input wire [255:0] fdma_rdata, input wire axi_r_error
);
    localparam integer FRAME_BYTES=WIDTH*HEIGHT*4;
    localparam integer HALF_BYTES=WIDTH*2;
    localparam integer HALF_BEATS=WIDTH/16;
    localparam integer HALF_COUNT=HEIGHT*2;
    localparam integer BLOCK_BEATS=16;
    localparam integer BLOCK_BYTES=512;
    // A frame must fit entirely below bit 24 of its physical address.
    // Original logical bases 0/32/64 MiB; spare 16 MiB is unused slot padding.
    reg [2:0] map0,map1,map2,spare;
    function [ADDR_WIDTH-1:0] physical;
        input [2:0] slot;
        input [24:0] offset;
        begin physical=({{(ADDR_WIDTH-3){1'b0}},slot}<<24)+offset; end
    endfunction
    wire [7:0] wlogical=dbuf_waddr>>25;
    wire [7:0] rlogical=dbuf_raddr>>25;
    wire [2:0] wmap=(wlogical==0)?map0:((wlogical==1)?map1:((wlogical==2)?map2:3'd7));
    wire [2:0] rmap=(rlogical==0)?map0:((rlogical==1)?map1:((rlogical==2)?map2:3'd7));
    wire [24:0] woffset=dbuf_waddr[24:0];
    wire [24:0] roffset=dbuf_raddr[24:0];
    reg wrequest_seen;
    wire wstart=dbuf_wreq && !fdma_wbusy && !wrequest_seen;
    reg wbusy_q;
    wire wdone=wbusy_q && !fdma_wbusy;
    reg command_pending,capturing,wait_fence,frozen,detached;
    reg fatal_bus_error,stream_poisoned;
    reg response_pending,response_started,release_pending;
    reg [63:0] nonce; reg export_pixels;
    reg [31:0] frame_counter,capture_frame;
    reg [7:0] status;
    reg [7:0] cap_logical;
    reg [2:0] cap_physical;
    assign begin_frame_base=physical(cap_physical,25'd0);
    reg [15:0] complete_halves;
    reg [24:0] expected_write_offset;
    reg [31:0] wait_count;
    reg [31:0] aw_count,b_count,fence;
    reg capture_bad;
    reg tx_capture,tx_shape_ok;
    reg [15:0] tx_beats,tx_size;
    reg [24:0] tx_offset;
    wire redirect=frozen && !detached && !release_pending && !packet_done &&
                  (wlogical==cap_logical);
    assign mapped_waddr=physical(redirect?spare:wmap,woffset);
    assign req_ready=!(command_pending|capturing|wait_fence|frozen|
                       response_pending|response_started|release_pending|fatal_bus_error);
    assign begin_valid=response_pending;
    assign begin_nonce=nonce;
    assign begin_frame_id=capture_frame;
    assign begin_status=status;
    wire [31:0] responded_difference=b_count-fence;
    wire fence_reached=!responded_difference[31];

    // Owner is fixed for an entire FDMA transaction.  Snapshot busy/data never
    // reaches ui_dbuf, whose state machine otherwise mistakes it for its own.
    reg [1:0] owner; // 0 idle, 1 display, 2 snapshot
    reg seen_rbusy;
    reg [31:0] read_wait_count;
    wire transaction_done=(owner!=0)&&seen_rbusy&&!fdma_rbusy;
    assign fdma_rreq=(owner!=0)&&!seen_rbusy;
    assign fdma_rready=1'b1;
    assign dbuf_rbusy=(owner==1)&&fdma_rbusy;
    assign dbuf_rvalid=(owner==1)&&fdma_rvalid;
    assign dbuf_rdata=fdma_rdata;
    reg display_active;
    reg [2:0] display_physical;
    reg [7:0] display_logical;
    reg [24:0] display_tx_offset;
    reg [15:0] display_tx_size;
    wire display_grant=(owner==0)&&dbuf_rreq;
    wire [2:0] display_selected=(roffset==0)?rmap:display_physical;
    wire display_references_frozen=(display_active&&(display_physical==cap_physical)) ||
        (display_grant&&(display_selected==cap_physical));

    // One bounded block is completely buffered before UART backpressure can
    // occur.  Its maximum 16 DDR beats are independent of serial speed.
    reg stream_active,buffer_full;
    reg [31:0] read_offset;
    reg [4:0] block_size,received;
    reg [3:0] output_word;
    reg [2:0] output_lane;
    reg [1:0] output_channel;
    reg [255:0] block_mem[0:15];
    reg [255:0] current_word;
    wire snapshot_request=stream_active&&!buffer_full&&(read_offset<FRAME_BYTES);
    wire [31:0] bytes_left=FRAME_BYTES-read_offset;
    wire [15:0] next_block_beats=(bytes_left>=BLOCK_BYTES)?16:(bytes_left/32);
    reg [23:0] current_pixel;
    always @* begin
        case(output_lane)
            0:current_pixel=current_word[23:0];
            1:current_pixel=current_word[55:32];
            2:current_pixel=current_word[87:64];
            3:current_pixel=current_word[119:96];
            4:current_pixel=current_word[151:128];
            5:current_pixel=current_word[183:160];
            6:current_pixel=current_word[215:192];
            default:current_pixel=current_word[247:224];
        endcase
    end
    assign rgb_byte=(output_channel==0)?current_pixel[23:16]:
        ((output_channel==1)?current_pixel[15:8]:current_pixel[7:0]);
    assign rgb_byte_valid=buffer_full&&stream_active;

    always @(posedge clk) begin
        if(!rst_n) begin
            map0<=0; map1<=2; map2<=4; spare<=1;
            command_pending<=0; capturing<=0; wait_fence<=0;
            frozen<=0; detached<=0; response_pending<=0;
            response_started<=0; release_pending<=0;
            nonce<=0; export_pixels<=1'b1; frame_counter<=0; capture_frame<=0; status<=0;
            cap_logical<=0; cap_physical<=0; complete_halves<=0;
            expected_write_offset<=0;
            perf_capture_start<=0;perf_capture_end<=0;perf_capture_ready<=0;
            wait_count<=0; aw_count<=0; b_count<=0; fence<=0;
            capture_bad<=0; frame_error<=0; wbusy_q<=0; wrequest_seen<=0;
            tx_capture<=0; tx_shape_ok<=0; tx_beats<=0; tx_size<=0; tx_offset<=0;
            owner<=0; seen_rbusy<=0; fdma_raddr<=0; fdma_rsize<=0;
            read_wait_count<=0; fatal_bus_error<=0; stream_poisoned<=0;
            display_active<=0; display_physical<=0; display_logical<=0;
            display_tx_offset<=0; display_tx_size<=0;
            stream_active<=0; buffer_full<=0; read_offset<=0;
            block_size<=0; received<=0;
            output_word<=0; output_lane<=0; output_channel<=0; current_word<=0;
        end else begin
            wbusy_q<=fdma_wbusy;
            if(!dbuf_wreq) wrequest_seen<=0;
            if(wstart) wrequest_seen<=1;
            if(axi_aw_fire) aw_count<=aw_count+1'b1;
            if(axi_b_fire) b_count<=b_count+1'b1;
            if(req_valid&&req_ready) begin
                nonce<=req_nonce; export_pixels<=req_export; command_pending<=1; wait_count<=0;
                perf_capture_start<=0;perf_capture_end<=0;perf_capture_ready<=0;
                capture_bad<=0; frame_error<=0; status<=0;
                stream_poisoned<=0;
            end
            if(command_pending||capturing||wait_fence) begin
                if(wait_count<WAIT_CYCLES) wait_count<=wait_count+1'b1;
                else begin
                    command_pending<=0; capturing<=0; wait_fence<=0;
                    response_pending<=1; status<=3; frame_error<=1;
                end
            end
            if((capturing||wait_fence)&&axi_b_fire&&axi_b_error) begin
                capture_bad<=1; frame_error<=1;
            end
            if(wstart) begin
                tx_beats<=0; tx_size<=dbuf_wsize; tx_offset<=woffset;
                tx_capture<=0; tx_shape_ok<=0;
                if(woffset==0) frame_counter<=frame_counter+1'b1;
                if(redirect) begin
                    // Redirect the VERY FIRST beat, not one transaction later.
                    case(wlogical)
                        0:map0<=spare; 1:map1<=spare; 2:map2<=spare;
                    endcase
                    detached<=1;
                    if(woffset!=0) frame_error<=1;
                end
                if(command_pending && woffset==0 && wlogical<3) begin
                    command_pending<=0; capturing<=1; complete_halves<=0;perf_capture_start<=wait_count;
                    expected_write_offset<=0;
                    cap_logical<=wlogical; cap_physical<=wmap;
                    capture_frame<=frame_counter+1'b1;
                    tx_capture<=1;
                    tx_shape_ok<=(dbuf_wsize==HALF_BEATS);
                end else if(capturing) begin
                    tx_capture<=1;
                    tx_shape_ok<=(wlogical==cap_logical) &&
                        (woffset==expected_write_offset) && (dbuf_wsize==HALF_BEATS);
                end
            end
            if(fdma_wvalid) tx_beats<=tx_beats+1'b1;
            if(wdone && tx_capture && capturing) begin
                if(!tx_shape_ok || tx_beats!=tx_size) begin
                    capturing<=0; response_pending<=1; status<=1; frame_error<=1;
                end else if(complete_halves==HALF_COUNT-1) begin
                    capturing<=0; frozen<=1; detached<=0; wait_fence<=1;perf_capture_end<=wait_count;
                    fence<=aw_count+(axi_aw_fire?1'b1:1'b0);
                end else begin
                    complete_halves<=complete_halves+1'b1;
                    expected_write_offset<=expected_write_offset+HALF_BYTES;
                end
            end
            if(wait_fence && fence_reached) begin
                wait_fence<=0; response_pending<=1;perf_capture_ready<=wait_count;
                status<=fatal_bus_error?4:((capture_bad||(axi_b_fire&&axi_b_error))?2:0);
            end
            if(begin_valid&&begin_ready) begin
                response_pending<=0; response_started<=1;
                if(status==0 && export_pixels) begin
                    stream_active<=1; read_offset<=0; buffer_full<=0;
                    output_word<=0; output_lane<=0; output_channel<=0; received<=0;
                end
            end
            if(packet_done) begin
                release_pending<=1; response_started<=0;
                stream_active<=0; buffer_full<=0;
            end
            if(release_pending) begin
                if(!frozen || !detached) begin
                    frozen<=0; release_pending<=0;
                end else if(!display_references_frozen && owner!=2) begin
                    spare<=cap_physical; frozen<=0; detached<=0; release_pending<=0;
                end
            end

            if(owner==0) begin
                seen_rbusy<=0; read_wait_count<=0;
                if(fdma_rbusy) begin
                    // A response after a cancelled, never-started request is
                    // outside the FDMA contract. Do not give it another owner.
                    fatal_bus_error<=1; frame_error<=1;
                end else if(dbuf_rreq&&!fatal_bus_error) begin
                    owner<=1;
                    fdma_raddr<=physical(display_selected,roffset);
                    fdma_rsize<=dbuf_rsize;
                    display_tx_offset<=roffset; display_tx_size<=dbuf_rsize;
                    if(roffset==0) begin
                        display_active<=1; display_physical<=rmap;
                        display_logical<=rlogical;
                    end
                end else if(snapshot_request&&!fatal_bus_error) begin
                    received<=0; block_size<=next_block_beats;
                    if(stream_poisoned) begin
                        // Finish the declared body as zeros with an error
                        // trailer. Such a response is NEVER a dataset image.
                        buffer_full<=1; current_word<=0;
                        output_word<=0; output_lane<=0; output_channel<=0;
                        read_offset<=read_offset+(next_block_beats*32);
                    end else begin
                        owner<=2;
                        fdma_raddr<=physical(cap_physical,read_offset[24:0]);
                        fdma_rsize<=next_block_beats;
                    end
                end
            end else begin
                if(read_wait_count<READ_WAIT_CYCLES) read_wait_count<=read_wait_count+1'b1;
                else begin
                    frame_error<=1;
                    if(owner==2&&!seen_rbusy&&!fdma_rbusy) begin
                        // No busy acknowledgement: retract the unaccepted
                        // request. The known ui_FDMA acknowledges in one cycle.
                        owner<=0; stream_poisoned<=1; received<=0;
                        buffer_full<=1; current_word<=0;
                        output_word<=0; output_lane<=0; output_channel<=0;
                        read_offset<=read_offset+(block_size*32);
                    end else begin
                        // Busy asserted: never reassign an outstanding DDR
                        // transaction. Shared-bus fault is fail-stop; reset is
                        // required. A PC timeout does NOT reset the hardware.
                        fatal_bus_error<=1;
                    end
                end
                if(fdma_rbusy) seen_rbusy<=1;
                if(owner==2&&fdma_rvalid) begin
                    if(received<16) block_mem[received[3:0]]<=fdma_rdata;
                    received<=received+1'b1;
                    if(axi_r_error || received>=block_size) frame_error<=1;
                end
                if(transaction_done) begin
                    owner<=0; seen_rbusy<=0;
                    if(owner==1) begin
                        if(display_tx_offset==FRAME_BYTES-HALF_BYTES &&
                           display_tx_size==HALF_BEATS) display_active<=0;
                    end else begin
                        if(received!=block_size) frame_error<=1;
                        buffer_full<=1; output_word<=0; output_lane<=0; output_channel<=0;
                        current_word<=(received!=0)?block_mem[0]:256'd0;
                        read_offset<=read_offset+(block_size*32);
                    end
                end
            end
            if(rgb_byte_valid&&rgb_byte_ready) begin
                if(output_channel!=2) output_channel<=output_channel+1'b1;
                else begin
                    output_channel<=0;
                    if(output_lane!=7) output_lane<=output_lane+1'b1;
                    else begin
                        output_lane<=0;
                        if(output_word==block_size-1) begin
                            output_word<=0; buffer_full<=0;
                            if(read_offset==FRAME_BYTES) stream_active<=0;
                        end else begin
                            output_word<=output_word+1'b1;
                            current_word<=(output_word+1<received)?block_mem[output_word+1'b1]:256'd0;
                        end
                    end
                end
            end
        end
    end
endmodule
