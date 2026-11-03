`timescale 1ns/1ps
`default_nettype none
module tb_settings;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0;reg [63:0] now_us=1000;
 always @(posedge clk)now_us<=now_us+1;
 reg settings_active=0;reg [3:0] key_press=0;
 reg uid_valid=0;reg [79:0] uid=0;reg [3:0] uid_length=0;
 reg card_present=0,nfc_ready=1,nfc_fault=0;
 reg config_initialized=0,config_valid=0;reg [255:0] config_data=0;reg [7:0] config_error=0;
 wire save_valid,done_ready;wire [255:0] save_data;reg save_ready=0,done_valid=0;reg [7:0] done_error=0;
 wire [239:0] card_uids;wire [11:0] card_lengths;wire [2:0] card_enabled,selection;
 wire voice_enabled,nfc_restart,card_valid,learning,voice_confirm,saving,dirty,busy;
 wire [1:0] card_action;wire [4:0] notice;wire notice_toggle;
 qy_peripheral_settings #(.LEARN_US(40),.NOTICE_US(100)) dut(.*);
 localparam [79:0] UID4=80'h00000000000012345678,UID7=80'h00000011223344556677,UID10=80'hffeeddccbbaa99887766;
 integer checks=0,events=0,retries=0,old_events,i;reg [1:0] last_action;reg [255:0] snapshot;
 always @(posedge clk)begin #1;if(card_valid)begin events=events+1;last_action=card_action;end if(nfc_restart)retries=retries+1;end
 task ck(input bit pass,input string what);begin checks=checks+1;if(!pass)$fatal(1,"SETTINGS %s time=%0d selection=%0d learning=%b notice=%0d events=%0d",what,now_us,selection,learning,notice,events);end endtask
 task ticks(input integer n);begin repeat(n)@(negedge clk);end endtask
 task press(input [3:0] keys);begin @(negedge clk);key_press=keys;@(negedge clk);key_press=0;ticks(1);end endtask
 task present(input [79:0] value,input [3:0] length);begin @(negedge clk);uid=value;uid_length=length;uid_valid=1;@(negedge clk);uid_valid=0;ticks(3);end endtask
 task page(input bit active);begin @(negedge clk);settings_active=active;ticks(3);end endtask
 task reset;begin @(negedge clk);rst_n=0;settings_active=0;key_press=0;uid_valid=0;config_initialized=0;config_valid=0;config_data=0;config_error=0;save_ready=0;done_valid=0;nfc_ready=1;nfc_fault=0;card_present=0;ticks(3);rst_n=1;ticks(3);end endtask
 task initialize(input bit valid,input [255:0] data,input [7:0] error_code);begin @(negedge clk);config_data=data;config_valid=valid;config_error=error_code;config_initialized=1;ticks(3);end endtask
 task choose(input integer n);begin while(selection!=n)press(4'b0100);end endtask
 initial begin
  reset();page(1);press(8);ck(notice==12&&!learning&&!save_valid,"commands wait for configuration initialization");
  initialize(0,0,0);ck(card_enabled==0&&!voice_enabled&&!dirty,"blank initialization has inert defaults");
  press(8);ck(learning&&notice==1,"KEY4 starts explicit registration");
  present(UID4,5);ck(card_enabled==0&&learning&&notice==15,"invalid length cannot register");
  present(UID4|80'hffffffffffff00000000,4);ck(card_enabled==1&&card_lengths[3:0]==4&&card_uids[79:0]==UID4&&dirty&&!learning,"registration canonicalizes unused UID bytes");
  ck(events==0,"registration never emits game action");
  choose(1);press(8);present(UID4,4);ck(notice==4&&learning&&card_enabled==1,"same UID in another slot is rejected");
  present(UID7,7);ck(card_enabled==3&&card_uids[159:80]==UID7&&card_lengths[7:4]==7&&!learning,"seven-byte second slot");
  choose(2);press(8);present(UID10,10);ck(card_enabled==7&&card_uids[239:160]==UID10&&card_lengths[11:8]==10,"ten-byte third slot");
  ck(events==0,"all registration actions remain isolated from application");
  choose(0);press(8);ticks(42);ck(!learning&&notice==5,"registration deadline expires");
  present(UID10,10);ck(card_uids[79:0]==UID4&&events==0,"late scan cannot register or act in settings");
  press(8);ck(learning,"registration can restart");page(0);present(UID7,7);ck(!learning&&events==1&&last_action==2,"leaving cancels registration and later independent scan may act");
  present(UID4^1,4);ck(events==1&&notice==6,"unknown card yields feedback only");
  present(UID10^80'h01000000000000000000,10);ck(events==1,"long UID high-byte mismatch is not a registered card");
  present(UID4,7);ck(events==1,"length participates in identity");
  present(UID4,4);ck(events==2&&last_action==1,"game card mapping");present(UID10,10);ck(events==3&&last_action==3,"history card mapping");
  page(1);choose(3);press(8);ck(voice_confirm&&!voice_enabled,"first voice enable press only asks confirmation");
  page(0);page(1);choose(3);ck(!voice_confirm&&!voice_enabled,"leaving cancels enable confirmation");
  press(8);press(8);ck(voice_enabled&&!voice_confirm&&dirty,"second explicit press enables configured voice");
  press(8);ck(!voice_enabled&&!voice_confirm&&notice==8,"enabled voice can be disabled with one press");
  press(8);press(4);ck(!voice_confirm&&!voice_enabled&&selection==4,"selection change cancels voice confirmation");
  press(8);ck(retries==1&&notice==11&&!learning,"NFC retry is a one-cycle explicit pulse");
  ticks(3);ck(retries==1,"retry does not repeat without key");
  nfc_ready=0;choose(0);press(8);ck(!learning&&notice==14,"registration requires an available NFC link");nfc_ready=1;
  choose(5);press(8);snapshot={voice_enabled,card_enabled,card_lengths,card_uids};
  ck(saving&&busy&&save_valid&&save_data==snapshot&&!done_ready,"save captures atomic runtime settings");
  press(4);present(UID4,4);ck(saving&&selection==5&&save_data==snapshot&&save_valid,"save backpressure keeps snapshot and UI stable");
  page(0);ck(saving&&save_valid&&save_data==snapshot,"leaving page cannot cancel in-flight save");
  @(negedge clk);save_ready=1;ticks(1);save_ready=0;ticks(1);ck(!save_valid&&saving&&done_ready,"save request accepted once, awaits completion");
  @(negedge clk);done_error=8'h31;done_valid=1;ticks(1);done_valid=0;ticks(1);ck(!saving&&dirty&&notice==10,"failed save preserves unsaved dirty state");
  page(1);choose(5);press(8);@(negedge clk);save_ready=1;ticks(1);save_ready=0;ticks(1);
  @(negedge clk);done_error=0;done_valid=1;ticks(1);done_valid=0;ticks(1);ck(!saving&&!dirty&&notice==9,"successful save clears dirty after completion");
  // A page transition during the comparison pipeline discards the scan.
  old_events=events;page(0);@(negedge clk);uid=UID4;uid_length=4;uid_valid=1;ticks(1);uid_valid=0;settings_active=1;ticks(4);
  ck(events==old_events&&!learning,"page transition cancels in-flight card recognition");
  // A physical key during matching must win, not delay the scan into a later cycle.
  page(0);@(negedge clk);uid=UID4;uid_length=4;uid_valid=1;ticks(1);uid_valid=0;key_press=1;ticks(1);key_press=0;ticks(4);
  ck(events==old_events,"physical key cancels rather than defers in-flight card action");
  // Initial records must reject invalid or ambiguous enabled identities.
  reset();snapshot=0;snapshot[79:0]=UID4;snapshot[243:240]=5;snapshot[252]=1;snapshot[255]=1;initialize(1,snapshot,0);
  ck(card_enabled==0&&!voice_enabled&&notice==13,"invalid enabled UID length rejects whole startup record");
  reset();snapshot=0;snapshot[79:0]=UID4;snapshot[159:80]=UID4;snapshot[247:240]=8'h44;snapshot[253:252]=3;initialize(1,snapshot,0);
  ck(card_enabled==0&&!voice_enabled&&notice==13,"duplicate enabled identities reject whole startup record");
  reset();snapshot=0;snapshot[79:0]=UID4;snapshot[159:80]=UID7;snapshot[239:160]=UID10;snapshot[251:240]=12'ha74;snapshot[255:252]=4'hf;initialize(1,snapshot,0);
  ck(card_enabled==7&&card_lengths==12'ha74&&card_uids==snapshot[239:0]&&voice_enabled&&!dirty,"valid startup record restores all three full UIDs and confirmation");
  config_data=0;ticks(3);ck(card_enabled==7&&voice_enabled,"startup configuration loads exactly once");
  reset();initialize(0,0,8'h12);ck(card_enabled==0&&!voice_enabled&&notice==13,"storage error keeps safe defaults visible");
  $display("PASS_SETTINGS checks=%0d card_events=%0d",checks,events);$finish;
 end
 initial begin #2000000;$fatal(1,"settings watchdog");end
endmodule
`default_nettype wire
