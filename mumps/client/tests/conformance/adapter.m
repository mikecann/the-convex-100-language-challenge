adapter ; NDJSON adapter protocol v1 for the shared conformance controller.
 ;
 ; Test infrastructure, not public client code: it wraps client/convex.m and
 ; speaks the shared harness's line-oriented protocol over stdin/stdout, or
 ; over a single TCP connection when ADAPTER_LISTEN names a listen address.
 ; Reserves stdout (or the controller socket) for protocol events; every
 ; diagnostic goes to stderr. It is single threaded, so the main loop
 ; interleaves pumping the Live socket with reading one controller command at
 ; a time -- the same shape client/convex.m's own single-owner design expects.
 ;
main
 do setup^convex
 do adSetup
 do adOpenStderr
 new url set url=$$getenv("CONVEX_URL")
 if url="" do  quit
 . do adDiag("CONVEX_URL is required")
 new opened set opened=$$open^convex(url,"native-mumps-0.1.0")
 ;
 do adOpenIo
 ;
 for  quit:adDone  do
 . new pumpDeadline set pumpDeadline=$$nowMs^convex()+15
 . new discard set discard=$$livePump^convex($$adRemaining(pumpDeadline))
 . do adPublishSubscriptions
 . new line set line=""
 . new readDeadline set readDeadline=$$nowMs^convex()+15
 . new outcome set outcome=$$adReadCommand($$adRemaining(readDeadline),.line)
 . if outcome="ok" do adDispatch(line)
 . if (outcome="eof")!(outcome="error") set adDone=1
 . do adFlush
 do closeLive^convex(500)
 quit
 ;
getenv(name)
 quit $ztrnlnm(name)
 ;
adOpenStderr
 open "/dev/stderr":append:5
 quit
 ;
adDiag(message)
 use "/dev/stderr"
 write message,!
 use $principal
 quit
 ;
adRemaining(deadline)
 new left set left=deadline-$$nowMs^convex()
 quit $select(left<0:0,1:left)
 ;
 ; ===========================================================================
 ; Setup, transport, and the bounded output queue
 ; ===========================================================================
 ;
adSetup
 set adDone=0
 set adQueueHead=1,adQueueTail=0,adQueueBytes=0
 set adQueueCount=8,adQueueMaxBytes=4194304
 set adBuf=""
 kill adSubOf,adTagOf
 quit
 ;
adOpenIo
 new listen set listen=$$getenv("ADAPTER_LISTEN")
 if listen="" set adIo=$principal,adIsSocket=0 quit
 new port,colon
 set colon=$find(listen,":")
 set port=$select(colon=0:listen,1:$extract(listen,colon,$length(listen)))
 set adIo="adln"
 set adIsSocket=1
 open adIo:(listen=port_":TCP":attach=adIo):5:"SOCKET"
 use adIo
 write /wait(120)
 use $principal
 if '$test do adDiag("no controller connected within 120s") set adDone=1
 quit
 ;
 ; A SOCKET device is an undelimited byte stream, so a command line is
 ; assembled from a byte buffer scanned for the next newline. A PIPE/TERM
 ; $PRINCIPAL, by contrast, already returns one record (one line, newline
 ; stripped) per READ, so it is read directly instead.
adReadCommand(timeoutMs,line)
 new deadline set deadline=$$nowMs^convex()+timeoutMs
 if 'adIsSocket quit $$adReadCommandPipe(deadline,.line)
 new nl,outcome
 set nl=$find(adBuf,$char(10))
 for  quit:nl>0  do  quit:outcome'="ok"
 . set outcome=$$adFillBounded(deadline)
 . set nl=$find(adBuf,$char(10))
 if nl=0 quit $get(outcome,"timeout")
 set line=$extract(adBuf,1,nl-2)
 set adBuf=$extract(adBuf,nl+1,$length(adBuf))
 quit "ok"
 ;
adReadCommandPipe(deadline,line)
 new seconds,eof
 set line=""
 set seconds=$$adRemaining(deadline)/1000
 use adIo
 read line:seconds
 new sawTest set sawTest=$test
 set eof=$zeof
 use $principal
 if line'="" quit "ok"
 if eof quit "eof"
 if 'sawTest quit "timeout"
 quit "ok"
 ;
adFillBounded(deadline)
 new seconds,data,outcome
 set seconds=$$adRemaining(deadline)/1000
 use adIo
 read data:seconds
 new sawTest set sawTest=$test
 new eof set eof=$zeof
 use $principal
 if data'="" set adBuf=adBuf_data quit "ok"
 if eof quit "eof"
 if 'sawTest quit "timeout"
 quit "ok"
 ;
adWriteRaw(text)
 use adIo
 write text,$char(10)
 use $principal
 quit
 ;
 ; ===========================================================================
 ; The bounded delivery queue. Subscription events are droppable (oldest
 ; first); hello/result/error/ack/closed responses are not, and if the
 ; budget cannot be freed without dropping one, the adapter fails loudly
 ; instead of growing past the shared 128 MiB adapter limit.
 ; ===========================================================================
 ;
adEmit(text,droppable)
 new charge set charge=$length(text)+64
 for  quit:(adQueueBytes+charge)<=adQueueMaxBytes&((adQueueTail-adQueueHead+1)<adQueueCount)  quit:'$$adDropOldest()
 if (adQueueBytes+charge)>adQueueMaxBytes!((adQueueTail-adQueueHead+1)>=adQueueCount) do  quit
 . if 'droppable do
 . . do adDiag("output budget exhausted by undroppable responses")
 . . set adDone=1
 set adQueueTail=adQueueTail+1
 set adQueue(adQueueTail)=text,adQueueDroppable(adQueueTail)=droppable
 set adQueueBytes=adQueueBytes+charge
 quit
 ;
 ; Drop the oldest droppable entry to make room; returns 0 if nothing
 ; droppable remains.
adDropOldest()
 new i,found
 set found=""
 for i=adQueueHead:1:adQueueTail do  quit:found'=""
 . if $get(adQueueDroppable(i))=1 set found=i
 if found="" quit 0
 do adQueueRemove(found)
 quit 1
 ;
adQueueRemove(i)
 new charge set charge=$length(adQueue(i))+64
 set adQueueBytes=adQueueBytes-charge
 kill adQueue(i),adQueueDroppable(i)
 if i=adQueueHead set adQueueHead=adQueueHead+1
 quit
 ;
adFlush
 for  quit:adQueueHead>adQueueTail  do
 . if '$data(adQueue(adQueueHead)) set adQueueHead=adQueueHead+1 quit
 . do adWriteRaw(adQueue(adQueueHead))
 . do adQueueRemove(adQueueHead)
 quit
 ;
 ; ===========================================================================
 ; Event construction. Optional fields are omitted rather than serialized
 ; as null, matching the shared adapter schema.
 ; ===========================================================================
 ;
adReady(id)
 quit "{""protocolVersion"":1,""id"":"_$$jQuote^convex(id)_",""type"":""ready"",""language"":""mumps"",""implementation"":"_$$jQuote^convex("native-mumps-0.1.0")_",""runtime"":"_$$jQuote^convex($$runtimeVersion^convex())_"}"
 ;
adResult(id,value,logs)
 quit "{""id"":"_$$jQuote^convex(id)_",""type"":""result"",""value"":"_value_",""logs"":"_$select(logs="":"[]",1:logs)_"}"
 ;
adErrorObject(name,message,data)
 quit "{""name"":"_$$jQuote^convex(name)_",""message"":"_$$jQuote^convex(message)_",""data"":"_$select(data="":"null",1:data)_"}"
 ;
adError(id,name,message,data)
 new idPart set idPart=$select(id="":"",1:"""id"":"_$$jQuote^convex(id)_",")
 quit "{"_idPart_"""type"":""error"",""error"":"_$$adErrorObject(name,message,data)_"}"
 ;
adAck(id)
 quit "{""id"":"_$$jQuote^convex(id)_",""type"":""ack""}"
 ;
adClosed(id)
 quit "{""id"":"_$$jQuote^convex(id)_",""type"":""closed""}"
 ;
adSubscriptionValue(subId,value,logs)
 quit "{""type"":""subscription"",""subscriptionId"":"_$$jQuote^convex(subId)_",""value"":"_value_",""logs"":"_$select(logs="":"[]",1:logs)_"}"
 ;
adSubscriptionError(subId,name,message,data,logs)
 new logsPart set logsPart=$select((logs="")!(logs="[]"):"",1:",""logs"":"_logs)
 quit "{""type"":""subscription"",""subscriptionId"":"_$$jQuote^convex(subId)_",""error"":"_$$adErrorObject(name,message,data)_logsPart_"}"
 ;
 ; ===========================================================================
 ; Dispatch
 ; ===========================================================================
 ;
adDispatch(line)
 new mark,root,id,op
 set mark=$$jMark^convex()
 set root=$$jParse^convex(line)
 if root<0!($$jType^convex(root)'="object") do  do jRelease^convex(mark) quit
 . do adEmit($$adError("","ProtocolError","the controller sent invalid JSON","null"),0)
 ;
 new idNode set idNode=$$jFind^convex(root,"id")
 set id=$select(idNode>=0&($$jType^convex(idNode)="string"):$$jText^convex(idNode),1:"")
 new opNode set opNode=$$jFind^convex(root,"op")
 set op=$select(opNode>=0&($$jType^convex(opNode)="string"):$$jText^convex(opNode),1:"")
 ;
 if op="hello" do  do jRelease^convex(mark) quit
 . do adEmit($$adReady(id),0)
 if (op="query")!(op="mutation")!(op="action") do  do jRelease^convex(mark) quit
 . do adCall(id,op,root)
 if op="subscribe" do  do jRelease^convex(mark) quit
 . do adSubscribe(id,root)
 if op="unsubscribe" do  do jRelease^convex(mark) quit
 . do adUnsubscribe(id,root)
 if op="setAuth" do  do jRelease^convex(mark) quit
 . do adSetAuth(id,root)
 if op="debugDisconnect" do  do jRelease^convex(mark) quit
 . do liveRetire^convex("TransportError","debugDisconnect")
 . do adEmit($$adAck(id),0)
 if op="close" do  do jRelease^convex(mark) quit
 . do closeLive^convex(1000)
 . do adEmit($$adClosed(id),0)
 . set adDone=1
 do jRelease^convex(mark)
 do adEmit($$adError(id,"ProtocolError","command does not match adapter protocol v1","null"),0)
 quit
 ;
adCall(id,op,root)
 new pathNode,argsNode,path,args,result
 set pathNode=$$jFind^convex(root,"path")
 set argsNode=$$jFind^convex(root,"args")
 if pathNode<0!($$jType^convex(pathNode)'="string")!(argsNode<0) do  quit
 . do adEmit($$adError(id,"ProtocolError","command does not match adapter protocol v1","null"),0)
 set path=$$jText^convex(pathNode)
 set args=$$jEncode^convex(argsNode)
 new ok
 if op="query" set ok=$$query^convex(path,args,.result)
 if op="mutation" set ok=$$mutation^convex(path,args,.result)
 if op="action" set ok=$$action^convex(path,args,.result)
 if ok do  quit
 . do adEmit($$adResult(id,result("value"),result("logs")),0)
 do adEmit($$adError(id,$$errorName^convex(),$$errorMessage^convex(),$$errorData^convex()),0)
 quit
 ;
adSubscribe(id,root)
 new subIdNode,pathNode,argsNode,subId,path,args,ok
 set subIdNode=$$jFind^convex(root,"subscriptionId")
 set pathNode=$$jFind^convex(root,"path")
 set argsNode=$$jFind^convex(root,"args")
 if subIdNode<0!($$jType^convex(subIdNode)'="string")!(pathNode<0)!($$jType^convex(pathNode)'="string")!(argsNode<0) do  quit
 . do adEmit($$adError(id,"ProtocolError","command does not match adapter protocol v1","null"),0)
 set subId=$$jText^convex(subIdNode),path=$$jText^convex(pathNode)
 set args=$$jEncode^convex(argsNode)
 set ok=$$subscribe^convex(subId,path,args)
 if ok do  set adSubOf(subId)=1 quit
 . do adEmit($$adAck(id),0)
 do adEmit($$adError(id,$$errorName^convex(),$$errorMessage^convex(),$$errorData^convex()),0)
 quit
 ;
adUnsubscribe(id,root)
 new subIdNode,subId,ok
 set subIdNode=$$jFind^convex(root,"subscriptionId")
 if subIdNode<0!($$jType^convex(subIdNode)'="string") do  quit
 . do adEmit($$adError(id,"ProtocolError","command does not match adapter protocol v1","null"),0)
 set subId=$$jText^convex(subIdNode)
 set ok=$$unsubscribe^convex(subId)
 kill adSubOf(subId),adDeliveredVersion(subId)
 do adEmit($$adAck(id),0)
 quit
 ;
adSetAuth(id,root)
 new tokenNode,token,ok
 set tokenNode=$$jFind^convex(root,"token")
 if tokenNode<0!($$jType^convex(tokenNode)'="string") do  quit
 . do adEmit($$adError(id,"ProtocolError","command does not match adapter protocol v1","null"),0)
 set token=$$jText^convex(tokenNode)
 set ok=$$setAuth^convex(token)
 do adEmit($$adAck(id),0)
 quit
 ;
 ; Publish any subscription whose delivered version is behind its latest
 ; value or error. Runs every pass through the main loop.
adPublishSubscriptions
 new subId
 set subId=""
 for  set subId=$order(adSubOf(subId)) quit:subId=""  do
 . if '$data(tagToQid(subId)) quit
 . new qid set qid=tagToQid(subId)
 . new latest set latest=$get(subVersion(qid),0)
 . new delivered set delivered=$get(adDeliveredVersion(subId),0)
 . if latest<=delivered quit
 . set adDeliveredVersion(subId)=latest
 . if $data(subErrName(qid)) do  quit
 . . do adEmit($$adSubscriptionError(subId,subErrName(qid),subErrMsg(qid),$get(subErrData(qid),"null"),$get(subLogs(qid),"[]")),1)
 . do adEmit($$adSubscriptionValue(subId,subValue(qid),$get(subLogs(qid),"[]")),1)
 quit
