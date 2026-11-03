`timescale 1ns/1ps
module tb_peripheral_voice;
 localparam [63:0] SPEECH_GAP_US=12000000;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,enabled=0,rx_valid=0,rx_error=0,phrase_valid=0,invalidate=0,tx_ready=0;
 reg [63:0] now_us=0;
 reg [7:0] rx_data=0,phrase_id=0;
 wire cmd_valid,tx_valid,speech_busy;wire [3:0] cmd;wire [7:0] tx_data;wire [31:0] rejected;
 qy_peripheral_voice dut(.*);
 integer commands=0,bytes_sent=0,checks=0,n,base_count;
 reg [3:0] accepted[0:255];reg [7:0] sent[0:1023];reg [7:0] stalled;
 always @(posedge clk)begin
  if(!rst_n)bytes_sent=0;
  else if(tx_valid&&tx_ready)begin sent[bytes_sent]=tx_data;bytes_sent=bytes_sent+1;end
  #1;
  if(!rst_n)commands=0;
  else if(cmd_valid)begin accepted[commands]=cmd;commands=commands+1;end
 end
 task tick;begin @(posedge clk);#2;end endtask
 task check(input bit condition,input [639:0] label_text);begin
  checks=checks+1;if(!condition)begin $display("FAIL %0s at t=%0t commands=%0d bytes=%0d",label_text,$time,commands,bytes_sent);$fatal(1);end
 end endtask
 task reset(input bit en);begin
  @(negedge clk);rst_n=0;enabled=0;rx_valid=0;rx_error=0;
  phrase_valid=0;invalidate=0;tx_ready=0;now_us=0;
  repeat(3)tick();@(negedge clk);rst_n=1;enabled=en;repeat(3)tick();
 end endtask
 task byte_in(input [7:0] value);begin
  @(negedge clk);rx_data=value;rx_valid=1;now_us=now_us+100;tick();
  @(negedge clk);rx_valid=0;tick();
 end endtask
 task frame(input [7:0] kind,input [7:0] value);begin
  byte_in(8'haa);byte_in(8'h55);byte_in(kind);byte_in(value);byte_in(8'hfb);
 end endtask
 task phrase(input [7:0] value);begin
  @(negedge clk);phrase_id=value;phrase_valid=1;tick();
  @(negedge clk);phrase_valid=0;tick();
 end endtask
 task cancel;begin
  @(negedge clk);invalidate=1;tick();@(negedge clk);invalidate=0;tick();
 end endtask
 task advance(input [63:0] interval_us);begin
  @(negedge clk);now_us=now_us+interval_us;tick();
 end endtask
 task check_packet(input integer offset,input [7:0] value);begin
  check(sent[offset]==8'haa&&sent[offset+1]==8'h55&&sent[offset+2]==8'hff&&
        sent[offset+3]==value&&sent[offset+4]==8'hfb,"exact five-byte speech packet");
 end endtask
 task drain(input integer total);integer guard;begin
  @(negedge clk);tx_ready=1;guard=0;
  while(bytes_sent<total&&guard<100)begin tick();guard=guard+1;end
  check(bytes_sent==total,"TX drains expected byte count");
  @(negedge clk);tx_ready=0;tick();
 end endtask
 initial begin
  reset(0);
  frame(0,8'hc1);phrase(8'hd0);drain(0);
  check(commands==0&&!speech_busy&&rejected==0,"disabled ignores commands and speech");
  reset(1);
  for(n=1;n<=8;n=n+1)begin frame(0,8'hc0+n);check(commands==n&&accepted[n-1]==n,"C1..C8 map to commands 1..8");end
  for(n=1;n<=8'h5e;n=n+1)frame(0,n);
  check(commands==8&&rejected==94,"all factory 01..5E rejected while enabled");
  frame(0,8'hc0);frame(0,8'hc9);frame(8'hff,8'hc1);frame(1,8'hc1);
  check(commands==8&&rejected==98,"unknown IDs and function/broadcast types rejected");
  frame(0,8'hc1);base_count=commands;frame(0,8'hc1);
  check(commands==base_count,"same command inside 300ms suppressed");
  advance(300000);frame(0,8'hc1);
  check(commands==base_count+1,"same command after 300ms accepted");
  // No idle cycles between frames: one byte each clock still decodes safely.
  @(negedge clk);rx_valid=1;rx_data=8'haa;tick();
  @(negedge clk);rx_data=8'h55;tick();@(negedge clk);rx_data=0;tick();
  @(negedge clk);rx_data=8'hc2;tick();@(negedge clk);rx_data=8'hfb;tick();
  @(negedge clk);rx_data=8'haa;tick();@(negedge clk);rx_data=8'h55;tick();
  @(negedge clk);rx_data=0;tick();@(negedge clk);rx_data=8'hc3;tick();
  @(negedge clk);rx_data=8'hfb;tick();@(negedge clk);rx_valid=0;tick();
  check(accepted[commands-2]==2&&accepted[commands-1]==3,"back-to-back frames accepted");
  base_count=commands;byte_in(8'haa);byte_in(8'h55);advance(20001);byte_in(0);byte_in(8'hc4);byte_in(8'hfb);
  check(commands==base_count,"timed-out half frame cannot emit command");
  frame(0,8'hc4);check(commands==base_count+1,"clean frame recovers after timeout");
  byte_in(8'haa);byte_in(8'h55);@(negedge clk);rx_error=1;tick();@(negedge clk);rx_error=0;
  byte_in(0);byte_in(8'hc5);byte_in(8'hfb);check(commands==base_count+1,"UART error discards partial frame");
  byte_in(8'haa);byte_in(8'haa);byte_in(8'h55);byte_in(0);byte_in(8'hc5);byte_in(8'hfb);
  check(commands==base_count+2,"repeated header AA resynchronizes");
  byte_in(8'haa);byte_in(8'h55);byte_in(0);byte_in(8'hc6);byte_in(8'haa);
  byte_in(8'h55);byte_in(0);byte_in(8'hc6);byte_in(8'hfb);
  check(commands==base_count+3,"AA malformed trailer can start next frame");
  base_count=commands;byte_in(8'haa);byte_in(8'h55);cancel();byte_in(0);byte_in(8'hc7);byte_in(8'hfb);
  check(commands==base_count,"invalidate clears RX partial frame");
  byte_in(8'haa);byte_in(8'h55);@(negedge clk);enabled=0;tick();
  byte_in(0);byte_in(8'hc7);@(negedge clk);enabled=1;tick();byte_in(8'hfb);
  check(commands==base_count,"disable/re-enable cannot complete stale RX frame");
  frame(0,8'hc7);check(commands==base_count+1,"full command after re-enable works");
  byte_in(8'haa);byte_in(8'h55);@(negedge clk);now_us=0;tick();
  byte_in(0);byte_in(8'hc8);byte_in(8'hfb);check(commands==base_count+1,"clock rollback discards partial RX frame");
  base_count=commands;byte_in(8'haa);byte_in(8'h55);
  @(negedge clk);now_us=now_us+20001;rx_data=8'haa;rx_valid=1;tick();
  @(negedge clk);rx_valid=0;tick();byte_in(8'h55);byte_in(0);byte_in(8'hc8);byte_in(8'hfb);
  check(commands==base_count+1,"new AA on timeout edge starts a fresh frame");

  reset(1);phrase(8'hcf);phrase(8'he9);repeat(5)tick();
  check(!speech_busy&&!tx_valid,"out-of-profile speech is ignored");
  phrase(8'hd0);repeat(3)tick();check(speech_busy&&tx_valid&&tx_data==8'haa,"first speech waits for ready");
  phrase(8'hd1);drain(5);check_packet(0,8'hd1);
  check(!speech_busy,"transport occupancy clears after complete frame");
  phrase(8'hd2);phrase(8'hd3);repeat(4)tick();check(!tx_valid&&speech_busy,"speech queues during conservative gap");
  advance(SPEECH_GAP_US-1);check(!tx_valid,"speech cannot start before 12-second gap");
  advance(1);repeat(2)tick();drain(10);check_packet(5,8'hd3);
  repeat(5)tick();check(bytes_sent==10,"replaced old phrase never sends later");
  phrase(8'hd4);cancel();advance(SPEECH_GAP_US);repeat(4)tick();
  check(!speech_busy&&!tx_valid&&bytes_sent==10,"invalidate removes unsent gap queue");
  phrase(8'hd5);repeat(2)tick();cancel();drain(10);
  check(!speech_busy&&bytes_sent==10,"invalidate before first handshake cancels entire packet");

  reset(1);phrase(8'he8);repeat(2)tick();
  for(n=0;n<5;n=n+1)begin
   stalled=tx_data;repeat(7)begin tick();check(tx_valid&&tx_data==stalled,"backpressure preserves byte and valid");end
   @(negedge clk);tx_ready=1;tick();@(negedge clk);tx_ready=0;tick();
  end
  check(bytes_sent==5,"five independently stalled bytes accepted once");check_packet(0,8'he8);
  reset(1);phrase(8'hd6);drain(2);phrase(8'hd7);
  @(negedge clk);enabled=0;tick();check(tx_valid&&speech_busy,"disable preserves frame already started");
  frame(0,8'hc1);phrase(8'hd8);drain(5);check_packet(0,8'hd6);
  advance(SPEECH_GAP_US+1000000);repeat(5)tick();check(commands==0&&!speech_busy&&!tx_valid,"disabled RX and queued speech discarded");
  @(negedge clk);enabled=1;tick();repeat(4)tick();check(!speech_busy,"re-enable does not resurrect speech");
  phrase(8'hd9);drain(7);phrase(8'hda);cancel();drain(10);check_packet(5,8'hd9);
  advance(SPEECH_GAP_US+1000000);repeat(5)tick();check(bytes_sent==10&&!speech_busy,"cancel completes active frame and removes pending phrase");
  reset(1);phrase(8'hdb);drain(1);
  @(negedge clk);enabled=0;tick();@(negedge clk);enabled=1;tick();drain(5);check_packet(0,8'hdb);
  check(bytes_sent==5&&!speech_busy,"disable and re-enable within a frame preserve exact packet");
  // Enumerate all supported transmit IDs; each must be preserved on the wire.
  reset(1);
  for(n=8'hd0;n<=8'he8;n=n+1)begin
   phrase(n);advance(SPEECH_GAP_US);repeat(2)tick();drain((n-8'hd0+1)*5);check_packet((n-8'hd0)*5,n);
  end
  check(bytes_sent==125,"all 25 phrases transmitted exactly once");
  $display("PASS qy_peripheral_voice: %0d checks",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"watchdog");end
endmodule
