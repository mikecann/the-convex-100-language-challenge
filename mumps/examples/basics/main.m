main ; Convex from MUMPS: the shared counter journey.
 ;
 ; The program reads a room's counter over Convex's documented HTTP API,
 ; starts a Live subscription, increments the counter once, and proves that
 ; the Live subscription reported the same change without polling.
 ;
 ; Run it with: CONVEX_URL=https://<deployment>.convex.cloud mumps -run main^main <room>
 ;
 do setup^convex
 new status set status=$$run()
 zhalt $select(status=0:0,1:1)
 ;
run()
 new url,room,args,current,initial,updated,expected
 new q set q=$char(34)
 ;
 ; Configuration: the deployment URL is required; the room comes from the
 ; verifier's first command-line argument, an environment variable for a
 ; convenient hand run, or a literal fallback so the example still does
 ; something when run with neither.
 set url=$ztrnlnm("CONVEX_URL")
 if url="" write "MUMPS example failed: CONVEX_URL is required",! quit 1
 set room=$piece($zcmdline," ",1)
 if room="" set room=$ztrnlnm("EXAMPLE_ROOM")
 if room="" set room="mumps-example"
 ;
 ; Client creation: one native MUMPS client for the deployment the container
 ; names. `open` resolves the URL and mints a fresh Live session id; nothing
 ; has touched the network yet.
 if '$$open^convex(url,"mumps-0.1.0") quit $$bail($$errorMessage^convex())
 set args="{"_q_"room"_q_":"_q_room_q_"}"
 ;
 ; Read the current value through Convex's documented HTTP query endpoint.
 new response
 if '$$query^convex("demo:state",args,.response) quit $$bail("query: "_$$errorMessage^convex())
 set current=$$count(response("value"),"current query")
 if current=-1 quit $$bail("")
 write "current count: ",current,!
 ;
 ; Start Live before mutating. Subscribing first is what makes the update
 ; below an observation rather than a race.
 if '$$subscribe^convex("counter","demo:state",args) quit $$bail("subscribe: "_$$errorMessage^convex())
 ;
 ; The first Live value hydrates the same state the HTTP query returned.
 set initial=$$next("initial Live value")
 if initial=-1 quit $$bail("")
 if initial'=current quit $$bail("the initial Live count disagreed with HTTP")
 write "live initial count: ",initial,!
 ;
 ; runId is the mutation's idempotency key. Convex records it, so a repeated
 ; run of the same key returns the previous result instead of incrementing
 ; twice. A fresh random key means this run really applies its increment.
 new mutation set mutation="{"_q_"room"_q_":"_q_room_q_","_q_"language"_q_":"_q_"mumps"_q_","_q_"runId"_q_":"_q_$$randomHex^convex(16)_q_"}"
 if '$$mutation^convex("demo:increment",mutation,.response) quit $$bail("mutation: "_$$errorMessage^convex())
 ;
 new mark,root,appliedNode,stateNode,applied,state
 set mark=$$jMark^convex()
 set root=$$jParse^convex(response("value"))
 set appliedNode=$select(root<0:-1,1:$$jFind^convex(root,"applied"))
 set stateNode=$select(root<0:-1,1:$$jFind^convex(root,"state"))
 set applied=$select(appliedNode>=0:$$jType^convex(appliedNode),1:"")
 set state=$select(stateNode>=0:$$jEncode^convex(stateNode),1:"")
 do jRelease^convex(mark)
 if applied'="true" quit $$bail("the mutation was not applied")
 ;
 set expected=current+1
 set state=$$count(state,"mutation")
 if state=-1 quit $$bail("")
 if state'=expected quit $$bail("the mutation returned an unexpected count")
 write "mutation applied: true",!
 write "mutation count: ",state,!
 ;
 ; Receive the same change over Live, without polling HTTP again.
 set updated=$$next("updated Live value")
 if updated=-1 quit $$bail("")
 if updated'=expected quit $$bail("the updated Live count disagreed with the mutation")
 write "live updated count: ",updated,!
 ;
 ; Every operation agreed before this proof line is printed.
 write "verified count: ",current," -> ",updated,!
 do closeLive^convex(2000)
 quit 0
 ;
 ; Wait for the next value this subscription publishes, and surface a
 ; reactive query failure as a failure rather than as a missing value.
next(operation)
 new hasError,errName,errMsg,value
 if '$$waitUpdate^convex("counter",15000,.hasError,.errName,.errMsg,.value) quit $$bail(operation_": "_$$errorMessage^convex())
 if hasError quit $$bail(operation_": "_errMsg)
 quit $$count(value,operation)
 ;
 ; Convex returns the room state as a JSON object. This narrows it to the
 ; non-negative integer the output contract needs, and refuses anything else.
count(value,operation)
 new mark,root,node,literal,result
 set mark=$$jMark^convex()
 set root=$$jParse^convex(value)
 if root<0!($$jType^convex(root)'="object") do  quit -1
 . do jRelease^convex(mark)
 . new discard set discard=$$bail(operation_" did not return a Convex object")
 set node=$$jFind^convex(root,"count")
 if node<0!($$jType^convex(node)'="number") do  quit -1
 . do jRelease^convex(mark)
 . new discard set discard=$$bail(operation_" returned no count")
 set literal=$$jText^convex(node)
 do jRelease^convex(mark)
 ; Convex JSON may encode an integral number as 0 or as 0.0. Both are
 ; accepted; fractional, non-finite, and out-of-range values are not.
 if '$$integral^convex(literal)!(literal<0) quit $$bail(operation_" returned a non-integral or negative count")
 quit literal+0
 ;
 ; One failure channel. Diagnostics belong on stderr so that stdout stays the
 ; exact shared transcript.
bail(message)
 do closeLive^convex(2000)
 ; `/dev/stderr` is a Unix path, not automatically an M device. The final
 ; image deliberately has no `/tmp`; a hosted transport failure used to reach
 ; this branch and then fatal with IONOTOPEN before it could print its real
 ; diagnostic. Open the already-mounted stderr stream first, just as the
 ; adapter does, so error handling remains safe in that stripped image.
 if message'="" open "/dev/stderr":append:5 use "/dev/stderr" write "MUMPS example failed: ",message,! use $principal
 quit -1
