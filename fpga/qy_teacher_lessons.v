`default_nettype none
// Four starter exercises follow the calibrated first-black identity.
// Each has four black/four white, with black to play and one immediate answer.
// A broken four inside five crossings makes the answer unique even when the
// first black is central on a 5x5 board. The origin is never moved or recolored.
// This board is a setup guide; the teaching core must observe it before commit.
module qy_teacher_lessons(
 input wire defence,vertical,
 input wire [3:0] board_size,
 input wire anchor_valid,input wire [7:0] anchor_index,
 output reg [337:0] board,output reg valid
);
 integer ar,ac,ap,aq,n,start_p,gap,line_q,other_q,extra_q;
 integer i,p,q,index,placed;
 always @* begin
  board=0;valid=0;
  ar=anchor_index/13;ac=anchor_index%13;n=board_size;
  ap=vertical?ar:ac;aq=vertical?ac:ar;
  start_p=0;gap=2;line_q=0;other_q=0;extra_q=0;
  p=0;q=0;index=0;placed=0;
  if(anchor_valid&&n>=5&&n<=13&&anchor_index<169&&ar<n&&ac<n)begin
   valid=1;
   start_p=ap>=2?ap-2:0;
   if(start_p>n-5)start_p=n-5;
   other_q=aq+1;if(other_q>=n)other_q=other_q-n;
   extra_q=aq+2;if(extra_q>=n)extra_q=extra_q-n;
   line_q=defence?other_q:aq;
   if(!defence&&ap-start_p==2)gap=1;
   for(i=0;i<5;i=i+1)begin
    if(i!=gap)begin
     p=start_p+i;q=line_q;index=vertical?p*13+q:q*13+p;
     board[index*2+:2]=defence?2'd2:2'd1;
    end
   end
   if(defence)begin
    board[anchor_index*2+:2]=2'd1;
    // Three blacks on the origin row and one elsewhere cannot form a four.
    placed=0;
    for(i=0;i<3;i=i+1)begin
     if(i!=ap&&placed<2)begin
      p=i;q=aq;index=vertical?p*13+q:q*13+p;
      board[index*2+:2]=2'd1;placed=placed+1;
     end
    end
    p=1;q=extra_q;index=vertical?p*13+q:q*13+p;
    board[index*2+:2]=2'd1;
   end else begin
    for(i=0;i<3;i=i+1)begin
     p=i*2;q=other_q;index=vertical?p*13+q:q*13+p;
     board[index*2+:2]=2'd2;
    end
    p=1;q=extra_q;index=vertical?p*13+q:q*13+p;
    board[index*2+:2]=2'd2;
   end
  end
 end
endmodule
`default_nettype wire
