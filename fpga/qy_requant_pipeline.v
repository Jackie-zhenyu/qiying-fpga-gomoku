`timescale 1ns/1ps
`default_nettype none
// Ten-stage, globally stalled exact requantization. A blocked output holds
// every stage, including the synchronous optional LUT. Reset cancels all
// accepted commands; no result from a cancelled epoch can escape.
module qy_requant_pipeline #(parameter LUT_FILE="silu_banks.hex")(
    input wire clk,rst,
    input wire cmd_valid,output wire cmd_ready,
    input wire [31:0] cmd_tag,input wire [11:0] cmd_terms,
    input wire signed [39:0] cmd_sum,input wire [31:0] cmd_multiplier,
    input wire [5:0] cmd_shift,input wire [7:0] cmd_output_zero,
    input wire [6:0] cmd_lut_bank,input wire cmd_use_lut,
    output wire m_valid,input wire m_ready,output wire [31:0] m_tag,
    output wire signed [39:0] m_sum,output wire [7:0] m_pre,m_activation,
    output wire [2:0] m_error
);
    reg [9:0] valid;
    wire advance=!valid[9]||m_ready;
    assign cmd_ready=!rst&&advance;
    assign m_valid=!rst&&valid[9];
    reg [31:0] tags[0:9];reg signed [39:0] sums[0:9];
    reg [2:0] errors[0:9];reg [5:0] shifts[0:9];
    reg [7:0] zeros[0:9];reg [6:0] banks[0:9];reg uses[0:9];
    reg [31:0] multiplier0;
    reg signed [71:0] product1;
    reg [71:0] magnitude2,quotient3,remainder3,half3,rounded4;
    reg negative2,negative3,negative4;
    reg signed [72:0] signed5,shifted6;
    reg [7:0] saturated7,saturated8,pre9,value9,lut8;
    reg [7:0] lut[0:32767];initial $readmemh(LUT_FILE,lut);
    wire [2:0] command_error={1'b0,
        (cmd_multiplier[31]||cmd_multiplier==0||cmd_shift==63),
        (cmd_terms==0||cmd_terms>2304)};
    wire increment=(shifts[3]!=0)&&((remainder3>half3)||
        ((remainder3==half3)&&quotient3[0]));
    assign m_tag=tags[9];assign m_error=errors[9];
    assign m_sum=(errors[9]!=0)?40'sd0:sums[9];
    assign m_pre=(errors[9]!=0)?8'd0:pre9;
    assign m_activation=(errors[9]!=0)?8'd0:value9;
    // Synchronous ROM with explicit CE, without a reset in the memory port.
    always @(posedge clk) if(advance) lut8<=lut[{banks[7],saturated7}];
    integer i;
    always @(posedge clk) begin
        if(rst) valid<=0;
        else if(advance) begin
            valid<={valid[8:0],cmd_valid};
            tags[0]<=cmd_tag;sums[0]<=cmd_sum;errors[0]<=command_error;
            shifts[0]<=cmd_shift;zeros[0]<=cmd_output_zero;
            banks[0]<=cmd_lut_bank;uses[0]<=cmd_use_lut;multiplier0<=cmd_multiplier;
            for(i=1;i<10;i=i+1) begin
                tags[i]<=tags[i-1];sums[i]<=sums[i-1];errors[i]<=errors[i-1];
                shifts[i]<=shifts[i-1];zeros[i]<=zeros[i-1];
                banks[i]<=banks[i-1];uses[i]<=uses[i-1];
            end
            product1<=sums[0]*$signed(multiplier0);
            magnitude2<=product1[71]?-product1:product1;negative2<=product1[71];
            quotient3<=magnitude2>>shifts[2];
            remainder3<=magnitude2&((72'd1<<shifts[2])-72'd1);
            half3<=shifts[2]==0?72'd0:(72'd1<<(shifts[2]-1));negative3<=negative2;
            rounded4<=quotient3+{{71{1'b0}},increment};negative4<=negative3;
            signed5<=negative4?-$signed({1'b0,rounded4}):$signed({1'b0,rounded4});
            shifted6<=signed5+$signed({65'd0,zeros[5]});
            saturated7<=shifted6<0?8'd0:shifted6>255?8'd255:shifted6[7:0];
            saturated8<=saturated7;
            pre9<=saturated8;value9<=uses[8]?lut8:saturated8;
        end
    end
endmodule
`default_nettype wire
