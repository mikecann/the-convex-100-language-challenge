livetest ; Live subscribe/waitUpdate tests against a local fixture sync peer.
 ;
 ; fixture.m's "sync" role completes the WebSocket handshake, reads the
 ; client's Connect and initial Add, and then pushes two Transitions the
 ; client never polled for -- proving waitUpdate actually observes
 ; server-initiated pushes, not just responses to something it sent.
 ;
main
 new port,failures
 set port=$piece($zcmdline," ",1)
 set failures=0
 ;
 if '$$open^convex("http://127.0.0.1:"_port,"mumps-live-test-0.1.0") do
 . write "OPEN FAILED: ",$$errorMessage^convex(),!
 . set failures=failures+1
 quit:failures>0
 ;
 if '$$subscribe^convex("counter","fixture:sub","{}") do
 . write "SUBSCRIBE FAILED: ",$$errorName^convex(),": ",$$errorMessage^convex(),!
 . set failures=failures+1
 quit:failures>0
 ;
 new hasError,errName,errMsg,value
 if '$$waitUpdate^convex("counter",8000,.hasError,.errName,.errMsg,.value) do
 . write "FIRST WAIT FAILED: ",$$errorMessage^convex(),!
 . set failures=failures+1
 else  if hasError do
 . write "FIRST VALUE WAS AN ERROR: ",errName,"/",errMsg,!
 . set failures=failures+1
 else  do
 . write "first live value: ",value,!
 . if value'="{""count"":5}" write "FIRST VALUE MISMATCH",! set failures=failures+1
 ;
 new hasError2,errName2,errMsg2,value2
 if '$$waitUpdate^convex("counter",8000,.hasError2,.errName2,.errMsg2,.value2) do
 . write "SECOND WAIT FAILED: ",$$errorMessage^convex(),!
 . set failures=failures+1
 else  if hasError2 do
 . write "SECOND VALUE WAS AN ERROR: ",errName2,"/",errMsg2,!
 . set failures=failures+1
 else  do
 . write "second live value: ",value2,!
 . if value2'="{""count"":6}" write "SECOND VALUE MISMATCH",! set failures=failures+1
 ;
 do closeLive^convex(2000)
 if failures=0 write "ALL LIVE TESTS PASSED",!
 else  write failures," FAILURES",!
 zhalt $select(failures=0:0,1:1)
