`timescale 1ns / 1ps
`default_nettype none

// Independent four-key synchronizer and consecutive-sample debounce filters.
// key_i[0..3] = logical KEY1..KEY4. Events last exactly one clk_i cycle.
// A key must be stably released after reset before it can emit any event.
module qy_key_frontend #(
    parameter integer CLK_HZ = 25_000_000,
    parameter integer DEBOUNCE_MS = 20,
    parameter [3:0] ACTIVE_LOW_MASK = 4'b1111
) (
    input  wire       clk_i,
    input  wire       arst_n_i,
    input  wire [3:0] key_i,
    output reg  [3:0] armed_o,
    output reg  [3:0] pressed_o,
    output reg  [3:0] press_pulse_o,
    output reg  [3:0] release_pulse_o
);
    function integer width_for_max;
        input [63:0] value;
        reg [63:0] remaining;
        begin
            remaining = value;
            width_for_max = 0;
            while (remaining != 0) begin
                width_for_max = width_for_max + 1;
                remaining = remaining >> 1;
            end
            if (width_for_max == 0)
                width_for_max = 1;
        end
    endfunction

    // Widen BEFORE multiplying: valid clock/rate combinations can exceed a
    // signed 32-bit intermediate. Round upwards, never shorten the window.
    localparam [63:0] CYCLES_CALC =
        (64'd1 * CLK_HZ * DEBOUNCE_MS + 64'd999) / 64'd1000;
    localparam [63:0] DEBOUNCE_CYCLES = (CYCLES_CALC < 1) ? 64'd1 : CYCLES_CALC;
    localparam integer COUNT_WIDTH = width_for_max(DEBOUNCE_CYCLES - 1);
    localparam [COUNT_WIDTH-1:0] LAST_SAMPLE = DEBOUNCE_CYCLES - 1;

    wire rst_n;
    qy_reset_sync reset_sync (
        .clk_i(clk_i), .arst_n_i(arst_n_i), .rst_n_o(rst_n)
    );

    (* ASYNC_REG = "TRUE" *) reg [3:0] key_meta;
    (* ASYNC_REG = "TRUE" *) reg [3:0] key_sync;
    reg [1:0] sample_valid;

    always @(posedge clk_i or negedge rst_n) begin
        if (!rst_n) begin
            key_meta <= 4'b0000;
            key_sync <= 4'b0000;
            sample_valid <= 2'b00;
        end else begin
            key_meta <= key_i ^ ACTIVE_LOW_MASK;
            key_sync <= key_meta;
            sample_valid <= {sample_valid[0], 1'b1};
        end
    end

    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : key_filter
            reg [COUNT_WIDTH-1:0] stable_count;
            always @(posedge clk_i or negedge rst_n) begin
                if (!rst_n) begin
                    stable_count <= {COUNT_WIDTH{1'b0}};
                    armed_o[k] <= 1'b0;
                    pressed_o[k] <= 1'b0;
                    press_pulse_o[k] <= 1'b0;
                    release_pulse_o[k] <= 1'b0;
                end else begin
                    press_pulse_o[k] <= 1'b0;
                    release_pulse_o[k] <= 1'b0;
                    if (!sample_valid[1]) begin
                        stable_count <= {COUNT_WIDTH{1'b0}};
                    end else if (!armed_o[k]) begin
                        // Synchronizer reset values cannot arm a held key:
                        // sample_valid has already flushed the two stages.
                        if (!key_sync[k]) begin
                            if (stable_count == LAST_SAMPLE) begin
                                armed_o[k] <= 1'b1;
                                stable_count <= {COUNT_WIDTH{1'b0}};
                            end else
                                stable_count <= stable_count + 1'b1;
                        end else
                            stable_count <= {COUNT_WIDTH{1'b0}};
                    end else if ((key_sync[k] == 1'b0) || (key_sync[k] == 1'b1)) begin
                        if (key_sync[k] == pressed_o[k])
                            stable_count <= {COUNT_WIDTH{1'b0}};
                        else if (stable_count == LAST_SAMPLE) begin
                            pressed_o[k] <= key_sync[k];
                            press_pulse_o[k] <= key_sync[k];
                            release_pulse_o[k] <= !key_sync[k];
                            stable_count <= {COUNT_WIDTH{1'b0}};
                        end else
                            stable_count <= stable_count + 1'b1;
                    end else begin
                        // X/Z is simulation diagnostic data, not a valid key
                        // sample; do not integrate it into the stable window.
                        stable_count <= {COUNT_WIDTH{1'b0}};
                    end
                end
            end
        end
    endgenerate

    // synthesis translate_off
    initial begin
        if (CLK_HZ <= 0 || DEBOUNCE_MS <= 0)
            $fatal(1, "CONFIG_ERROR: CLK_HZ and DEBOUNCE_MS must be positive");
    end
    // synthesis translate_on
endmodule

`default_nettype wire
