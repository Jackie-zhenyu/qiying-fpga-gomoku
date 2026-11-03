`default_nettype none
// Byte 0 is least significant. Matching includes the full UID AND length.
// 0 enable bits = safe default for unregistered cards. Duplicate maps rejected.
module qy_teacher_cards(
 input wire clk,rst_n,uid_valid,input wire [79:0] uid,input wire [3:0] uid_length,
 input wire [3:0] enabled,input wire [319:0] uids,input wire [15:0] lengths,
 output reg card_valid,output reg [2:0] card_mode,output reg unknown
);
 integer i,j,match_count;reg [2:0] found;reg equal_uid;
 always @* begin
  match_count=0;found=0;
  for(i=0;i<4;i=i+1)begin
   equal_uid=enabled[i]&&lengths[i*4+:4]==uid_length&&(uid_length==4||uid_length==7||uid_length==10);
   for(j=0;j<10;j=j+1)if(j<uid_length&&uid[j*8+:8]!=uids[i*80+j*8+:8])equal_uid=0;
   if(equal_uid)begin match_count=match_count+1;found=i+1;end
  end
 end
 always @(posedge clk)begin
  if(!rst_n)begin card_valid<=0;card_mode<=0;unknown<=0;end
  else begin card_valid<=0;unknown<=0;
   if(uid_valid)begin if(match_count==1)begin card_valid<=1;card_mode<=found;end else unknown<=1;end
  end
 end
endmodule
`default_nettype wire

