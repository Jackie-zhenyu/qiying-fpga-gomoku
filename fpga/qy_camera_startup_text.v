`timescale 1ns/1ps
`default_nettype none
// Temporary bring-up line below the camera viewport, hidden while ready.
// P=DDR PLL, D=DDR calibrated, B=buffer released, C=camera configured,
// F=fresh camera frame, E=DDR error hex byte, S=DDR training step hex byte.
module qy_camera_startup_text(
    input wire [11:0] x_i,y_i,
    input wire [20:0] status_i,
    input wire visible_i,
    output wire ink_o
);
    wire [11:0] dx=x_i-12'd1200;
    wire [11:0] dy=y_i-12'd564;
    wire [4:0] char_cell=dx[8:4];
    wire [2:0] gx=dx[3:1], gy=dy[3:1];
    reg [5:0] character;
    // 0..15 hex; 16..20 P,D,B,C,F; 21 E; 22 S; 31 space.
    always @* begin
        character=31;
        case(char_cell)
            0:character=16; 1:character={5'd0,status_i[19]};
            3:character=17; 4:character={5'd0,status_i[18]};
            6:character=18; 7:character={5'd0,status_i[17]};
            9:character=19; 10:character={5'd0,status_i[16]};
            12:character=20; 13:character={5'd0,status_i[20]};
            15:character=21; 16:character={2'd0,status_i[15:12]}; 17:character={2'd0,status_i[11:8]};
            19:character=22; 20:character={2'd0,status_i[7:4]}; 21:character={2'd0,status_i[3:0]};
            default:character=31;
        endcase
    end
    function [34:0] font;
        input [5:0] ch;
        begin case(ch)
            0:font={5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            1:font={5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            2:font={5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            3:font={5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            4:font={5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            5:font={5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            6:font={5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            7:font={5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            8:font={5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            9:font={5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            10:font={5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            11,18:font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            12,19:font={5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
            13,17:font={5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            14,21:font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            15,20:font={5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            16:font={5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            22:font={5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            default:font=0;
        endcase end
    endfunction
    wire [34:0] glyph=font(character);
    assign ink_o=visible_i && x_i>=1200 && x_i<1552 && y_i>=564 && y_i<578 && gx<5 && gy<7
                 && glyph[34-(gy*5+gx)];
endmodule
`default_nettype wire
