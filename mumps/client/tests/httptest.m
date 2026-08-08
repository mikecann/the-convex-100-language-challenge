httptest ; HTTP query/mutation/structured-error tests against a local fixture peer.
 ;
 ; Each case talks to its own fixture.m process over a real 127.0.0.1 socket
 ; (see the Dockerfile), so this exercises the client's actual HTTP request
 ; framing and response parsing, not just its JSON codec.
 ;
main
 new port1,port2,port3,failures
 set port1=$piece($zcmdline," ",1)
 set port2=$piece($zcmdline," ",2)
 set port3=$piece($zcmdline," ",3)
 set failures=0
 ;
 if '$$open^convex("http://127.0.0.1:"_port1,"mumps-http-test-0.1.0") do
 . write "OPEN FAILED: ",$$errorMessage^convex(),!
 . set failures=failures+1
 else  do
 . new result
 . if '$$query^convex("fixture:query","{}",.result) do
 . . write "QUERY FAILED: ",$$errorName^convex(),": ",$$errorMessage^convex(),!
 . . set failures=failures+1
 . else  do
 . . write "query value: ",result("value"),!
 . . if result("value")'="{""count"":5}" write "QUERY VALUE MISMATCH",! set failures=failures+1
 . . if result("logs")'="[""fixture query""]" write "QUERY LOGS MISMATCH: ",result("logs"),! set failures=failures+1
 ;
 if '$$open^convex("http://127.0.0.1:"_port2,"mumps-http-test-0.1.0") do
 . write "OPEN FAILED: ",$$errorMessage^convex(),!
 . set failures=failures+1
 else  do
 . new result
 . if '$$mutation^convex("fixture:mutation","{}",.result) do
 . . write "MUTATION FAILED: ",$$errorName^convex(),": ",$$errorMessage^convex(),!
 . . set failures=failures+1
 . else  do
 . . write "mutation value: ",result("value"),!
 . . if result("value")'="{""applied"":true,""state"":{""count"":6}}" write "MUTATION VALUE MISMATCH",! set failures=failures+1
 ;
 if '$$open^convex("http://127.0.0.1:"_port3,"mumps-http-test-0.1.0") do
 . write "OPEN FAILED: ",$$errorMessage^convex(),!
 . set failures=failures+1
 else  do
 . new result
 . if $$query^convex("fixture:fail","{}",.result) do
 . . write "EXPECTED FAILURE BUT SUCCEEDED",!
 . . set failures=failures+1
 . else  do
 . . write "structured error: ",$$errorName^convex()," / ",$$errorMessage^convex()," data=",$$errorData^convex(),!
 . . if $$errorName^convex()'="FunctionError" write "ERROR NAME MISMATCH",! set failures=failures+1
 . . if $$errorMessage^convex()'="fixture failure" write "ERROR MESSAGE MISMATCH",! set failures=failures+1
 . . if $$errorData^convex()'="{""code"":""boom""}" write "ERROR DATA MISMATCH",! set failures=failures+1
 ;
 if failures=0 write "ALL HTTP TESTS PASSED",!
 else  write failures," FAILURES",!
 zhalt $select(failures=0:0,1:1)
