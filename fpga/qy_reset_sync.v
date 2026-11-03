`timescale 1ns / 1ps
`default_nettype none

// The board wrapper must provide a real power-on/clock-failure reset source.
// Assertion is asynchronous; release requires two rising clock edges.
// No key is used as reset by this module.
module qy_reset_sync (
    input  wire clk_i,
    input  wire arst_n_i,
    output wire rst_n_o
);
    // A placement hint, not a substitute for vendor CDC/placement review.
    (* ASYNC_REG = "TRUE" *) reg [1:0] release_pipe;

    always @(posedge clk_i or negedge arst_n_i) begin
        if (!arst_n_i)
            release_pipe <= 2'b00;
        else
            release_pipe <= {release_pipe[0], 1'b1};
    end

    assign rst_n_o = release_pipe[1];
endmodule

`default_nettype wire
