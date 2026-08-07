fixture ; Local network peer for httptest and livetest.
 ;
 ; httptest and livetest need something on the other end of a real TCP
 ; connection: a peer that actually completes an HTTP exchange or an RFC 6455
 ; WebSocket handshake, so a bug in the client's own socket/framing code
 ; cannot pass by talking only to itself. This program is that peer. It is
 ; test infrastructure, not client code, but it deliberately reuses
 ; client/convex.m's own socket, JSON, and crypto primitives rather than
 ; reimplementing them -- the client's HTTP/WebSocket transport is what is
 ; under test here, not this fixture's.
 ;
 ; Each role listens on 127.0.0.1:<port>, accepts exactly one connection, runs
 ; a short scripted exchange, and exits. The test driver starts one fixture
 ; process per expected connection in the background and then runs the
 ; matching *test routine in the foreground; see the Dockerfile.
 quit
 ;
main
 do setup^convex
 new role set role=$piece($zcmdline," ",1)
 if role="http" do http($piece($zcmdline," ",2),$piece($zcmdline," ",3)) quit
 if role="sync" do sync($piece($zcmdline," ",2)) quit
 use "/dev/stderr" write "fixture: unknown role """,role,"""",! use $principal
 zhalt 1
 ;
 ; Accepts one connection on `port` and returns its socket handle, or "" on
 ; failure. This is the same OPEN-then-WRITE-/WAIT-then-reuse-the-same-handle
 ; pattern client/tests/conformance/adapter.m uses for ADAPTER_LISTEN: the
 ; listener device becomes the accepted connection's device in place, no
 ; separate handle needed.
accept(port)
 new conn set conn="fx"
 open conn:(listen=port_":TCP":attach=conn):5:"SOCKET"
 use conn
 write /wait(30)
 new accepted set accepted=$test
 use $principal
 if 'accepted quit ""
 quit conn
 ;
 ; ===========================================================================
 ; HTTP role: read one request (headers, plus any declared body) and answer
 ; with a canned response.
 ; ===========================================================================
 ;
http(port,scenario)
 new conn set conn=$$accept(port)
 if conn="" halt
 new deadline set deadline=$$nowMs^convex()+15000
 new buffer,headerEnd,outcome,chunk
 set buffer="",headerEnd=0
 for  quit:headerEnd>0  quit:headerEnd<0  do
 . set outcome=$$sockRead^convex(conn,65536,$$remaining^convex(deadline),.chunk)
 . if outcome="ok" set buffer=buffer_chunk,headerEnd=$find(buffer,$char(13,10,13,10)) quit
 . set headerEnd=-1
 if headerEnd>0 do
 . ; Drain any declared request body so the peer's write is never refused
 . ; mid-stream; the body's content is not asserted on here, only its shape
 . ; (the request path/args) is -- and that is exercised end to end by
 . ; ./run verify-example and ./run verify against the real backend.
 . new headers set discard=$$parseHeaders^convex($extract(buffer,1,headerEnd-5),.headers)
 . new need set need=$get(headers("content-length"),0)+0
 . new have set have=$length(buffer)-headerEnd+1
 . for  quit:have>=need  quit:outcome'="ok"  do
 . . set outcome=$$sockRead^convex(conn,65536,2000,.chunk)
 . . if outcome="ok" set buffer=buffer_chunk,have=have+$length(chunk)
 ;
 new statusLine,body
 if scenario="query" set statusLine="200 OK",body="{""status"":""success"",""value"":{""count"":5},""logLines"":[""fixture query""]}"
 else  if scenario="mutation" set statusLine="200 OK",body="{""status"":""success"",""value"":{""applied"":true,""state"":{""count"":6}},""logLines"":[""fixture mutation""]}"
 else  set statusLine="200 OK",body="{""status"":""error"",""errorMessage"":""fixture failure"",""errorData"":{""code"":""boom""},""logLines"":[""fixture error""]}"
 ;
 new response set response="HTTP/1.1 "_statusLine_$char(13,10)
 set response=response_"Content-Type: application/json"_$char(13,10)
 set response=response_"Content-Length: "_$length(body)_$char(13,10)
 set response=response_"Connection: close"_$char(13,10,13,10)_body
 new wok set wok=$$sockWrite^convex(conn,response,5000)
 do sockClose^convex(conn)
 halt
 ;
 ; ===========================================================================
 ; Sync role: complete the WebSocket handshake, read the client's Connect and
 ; ModifyQuerySet, then push two Transitions the client did not ask for by
 ; polling -- proving the Live path delivers server-initiated updates, not
 ; just responses to requests.
 ; ===========================================================================
 ;
sync(port)
 new conn set conn=$$accept(port)
 if conn="" halt
 set fxBuf=""
 new deadline set deadline=$$nowMs^convex()+15000
 if '$$fxHandshake(conn,deadline) do sockClose^convex(conn) halt
 ;
 new opcode,payload,outcome
 set outcome=$$fxRecv(conn,deadline,.opcode,.payload) ; Connect
 if outcome'="ok" do sockClose^convex(conn) halt
 set outcome=$$fxRecv(conn,deadline,.opcode,.payload) ; ModifyQuerySet (Add)
 if outcome'="ok" do sockClose^convex(conn) halt
 ;
 new root,mods,first,qidNode,qid
 set root=$$jParse^convex(payload)
 set mods=$$jFind^convex(root,"modifications")
 set first=$$jChild^convex(mods,1)
 set qidNode=$$jFind^convex(first,"queryId")
 set qid=$$jText^convex(qidNode)
 if qid="" do sockClose^convex(conn) halt
 ;
 new ts1,ts2
 set ts1=$$b64Encode^convex($char(0,0,0,0,0,0,0,1))
 set ts2=$$b64Encode^convex($char(0,0,0,0,0,0,0,2))
 ;
 new t1 set t1="{""type"":""Transition"",""startVersion"":{""querySet"":0,""identity"":0,""ts"":""AAAAAAAAAAA=""},""endVersion"":{""querySet"":1,""identity"":0,""ts"":"""_ts1_"""},""modifications"":[{""type"":""QueryUpdated"",""queryId"":"_qid_",""value"":{""count"":5},""logLines"":[]}]}"
 new sendOk set sendOk=$$fxSend(conn,1,t1)
 ;
 hang 0.2 ; gives the client a real chance to be blocked in a read, not just polling
 ;
 new t2 set t2="{""type"":""Transition"",""startVersion"":{""querySet"":1,""identity"":0,""ts"":"""_ts1_"""},""endVersion"":{""querySet"":2,""identity"":0,""ts"":"""_ts2_"""},""modifications"":[{""type"":""QueryUpdated"",""queryId"":"_qid_",""value"":{""count"":6},""logLines"":[]}]}"
 set sendOk=$$fxSend(conn,1,t2)
 ;
 ; The client closes when the test tears the subscription down; answer its
 ; close frame if it arrives before the deadline, then close either way.
 set outcome=$$fxRecv(conn,deadline,.opcode,.payload)
 if outcome="ok",opcode=8 do
 . new discard set discard=$$fxSend(conn,8,"")
 do sockClose^convex(conn)
 halt
 ;
 ; Server-side half of the RFC 6455 handshake: read the upgrade request,
 ; answer with the Sec-WebSocket-Accept digest computed from the client's key.
fxHandshake(conn,deadline)
 new buffer,headerEnd,outcome,chunk,headers,key,accept,response
 set buffer="",headerEnd=0
 for  quit:headerEnd>0  quit:headerEnd<0  do
 . set outcome=$$sockRead^convex(conn,65536,$$remaining^convex(deadline),.chunk)
 . if outcome="ok" set buffer=buffer_chunk,headerEnd=$find(buffer,$char(13,10,13,10)) quit
 . set headerEnd=-1
 if headerEnd<0 quit 0
 new ok set ok=$$parseHeaders^convex($extract(buffer,1,headerEnd-5),.headers)
 if 'ok quit 0
 set key=$get(headers("sec-websocket-key"))
 if key="" quit 0
 set accept=$$b64Encode^convex($$sha1^convex(key_$$wsGuid^convex()))
 set response="HTTP/1.1 101 Switching Protocols"_$char(13,10)
 set response=response_"Upgrade: websocket"_$char(13,10)
 set response=response_"Connection: Upgrade"_$char(13,10)
 set response=response_"Sec-WebSocket-Accept: "_accept_$char(13,10,13,10)
 new wok set wok=$$sockWrite^convex(conn,response,5000)
 set fxBuf=$extract(buffer,headerEnd,$length(buffer))
 quit 1
 ;
 ; Server frames are unmasked (the mirror image of client/convex.m's
 ; wsReadFrame, which reads unmasked server frames); every message the client
 ; sends is a single unfragmented frame (see convex.m's wsSend), so no
 ; continuation-frame reassembly is needed here.
fxFill(conn,need,deadline)
 new outcome,chunk
 for  quit:$length(fxBuf)>=need  do  quit:outcome'="ok"
 . set outcome=$$sockRead^convex(conn,65536,$$remaining^convex(deadline),.chunk)
 . if outcome="ok" set fxBuf=fxBuf_chunk
 if $length(fxBuf)>=need quit "ok"
 quit outcome
 ;
fxRecv(conn,deadline,opcode,payload)
 new outcome,b0,b1,lenField,extra,maskBytes,masked,i
 set payload=""
 set outcome=$$fxFill(conn,2,deadline)
 if outcome'="ok" quit outcome
 set b0=$ascii(fxBuf,1),b1=$ascii(fxBuf,2)
 set opcode=b0#16
 set lenField=b1#128
 set extra=2
 if lenField=126 do
 . set outcome=$$fxFill(conn,4,deadline)
 . if outcome="ok" set lenField=($ascii(fxBuf,3)*256)+$ascii(fxBuf,4),extra=4
 else  if lenField=127 quit "error" ; the fixture never expects a frame this large
 if outcome'="ok" quit outcome
 set outcome=$$fxFill(conn,extra+4+lenField,deadline)
 if outcome'="ok" quit outcome
 set maskBytes=$extract(fxBuf,extra+1,extra+4)
 set masked=$extract(fxBuf,extra+5,extra+4+lenField)
 set fxBuf=$extract(fxBuf,extra+4+lenField+1,$length(fxBuf))
 set payload=""
 for i=1:1:lenField do
 . new mb set mb=$ascii(maskBytes,((i-1)#4)+1)
 . set payload=payload_$char($$bxor^convex($ascii(masked,i),mb))
 quit "ok"
 ;
fxSend(conn,opcode,payload)
 new frame,lengthField,n
 set n=$length(payload)
 set frame=$char(128+opcode)
 if n<126 set lengthField=$char(n)
 else  if n<65536 set lengthField=$char(126)_$char((n\256)#256)_$char(n#256)
 else  set lengthField=$char(127)_$char(0)_$char(0)_$char(0)_$char(0)_$char((n\16777216)#256)_$char((n\65536)#256)_$char((n\256)#256)_$char(n#256)
 set frame=frame_lengthField_payload
 quit $$sockWrite^convex(conn,frame,5000)
