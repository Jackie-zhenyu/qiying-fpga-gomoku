`timescale 1ns/1ps
`default_nettype none

// Quantized activation/activation dot product. Both operands have U8 zero
// points; this is distinct from the signed, zero-centered Conv weight port.
// Post-scaling is the same signed40 / signed31 / exact nearest-even pipeline.
// m_pre and m_activation are equal, preserving the existing result tuple.
module qy_u8_dot_pipeline (
    input wire clk, input wire rst,
    input wire cmd_valid, output wire cmd_ready,
    input wire [31:0] cmd_tag,
    input wire [11:0] cmd_terms,
    input wire signed [31:0] cmd_bias,
    input wire [7:0] cmd_input_zero,
    input wire [31:0] cmd_multiplier,
    input wire [5:0] cmd_shift,
    input wire [7:0] cmd_output_zero,
    input wire [7:0] cmd_weight_zero,
    input wire s_valid, output wire s_ready,
    input wire [7:0] s_activation,
    input wire [7:0] s_weight,
    output wire m_valid, input wire m_ready,
    output reg [31:0] m_tag,
    output reg signed [39:0] m_sum,
    output reg [7:0] m_pre, output reg [7:0] m_activation,
    output reg [2:0] m_error
);
    // One job remains in flight. Pipeline stages break the wide requant path.
    localparam [3:0] IDLE=0, MAC=1, POST=2, ABS=3, SPLIT=4,
        ROUND=5, SIGN=6, ZERO=7, SAT=8, GAP=9, FINISH=10, OUTPUT=11;
    reg [3:0] state;
    reg [11:0] remaining;
    reg signed [39:0] accumulator;
    reg [31:0] tag, multiplier;
    reg [7:0] input_zero, output_zero;
    reg [5:0] shift;
    reg [7:0] weight_zero;
    reg signed [71:0] scaled_product;
    reg [71:0] magnitude, quotient, remainder, half, rounded_mag;
    reg negative;
    reg signed [72:0] rounded, shifted;
    reg [7:0] saturated;
    assign cmd_ready = !rst && (state == IDLE);
    assign s_ready = !rst && (state == MAC);
    assign m_valid = !rst && (state == OUTPUT);
    wire [2:0] command_error = {
        1'b0,
        (cmd_multiplier[31] || cmd_multiplier == 0 || cmd_shift == 6'd63),
        (cmd_terms == 0 || cmd_terms > 12'd2304)
    };
    wire signed [8:0] centered = $signed({1'b0,s_activation}) - $signed({1'b0,input_zero});
    wire signed [8:0] centered_weight = $signed({1'b0,s_weight}) - $signed({1'b0,weight_zero});
    wire signed [17:0] sample_product = centered * centered_weight;
    wire signed [39:0] product_ext = {{22{sample_product[17]}},sample_product};

    // Exact signed nearest-even rounding. Shift is latched in range 0..62.
    wire increment = (shift != 0) && ((remainder > half) ||
                                      ((remainder == half) && quotient[0]));

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; remaining <= 0; accumulator <= 0;
            tag <= 0; multiplier <= 0; input_zero <= 0; output_zero <= 0;
            shift <= 0; weight_zero <= 0;
            m_tag <= 0; m_sum <= 0; m_pre <= 0; m_activation <= 0; m_error <= 0;
        end else begin
            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    if (command_error != 0) begin
                        m_tag <= cmd_tag; m_sum <= 0; m_pre <= 0; m_activation <= 0;
                        m_error <= command_error; state <= OUTPUT;
                    end else begin
                        remaining <= cmd_terms;
                        accumulator <= {{8{cmd_bias[31]}},cmd_bias};
                        tag <= cmd_tag; input_zero <= cmd_input_zero;
                        multiplier <= cmd_multiplier; shift <= cmd_shift;
                        output_zero <= cmd_output_zero; weight_zero <= cmd_weight_zero; state <= MAC;
                    end
                end
                MAC: if (s_valid && s_ready) begin
                    accumulator <= accumulator + product_ext;
                    remaining <= remaining - 12'd1;
                    if (remaining == 12'd1) state <= POST;
                end
                POST: begin
                    scaled_product <= accumulator * $signed(multiplier);
                    state <= ABS;
                end
                ABS: begin
                    magnitude <= scaled_product[71] ? -scaled_product : scaled_product;
                    negative <= scaled_product[71]; state <= SPLIT;
                end
                SPLIT: begin
                    quotient <= magnitude >> shift;
                    remainder <= magnitude & ((72'd1 << shift) - 72'd1);
                    half <= (shift == 0) ? 72'd0 : (72'd1 << (shift-1));
                    state <= ROUND;
                end
                ROUND: begin
                    rounded_mag <= quotient + {{71{1'b0}},increment}; state <= SIGN;
                end
                SIGN: begin
                    rounded <= negative ? -$signed({1'b0,rounded_mag}) : $signed({1'b0,rounded_mag});
                    state <= ZERO;
                end
                ZERO: begin
                    shifted <= rounded + $signed({65'd0,output_zero}); state <= SAT;
                end
                SAT: begin
                    saturated <= (shifted < 0) ? 8'd0 : (shifted > 255) ? 8'd255 : shifted[7:0];
                    state <= GAP;
                end
                GAP: state <= FINISH;
                FINISH: begin
                    m_tag <= tag; m_sum <= accumulator;
                    m_pre <= saturated; m_activation <= saturated;
                    m_error <= 0; state <= OUTPUT;
                end
                OUTPUT: if (m_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
