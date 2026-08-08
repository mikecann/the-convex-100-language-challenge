convex ; Convex client for YottaDB M -- JSON, HTTP transport, and the Live sync
 ; protocol state machine. Everything below is M source: sockets are opened
 ; with the language's own OPEN/USE/READ/WRITE device syntax (device type
 ; "SOCKET"), never a foreign process. Session state (cxUrl, cxHost, cxToken,
 ; the JSON node pool, the Live subscription table) lives in routine-local M
 ; variables -- never in a `^global`, so the client never touches a database
 ; region and the runtime image can stay read-only.
 quit
 ;
 ; ===========================================================================
 ; Setup and error state
 ; ===========================================================================
 ;
setup ; idempotent one-time table build
 new i
 if $get(cxReady)=1 quit
 set cxReady=1
 set cxJNext=1
 set cxErrName="",cxErrMsg="",cxErrData="null"
 set cxJMaxBytes=1048576
 set cxJMaxDepth=128
 set cxJMaxNodes=8192
 set cxHttpMaxBody=1048576
 set cxHttpMaxHeaders=65536
 set cxWsMaxFrame=1048576
 set cxPow2(0)=1
 for i=1:1:56 set cxPow2(i)=cxPow2(i-1)*2
 set cxHexDigits="0123456789abcdef"
 for i=0:1:15 set cxHexVal($extract(cxHexDigits,i+1))=i
 for i=0:1:15 set cxHexVal($$upper($extract(cxHexDigits,i+1)))=i
 quit
 ;
upper(s) ; uppercase ascii letters only (avoids depending on $ZCONVERT locale)
 new r,i,c
 set r="",i=0
 for  set i=i+1 quit:i>$length(s)  do
 . set c=$ascii(s,i)
 . if c>96,c<123 set c=c-32
 . set r=r_$char(c)
 quit r
 ;
fail(name,message) ; record a structured client-side failure; always returns 0
 set cxErrName=name,cxErrMsg=message,cxErrData="null"
 quit 0
 ;
errorName() quit cxErrName
errorMessage() quit cxErrMsg
errorData() quit cxErrData
 ;
 ; ===========================================================================
 ; JSON: a node pool so nested documents can be inspected without re-parsing.
 ; Nodes allocate in order and release back to a mark, keeping long adapter
 ; runs bounded. jT(node)=type, jV(node)=text (raw literal for numbers, the
 ; already-decoded value for strings), jN(node)=child count, jC(node,i)=child
 ; node id, jK(node,i)=member key (objects only).
 ; ===========================================================================
 ;
jMark() quit cxJNext
 ;
jRelease(mark) ; drop every node allocated since mark
 new node,i
 for node=cxJNext-1:-1:mark do
 . for i=1:1:$get(jN(node)) kill jC(node,i),jK(node,i)
 . kill jT(node),jV(node),jN(node)
 set cxJNext=mark
 quit
 ;
jNode(type,value) ; allocate one node; -1 and cxErrMsg set if the pool is full
 new node
 if cxJNext>cxJMaxNodes do  quit -1
 . set cxErrMsg="JSON document exceeds "_cxJMaxNodes_" nodes"
 set node=cxJNext,cxJNext=cxJNext+1
 set jT(node)=type,jV(node)=value,jN(node)=0
 quit node
 ;
jType(node) quit jT(node)
jText(node) quit jV(node)
jCount(node) quit $get(jN(node))
 ;
jChild(node,position) ; 1-based
 if position<1!(position>$get(jN(node))) quit -1
 quit jC(node,position)
 ;
jKey(node,position) quit $get(jK(node,position))
 ;
jFind(node,key) ; object member lookup by exact key; -1 if absent or not object
 new position,result
 set result=-1
 if jT(node)'="object" quit -1
 for position=1:1:$get(jN(node)) if jK(node,position)=key set result=jC(node,position) quit
 quit result
 ;
 ; jParse(text) -> root node id, or -1 with cxJErr set describing why.
jParse(text)
 new root
 set cxJErr=""
 if $length(text)>cxJMaxBytes do  quit -1
 . set cxJErr="JSON input exceeds "_cxJMaxBytes_" bytes"
 set cxJSrc=text,cxJPos=1,cxJLen=$length(text),cxJDepth=0
 set root=$$jValue()
 if root<0 quit -1
 do jSkipSpace()
 if cxJPos<=cxJLen do  quit -1
 . set cxJErr="trailing content after the JSON value"
 quit root
 ;
jSkipSpace()
 new c
 for  do  quit:'$$isspace(c)
 . if cxJPos>cxJLen set c="" quit
 . set c=$extract(cxJSrc,cxJPos)
 . if $$isspace(c) set cxJPos=cxJPos+1
 quit
 ;
isspace(c) quit (c=" ")!(c=$char(9))!(c=$char(10))!(c=$char(13))
 ;
jValue()
 new c
 set cxJDepth=cxJDepth+1
 if cxJDepth>cxJMaxDepth do  set cxJDepth=cxJDepth-1 quit -1
 . set cxJErr="JSON nesting exceeds "_cxJMaxDepth_" levels"
 do jSkipSpace()
 if cxJPos>cxJLen do  set cxJDepth=cxJDepth-1 quit -1
 . set cxJErr="JSON value ended early"
 set c=$extract(cxJSrc,cxJPos)
 new result
 if c="{" set result=$$jObject()
 else  if c="[" set result=$$jArray()
 else  if c="""" set result=$$jStringNode()
 else  if c="t" set result=$$jLiteral("true","true")
 else  if c="f" set result=$$jLiteral("false","false")
 else  if c="n" set result=$$jLiteral("null","null")
 else  if (c="-")!(c?1n) set result=$$jNumber()
 else  do  set result=-1
 . set cxJErr="unexpected character in JSON value"
 set cxJDepth=cxJDepth-1
 quit result
 ;
jLiteral(word,type)
 new n
 set n=$length(word)
 if $extract(cxJSrc,cxJPos,cxJPos+n-1)'=word do  quit -1
 . set cxJErr="invalid JSON literal"
 set cxJPos=cxJPos+n
 quit $$jNode(type,word)
 ;
jNumber()
 new start,c,sawDigit
 set start=cxJPos
 if $extract(cxJSrc,cxJPos)="-" set cxJPos=cxJPos+1
 if cxJPos>cxJLen do  quit -1
 . set cxJErr="JSON number ended early"
 set c=$extract(cxJSrc,cxJPos)
 if c="0" set cxJPos=cxJPos+1
 else  if c?1n do
 . for  quit:cxJPos>cxJLen  quit:'($extract(cxJSrc,cxJPos)?1n)  set cxJPos=cxJPos+1
 else  do  set cxJPos=-1 quit
 . set cxJErr="invalid JSON number"
 if cxJPos<0 quit -1
 if $extract(cxJSrc,cxJPos)="." do
 . set cxJPos=cxJPos+1,sawDigit=0
 . for  quit:cxJPos>cxJLen  quit:'($extract(cxJSrc,cxJPos)?1n)  set cxJPos=cxJPos+1,sawDigit=1
 . if 'sawDigit set cxJPos=-1
 if cxJPos<0 do  quit -1
 . set cxJErr="invalid JSON number"
 if cxJPos<=cxJLen,(($extract(cxJSrc,cxJPos)="e")!($extract(cxJSrc,cxJPos)="E")) do
 . set cxJPos=cxJPos+1
 . if cxJPos<=cxJLen,(($extract(cxJSrc,cxJPos)="+")!($extract(cxJSrc,cxJPos)="-")) set cxJPos=cxJPos+1
 . set sawDigit=0
 . for  quit:cxJPos>cxJLen  quit:'($extract(cxJSrc,cxJPos)?1n)  set cxJPos=cxJPos+1,sawDigit=1
 . if 'sawDigit set cxJPos=-1
 if cxJPos<0 do  quit -1
 . set cxJErr="invalid JSON number exponent"
 quit $$jNode("number",$extract(cxJSrc,start,cxJPos-1))
 ;
jStringNode()
 new text
 set text=$$jReadString()
 if text=cxJStringError quit -1
 quit $$jNode("string",text)
 ;
 ; jReadString() consumes a JSON string literal at cxJPos (which must point at
 ; the opening quote) and returns the decoded byte string. On failure it
 ; returns the sentinel cxJStringError and sets cxJErr.
jReadString()
 new out,c,code,hi,lo,done
 set cxJStringError="<<json-string-error>>"
 if $extract(cxJSrc,cxJPos)'="""" do  quit cxJStringError
 . set cxJErr="expected a JSON string"
 set cxJPos=cxJPos+1,out="",done=0
 for  quit:done  quit:cxJPos>cxJLen  do
 . set c=$extract(cxJSrc,cxJPos)
 . if c="""" set cxJPos=cxJPos+1,done=1 quit
 . if c'="\" do  quit
 . . set code=$ascii(c)
 . . if code<32 set out=cxJStringError,done=1 quit
 . . set out=out_c,cxJPos=cxJPos+1
 . if c'="\" quit
 . ; c is a backslash: handle exactly one escape sequence
 . set cxJPos=cxJPos+1
 . if cxJPos>cxJLen set out=cxJStringError,done=1 quit
 . set c=$extract(cxJSrc,cxJPos)
 . if c="""" set out=out_"""",cxJPos=cxJPos+1 quit
 . if c="\" set out=out_"\",cxJPos=cxJPos+1 quit
 . if c="/" set out=out_"/",cxJPos=cxJPos+1 quit
 . if c="b" set out=out_$char(8),cxJPos=cxJPos+1 quit
 . if c="f" set out=out_$char(12),cxJPos=cxJPos+1 quit
 . if c="n" set out=out_$char(10),cxJPos=cxJPos+1 quit
 . if c="r" set out=out_$char(13),cxJPos=cxJPos+1 quit
 . if c="t" set out=out_$char(9),cxJPos=cxJPos+1 quit
 . if c'="u" do  quit
 . . set out=cxJStringError,done=1
 . if out=cxJStringError quit
 . set cxJPos=cxJPos+1
 . set code=$$jHex4()
 . if code<0 set out=cxJStringError,done=1 quit
 . if code<55296!(code>57343) set out=out_$$utf8(code) quit
 . if code>56319 set out=cxJStringError,done=1 quit
 . ; high surrogate: a low surrogate must immediately follow
 . set hi=code
 . if $extract(cxJSrc,cxJPos,cxJPos+1)'="\u" set out=cxJStringError,done=1 quit
 . set cxJPos=cxJPos+2
 . set lo=$$jHex4()
 . if lo<0!(lo<56320)!(lo>57343) set out=cxJStringError,done=1 quit
 . set out=out_$$utf8(65536+((hi-55296)*1024)+(lo-56320))
 if out=cxJStringError do  quit cxJStringError
 . set cxJErr="invalid escape sequence in JSON string"
 if 'done do  quit cxJStringError
 . set cxJErr="unterminated JSON string"
 quit out
 ;
jHex4() ; consume exactly 4 hex digits at cxJPos; -1 on failure
 new text,i,c,v
 if cxJPos+3>cxJLen quit -1
 set text=$extract(cxJSrc,cxJPos,cxJPos+3),v=0
 for i=1:1:4 do  quit:v<0
 . set c=$extract(text,i)
 . if '$data(cxHexVal(c)) set v=-1 quit
 . set v=(v*16)+cxHexVal(c)
 if v<0 quit -1
 set cxJPos=cxJPos+4
 quit v
 ;
 ; Encode one Unicode code point as UTF-8 bytes.
utf8(code)
 if code<128 quit $char(code)
 if code<2048 quit $char(192+(code\64))_$char(128+(code#64))
 if code<65536 quit $char(224+(code\4096))_$char(128+((code\64)#64))_$char(128+(code#64))
 quit $char(240+(code\262144))_$char(128+((code\4096)#64))_$char(128+((code\64)#64))_$char(128+(code#64))
 ;
jObject()
 new node,first,key,child,done
 set node=$$jNode("object","")
 if node<0 quit -1
 set cxJPos=cxJPos+1
 do jSkipSpace()
 if cxJPos<=cxJLen,$extract(cxJSrc,cxJPos)="}" set cxJPos=cxJPos+1 quit node
 set first=1,done=0
 for  quit:done  quit:cxJPos<0  do
 . if 'first do
 . . do jSkipSpace()
 . . if cxJPos>cxJLen!($extract(cxJSrc,cxJPos)'=",") set cxJErr="expected , or } in JSON object",cxJPos=-1 quit
 . . set cxJPos=cxJPos+1
 . if cxJPos<0 quit
 . do jSkipSpace()
 . if cxJPos>cxJLen!($extract(cxJSrc,cxJPos)'="""") set cxJErr="expected a JSON object key",cxJPos=-1 quit
 . set key=$$jReadString()
 . if key=cxJStringError set cxJPos=-1 quit
 . do jSkipSpace()
 . if cxJPos>cxJLen!($extract(cxJSrc,cxJPos)'=":") set cxJErr="expected : after a JSON object key",cxJPos=-1 quit
 . set cxJPos=cxJPos+1
 . set child=$$jValue()
 . if child<0 set cxJPos=-1 quit
 . set jN(node)=jN(node)+1,jC(node,jN(node))=child,jK(node,jN(node))=key
 . do jSkipSpace()
 . if cxJPos>cxJLen set cxJErr="unterminated JSON object",cxJPos=-1 quit
 . if $extract(cxJSrc,cxJPos)="}" set cxJPos=cxJPos+1,done=1 quit
 . set first=0
 if cxJPos<0 quit -1
 quit node
 ;
jArray()
 new node,first,child,done
 set node=$$jNode("array","")
 if node<0 quit -1
 set cxJPos=cxJPos+1
 do jSkipSpace()
 if cxJPos<=cxJLen,$extract(cxJSrc,cxJPos)="]" set cxJPos=cxJPos+1 quit node
 set first=1,done=0
 for  quit:done  quit:cxJPos<0  do
 . if 'first do
 . . do jSkipSpace()
 . . if cxJPos>cxJLen!($extract(cxJSrc,cxJPos)'=",") set cxJErr="expected , or ] in JSON array",cxJPos=-1 quit
 . . set cxJPos=cxJPos+1
 . if cxJPos<0 quit
 . set child=$$jValue()
 . if child<0 set cxJPos=-1 quit
 . set jN(node)=jN(node)+1,jC(node,jN(node))=child
 . do jSkipSpace()
 . if cxJPos>cxJLen set cxJErr="unterminated JSON array",cxJPos=-1 quit
 . if $extract(cxJSrc,cxJPos)="]" set cxJPos=cxJPos+1,done=1 quit
 . set first=0
 if cxJPos<0 quit -1
 quit node
 ;
 ; Quote a raw byte string as a JSON string literal.
jQuote(text)
 new out,i,c,code
 set out="""",i=0
 for  set i=i+1 quit:i>$length(text)  do
 . set c=$extract(text,i),code=$ascii(c)
 . if c="""" set out=out_"\""" quit
 . if c="\" set out=out_"\\" quit
 . if code=8 set out=out_"\b" quit
 . if code=9 set out=out_"\t" quit
 . if code=10 set out=out_"\n" quit
 . if code=12 set out=out_"\f" quit
 . if code=13 set out=out_"\r" quit
 . if code<32 set out=out_"\u00"_$extract(cxHexDigits,(code\16)+1)_$extract(cxHexDigits,(code#16)+1) quit
 . set out=out_c
 quit out_""""
 ;
 ; Serialize a node back to JSON text.
jEncode(node)
 new type,i,out
 set type=jT(node)
 if type="string" quit $$jQuote(jV(node))
 if (type="number")!(type="true")!(type="false")!(type="null") quit jV(node)
 if type="object" do
 . set out="{"
 . for i=1:1:$get(jN(node)) do
 . . if i>1 set out=out_","
 . . set out=out_$$jQuote(jK(node,i))_":"_$$jEncode(jC(node,i))
 . set out=out_"}"
 else  do
 . set out="["
 . for i=1:1:$get(jN(node)) do
 . . if i>1 set out=out_","
 . . set out=out_$$jEncode(jC(node,i))
 . set out=out_"]"
 quit out
 ;
 ; True when `literal` is a JSON number literal representing a finite integer
 ; in range. Convex may encode an integral value as "0" or "0.0"; both are
 ; accepted, fractional and out-of-range values are not.
integral(literal)
 new mantissa,fraction,point,allZero,i
 if (literal["e")!(literal["E") quit 0 ; exponent form is never treated as integral here
 set point=$find(literal,".")
 if point=0 quit $$inRange(literal)
 set mantissa=$extract(literal,1,point-2)
 set fraction=$extract(literal,point,$length(literal))
 set allZero=1
 for i=1:1:$length(fraction) if $extract(fraction,i)'="0" set allZero=0
 if 'allZero quit 0
 quit $$inRange(mantissa)
 ;
inRange(text)
 new n
 set n=text+0
 if n<-9007199254740992 quit 0
 if n>9007199254740992 quit 0
 quit 1
 ;
 ; ===========================================================================
 ; Randomness
 ; ===========================================================================
 ;
 ; Read `n` random bytes from the kernel CSPRNG and return them as lowercase
 ; hex. /dev/urandom is a character device, readable even from a read-only
 ; filesystem layer, so this needs no writable state of its own.
randomHex(n)
 ; READ var#count:timeout waits for exactly `count` bytes (or EOF, or the
 ; full timeout) rather than returning as soon as any bytes are ready --
 ; confirmed by direct experiment, and the reason an earlier version of this
 ; function occasionally returned short. A plain READ var:timeout returns as
 ; soon as any bytes arrive, so this loops that form until it has n bytes.
 ;
 ; Deliberately does NOT check $DEVICE after the OPEN: confirmed by direct
 ; experiment (against both socket CONNECT and this same /dev/urandom OPEN)
 ; that $DEVICE does not reliably read as "" on success once a process has
 ; done any prior I/O on another device -- it has been observed as the
 ; literal string "0" on a provably successful open. Checking it here
 ; silently discarded a real open and returned "", which produced an empty
 ; WebSocket mask and an empty Sec-WebSocket-Key: real, observed failures,
 ; not a hypothetical. The read loop below is itself failure-safe (it caps
 ; attempts and reports a short result), so nothing else needs the guard.
 new raw,out,i,b,chunk,attempts
 open "/dev/urandom":readonly:5
 use "/dev/urandom"
 set raw="",attempts=0
 for  quit:($length(raw)>=n)!(attempts>32)  do
 . read chunk:5
 . set raw=raw_chunk,attempts=attempts+1
 use $principal
 close "/dev/urandom"
 if $length(raw)<n quit ""
 set raw=$extract(raw,1,n)
 set out=""
 for i=1:1:n do
 . set b=$ascii(raw,i)
 . set out=out_$extract(cxHexDigits,(b\16)+1)_$extract(cxHexDigits,(b#16)+1)
 quit out
 ;
 ; RFC 4122 version 4 UUID, used as the Live session id.
uuid()
 new hex,variant
 set hex=$$randomHex(16)
 if $length(hex)'=32 quit ""
 set variant=$extract(cxHexDigits,8+(cxHexVal($extract(hex,17,17))#4)+1)
 quit $extract(hex,1,8)_"-"_$extract(hex,9,12)_"-4"_$extract(hex,14,16)_"-"_variant_$extract(hex,18,20)_"-"_$extract(hex,21,32)
 ;
 ; ===========================================================================
 ; URL parsing
 ; ===========================================================================
 ;
 ; Populate cxSecure/cxHost/cxPort/cxHostHeader from a "http(s)://host[:port]"
 ; deployment URL. Convex deployment URLs never carry a path, query, or
 ; fragment, so this deliberately does not try to parse one.
parseUrl(url)
 new rest,slash2,colon,portText
 set cxUrl=url
 if $extract(url,1,8)="https://" set cxSecure=1,rest=$extract(url,9,$length(url))
 else  if $extract(url,1,7)="http://" set cxSecure=0,rest=$extract(url,8,$length(url))
 else  quit $$fail("ConfigError","the deployment URL must start with http:// or https://")
 if rest="" quit $$fail("ConfigError","the deployment URL has no host")
 set slash2=$find(rest,"/")
 if slash2>0 set rest=$extract(rest,1,slash2-2)
 if rest="" quit $$fail("ConfigError","the deployment URL has no host")
 set colon=$find(rest,":")
 if colon=0 do
 . set cxHost=rest
 . set cxPort=$select(cxSecure:443,1:80)
 else  do
 . set cxHost=$extract(rest,1,colon-2)
 . set portText=$extract(rest,colon,$length(rest))
 . set cxPort=portText+0
 if cxHost="" quit $$fail("ConfigError","the deployment URL has no host")
 if (cxPort<1)!(cxPort>65535) quit $$fail("ConfigError","the deployment URL port is invalid")
 set cxHostHeader=$select(colon=0:cxHost,1:cxHost_":"_cxPort)
 quit 1
 ;
 ; ===========================================================================
 ; Sockets: plain TCP is opened directly with the language's OPEN/USE/READ
 ; syntax against a device of type "SOCKET". TLS additionally negotiates
 ; through YottaDB's bundled OpenSSL encryption plugin via WRITE /TLS.
 ; ===========================================================================
 ;
nowMs()
 ; $ZUT is microseconds since the Unix epoch, so this is monotonic enough for
 ; a deadline budget without any extra clock plumbing.
 quit $zut\1000
 ;
sockOpen(host,port,secure,timeoutMs)
 ; A single OPEN carrying CONNECT is unreliable here: $DEVICE does not
 ; reliably distinguish success from failure (both a live connection and a
 ; genuinely refused one have been observed to report "0"), apparently
 ; because $DEVICE/$KEY are only meaningful for the device actually USEd, per
 ; YottaDB's own documented recommendation. So this opens an empty socket
 ; device first, USEs it with CONNECT, and reads $KEY -- which does reliably
 ; read "ESTABLISHED|handle|address" on success and "" on failure -- while it
 ; is the current device.
 new handle,seconds,key
 set cxSockNext=$get(cxSockNext,0)+1
 set handle="s"_cxSockNext
 set seconds=(timeoutMs+999)\1000
 if seconds<1 set seconds=1
 open handle::seconds:"SOCKET"
 use handle:(connect=host_":"_port_":TCP":ioerror="TRAP":ichset="M":ochset="M")
 set key=$key
 use $principal
 if $extract(key,1,11)'="ESTABLISHED" do  quit ""
 . set cxErrTransport=$$fail("TransportError","cannot connect to "_host_":"_port)
 if secure do
 . use handle
 . write /tls("client",seconds,"client")
 . new tlsTest set tlsTest=$test
 . use $principal
 . if 'tlsTest do
 . . close handle
 . . set cxErrTransport=$$fail("TransportError","TLS handshake to "_host_" timed out")
 . . set handle=""
 quit handle
 ;
sockWrite(handle,text,timeoutMs)
 use handle
 write text
 use $principal
 quit 1
 ;
 ; Reads whatever arrives within timeoutMs, capped defensively at `maxLen`.
 ; Deliberately NOT `READ var#count:timeout`: confirmed by direct experiment
 ; against a peer that writes a few bytes and then holds the connection open
 ; that the counted form blocks for the full timeout (or EOF) rather than
 ; returning as soon as any data is ready, which would make every read on a
 ; live connection cost its entire budget. The uncounted form returns as soon
 ; as at least one byte has arrived.
 ; Returns "ok" (something arrived), "timeout" (nothing arrived in time),
 ; "eof" (the peer closed cleanly), or "error".
sockRead(handle,maxLen,timeoutMs,data)
 ; A real (fractional) second count, not rounded up to the next whole
 ; second: the adapter's Live-pump/command-read interleaving passes budgets
 ; as small as 15ms, and READ's timeout argument honors fractional seconds.
 new seconds
 set seconds=timeoutMs/1000
 if seconds<0 set seconds=0
 ; maxLen is no longer used to bound the READ itself (see above); callers
 ; append whatever arrives to their own growing buffer, so there is nothing
 ; to truncate here without silently discarding bytes.
 set data=""
 use handle
 read data:seconds
 new sawTest set sawTest=$test
 new eof set eof=$zeof
 use $principal
 ; A peer that writes its response and then closes can deliver both real
 ; bytes and end-of-file on the same READ; treat that as data first so the
 ; caller processes it, and only report "eof" once a read truly comes back
 ; empty.
 if data'="" quit "ok"
 if eof quit "eof"
 if 'sawTest quit "timeout"
 quit "ok"
 ;
sockClose(handle)
 if handle="" quit
 use handle
 close handle
 use $principal
 quit
 ;
 ; ===========================================================================
 ; Client lifecycle
 ; ===========================================================================
 ;
open(url,version)
 do setup
 if '$$parseUrl(url) quit 0
 set cxClientVer=$select(version="":"mumps-0.1.0",1:version)
 set cxToken=""
 set cxSession=$$uuid()
 if cxSession="" quit $$fail("ConfigError","cannot generate a session identifier")
 set cxHttpConnectMs=5000,cxHttpTotalMs=15000
 set cxLiveConnectMs=5000,cxLiveWriteMs=2000
 set cxLiveInitialTimestamp="AAAAAAAAAAA="
 set cxLiveLastClose="InitialConnect"
 set cxLiveMaxTimestamp=cxLiveInitialTimestamp
 set cxLiveRemoteQuerySet=0,cxLiveRemoteIdentity=0,cxLiveRemoteTimestamp=cxLiveInitialTimestamp
 set cxLiveConnectionCount=0
 set cxLiveQuerySetVersion=0
 set cxLiveSocket=""
 set cxLiveNextQueryId=0
 set cxLiveBad=0
 ; Reconnect-on-drop backoff: cxLiveBackoffMs is the delay liveMaybeReconnect
 ; waits before the next attempt after a failure, doubling (capped) on each
 ; consecutive failure and resetting to the base once a handshake succeeds.
 ; cxLiveRetryAt=0 lets the very first connection attempt happen immediately.
 set cxLiveBackoffBaseMs=250,cxLiveBackoffMaxMs=30000
 set cxLiveBackoffMs=cxLiveBackoffBaseMs
 set cxLiveRetryAt=0
 kill subPath,subArgs,subTag,subValue,subLogs,subErrName,subErrMsg,subErrData,subHasValue,subVersion,subAwaitingRehydration,tagToQid
 quit 1
 ;
setAuth(token)
 set cxToken=token
 quit 1
 ;
quote(text) quit $$jQuote(text)
 ;
runtimeVersion()
 quit $zyrelease_"; native-mumps-0.1.0"
 ;
 ; ===========================================================================
 ; HTTP transport: one request, one connection, one deadline covering
 ; connect, write, and the whole response.
 ; ===========================================================================
 ;
remaining(deadline)
 new left set left=deadline-$$nowMs()
 quit $select(left<0:0,1:left)
 ;
 ; httpRequest(path,body,.status,.responseBody) -> 1 on a completed exchange
 ; (any HTTP status), 0 with cxErrName/cxErrMsg set on a transport/protocol
 ; failure.
httpRequest(path,body,status,responseBody)
 new deadline,handle,request,headerEnd,buffer,chunk,headers,lengthText,length,ok
 set status=0,responseBody=""
 set deadline=$$nowMs()+cxHttpTotalMs
 set handle=$$sockOpen(cxHost,cxPort,cxSecure,$$remaining(deadline))
 if handle="" quit 0
 ;
 set request="POST "_path_" HTTP/1.1"_$char(13,10)
 set request=request_"Host: "_cxHostHeader_$char(13,10)
 set request=request_"Content-Type: application/json"_$char(13,10)
 set request=request_"Accept: application/json"_$char(13,10)
 set request=request_"Connection: close"_$char(13,10)
 set request=request_"Convex-Client: "_cxClientVer_$char(13,10)
 if cxToken'="" set request=request_"Authorization: Bearer "_cxToken_$char(13,10)
 set request=request_"Content-Length: "_$length(body)_$char(13,10,13,10)_body
 new wok set wok=$$sockWrite(handle,request,$$remaining(deadline))
 ;
 set buffer="",headerEnd=0
 for  quit:headerEnd>0  do  quit:headerEnd<0
 . new outcome set outcome=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . if outcome="ok" do  quit
 . . set buffer=buffer_chunk
 . . set headerEnd=$find(buffer,$char(13,10,13,10))
 . if outcome="timeout" do  quit
 . . set cxErrTransport=$$fail("TransportError","timed out reading the HTTP response header")
 . . set headerEnd=-1
 . if outcome="eof" do  quit
 . . set cxErrTransport=$$fail("TransportError","the deployment closed the connection before responding")
 . . set headerEnd=-1
 . if outcome="error" do
 . . set cxErrTransport=$$fail("TransportError","response read failed")
 . . set headerEnd=-1
 if headerEnd<0 do sockClose(handle) quit 0
 ;
 set status=$$parseStatusLine($extract(buffer,1,headerEnd-5))
 if status<0 do sockClose(handle) quit 0
 new ok2 set ok2=$$parseHeaders($extract(buffer,1,headerEnd-5),.headers)
 if 'ok2 do sockClose(handle) quit 0
 set buffer=$extract(buffer,headerEnd,$length(buffer))
 ;
 if $get(headers("transfer-encoding"))'="",$get(headers("content-length"))'="" do sockClose(handle) quit $$fail("ProtocolError","HTTP response has both Transfer-Encoding and Content-Length")
 if $$lower($get(headers("transfer-encoding")))="chunked" do
 . set ok=$$readChunked(handle,deadline,.buffer,.responseBody)
 else  if $get(headers("content-length"))'="" do
 . set lengthText=headers("content-length")
 . if lengthText'?1n.n set cxErrProto=$$fail("ProtocolError","HTTP Content-Length is invalid") set ok=0 quit
 . set length=lengthText+0
 . if length>cxHttpMaxBody set cxErrProto=$$fail("ProtocolError","HTTP body exceeds the response limit") set ok=0 quit
 . set ok=1
 . for  quit:$length(buffer)>=length  do  quit:'ok
 . . new outcome2 set outcome2=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . . if outcome2'="ok" set cxErrTransport=$$fail("TransportError","the HTTP body ended early") set ok=0 quit
 . . set buffer=buffer_chunk
 . if $length(buffer)<length set ok=0
 . else  set responseBody=$extract(buffer,1,length),ok=1
 else  do
 . for  do  quit:'ok
 . . new outcome3 set outcome3=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . . if outcome3="eof" set ok=1 quit
 . . if outcome3'="ok" set cxErrTransport=$$fail("TransportError","the HTTP body did not complete") set ok=0 quit
 . . set buffer=buffer_chunk
 . . if $length(buffer)>cxHttpMaxBody set cxErrProto=$$fail("ProtocolError","HTTP body exceeds the response limit") set ok=0 quit
 . . set ok=2 ; keep looping (any non-zero "ok" during the loop just means "continue")
 . set responseBody=buffer
 . if ok=2 set ok=1
 do sockClose(handle)
 quit ok
 ;
lower(s)
 new r,i,c
 set r="",i=0
 for  set i=i+1 quit:i>$length(s)  do
 . set c=$ascii(s,i)
 . if c>64,c<91 set c=c+32
 . set r=r_$char(c)
 quit r
 ;
parseStatusLine(headerBlock)
 new line,end
 set end=$find(headerBlock,$char(13,10))
 set line=$select(end=0:headerBlock,1:$extract(headerBlock,1,end-3))
 if $extract(line,1,5)'="HTTP/" do  quit -1
 . set cxErrProto=$$fail("ProtocolError","HTTP status line is invalid")
 new code set code=$extract(line,10,12)
 if code'?3n do  quit -1
 . set cxErrProto=$$fail("ProtocolError","HTTP status line is invalid")
 quit code+0
 ;
parseHeaders(headerBlock,headers)
 kill headers
 new pos,lineEnd,line,colon,name,value
 set pos=$find(headerBlock,$char(13,10))
 if pos=0 quit 1
 for  quit:pos>$length(headerBlock)  do
 . set lineEnd=$find(headerBlock,$char(13,10),pos)
 . set line=$select(lineEnd=0:$extract(headerBlock,pos,$length(headerBlock)),1:$extract(headerBlock,pos,lineEnd-3))
 . set pos=$select(lineEnd=0:$length(headerBlock)+1,1:lineEnd)
 . if line="" quit
 . set colon=$find(line,":")
 . if colon<2 quit
 . set name=$$lower($extract(line,1,colon-2))
 . set value=$extract(line,colon,$length(line))
 . for  quit:$extract(value,1)'=" "&($extract(value,1)'=$char(9))  set value=$extract(value,2,$length(value))
 . for  quit:$extract(value,$length(value))'=" "&($extract(value,$length(value))'=$char(9))  set value=$extract(value,1,$length(value)-1)
 . set headers(name)=value
 quit 1
 ;
readChunked(handle,deadline,buffer,body)
 new lineEnd,sizeLine,size,outcome,chunk,semicolon
 set body=""
 for  do  quit:size=""
 . for  quit:$find(buffer,$char(13,10))>0  do  quit:outcome'="ok"
 . . set outcome=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . . if outcome'="ok" quit
 . . set buffer=buffer_chunk
 . if outcome'="ok",$find(buffer,$char(13,10))=0 set cxErrTransport=$$fail("TransportError","chunked HTTP body ended early") set size="" set body=cxJStringError quit
 . set lineEnd=$find(buffer,$char(13,10))
 . set sizeLine=$extract(buffer,1,lineEnd-3)
 . new semicolon set semicolon=$find(sizeLine,";")
 . if semicolon>0 set sizeLine=$extract(sizeLine,1,semicolon-2)
 . if sizeLine'?1.8h set cxErrProto=$$fail("ProtocolError","chunked HTTP size is invalid") set size="" set body=cxJStringError quit
 . set size=$$hexValue(sizeLine)
 . set buffer=$extract(buffer,lineEnd,$length(buffer))
 . if size=0 do  quit
 . . set body="__done__"
 . if $length(body)+size>cxHttpMaxBody set cxErrProto=$$fail("ProtocolError","HTTP body exceeds the response limit") set size="" set body=cxJStringError quit
 . for  quit:$length(buffer)>=(size+2)  do  quit:outcome'="ok"
 . . set outcome=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . . if outcome'="ok" quit
 . . set buffer=buffer_chunk
 . if outcome'="ok" set cxErrTransport=$$fail("TransportError","chunked HTTP body ended early") set size="" set body=cxJStringError quit
 . if $extract(buffer,size+1,size+2)'=$char(13,10) set cxErrProto=$$fail("ProtocolError","chunked HTTP data is missing its terminator") set size="" set body=cxJStringError quit
 . if body'="__done__" set body=body_$extract(buffer,1,size)
 . set buffer=$extract(buffer,size+3,$length(buffer))
 . set size=""
 if body=cxJStringError set body="" quit 0
 if body="__done__" set body=""
 quit 1
 ;
hexValue(text)
 new i,v
 set v=0
 for i=1:1:$length(text) set v=(v*16)+cxHexVal($$lower($extract(text,i)))
 quit v
 ;
 ; ===========================================================================
 ; Convex HTTP functions
 ; ===========================================================================
 ;
query(path,arguments,result) quit $$call("query",path,arguments,.result)
mutation(path,arguments,result) quit $$call("mutation",path,arguments,.result)
action(path,arguments,result) quit $$call("action",path,arguments,.result)
 ;
call(operation,path,arguments,result)
 kill result
 new mark,argNode,body,status,responseBody,ok,payloadMark,payload,statusNode,logsNode,logs,valueNode,msgNode,dataNode
 if cxUrl="" quit $$fail("ConfigError","the client is not open")
 if $find(path,":")=0 quit $$fail("ClientError","function path must be module:function")
 set mark=$$jMark()
 set argNode=$$jParse(arguments)
 if argNode<0!($$jType(argNode)'="object") do  quit $$fail("ClientError","arguments must be a JSON object")
 . do jRelease(mark)
 set body="{""path"":"_$$jQuote(path)_",""args"":"_$$jEncode(argNode)_",""format"":""json""}"
 do jRelease(mark)
 ;
 set ok=$$httpRequest("/api/"_operation,body,.status,.responseBody)
 if 'ok quit 0
 if (status<200)!(status>=300) quit $$fail("TransportError","Convex HTTP request returned status "_status)
 ;
 set payloadMark=$$jMark()
 set payload=$$jParse(responseBody)
 if payload<0!($$jType(payload)'="object") do  quit $$fail("ProtocolError","HTTP "_status_" returned a non-Convex body")
 . do jRelease(payloadMark)
 ;
 set statusNode=$$jFind(payload,"status")
 set logsNode=$$jFind(payload,"logLines")
 ; logLines is part of Convex's documented response envelope, but a self-hosted
 ; deployment omits the key entirely when a function logged nothing; treat
 ; that the same as an explicit empty array rather than a protocol error.
 set logs=$select(logsNode<0:"[]",1:$$encodeLogs(logsNode))
 if logs="" do  quit $$fail("ProtocolError","Convex logLines must be an array of strings")
 . do jRelease(payloadMark)
 set result("logs")=logs
 ;
 if statusNode>=0,$$jType(statusNode)="string",$$jText(statusNode)="success" do  quit 1
 . set valueNode=$$jFind(payload,"value")
 . if valueNode<0 do  quit $$fail("ProtocolError","a successful Convex response has no value")
 . . do jRelease(payloadMark)
 . set result("value")=$$jEncode(valueNode)
 . do jRelease(payloadMark)
 ;
 if statusNode>=0,$$jType(statusNode)="string",$$jText(statusNode)="error" do  quit 0
 . set msgNode=$$jFind(payload,"errorMessage")
 . set dataNode=$$jFind(payload,"errorData")
 . if msgNode<0!($$jType(msgNode)'="string") do  quit $$fail("ProtocolError","a failed Convex response has no errorMessage string")
 . . do jRelease(payloadMark)
 . set cxErrName="FunctionError"
 . set cxErrMsg=$$jText(msgNode)
 . set cxErrData=$select(dataNode>=0:$$jEncode(dataNode),1:"null")
 . do jRelease(payloadMark)
 ;
 do jRelease(payloadMark)
 quit $$fail("ProtocolError","HTTP "_status_" response has an unknown status")
 ;
 ; Convex's logLines is documented as an array of strings; encode it back to
 ; JSON text, or "" (a value cx_call never legitimately produces) on a shape
 ; mismatch.
encodeLogs(node)
 new i,out
 if node<0 quit ""
 if $$jType(node)'="array" quit ""
 set out="["
 for i=1:1:$$jCount(node) do
 . if i>1 set out=out_","
 . new child set child=$$jChild(node,i)
 . if $$jType(child)'="string" set out="" quit
 . set out=out_$$jQuote($$jText(child))
 if out="" quit ""
 quit out_"]"
 ;
 ; ===========================================================================
 ; Bit arithmetic and SHA-1 (needed only for the WebSocket handshake's
 ; Sec-WebSocket-Accept digest -- YottaDB has no built-in message digest, and
 ; M has no native bitwise operators, so this reconstructs exactly the 32-bit
 ; ops SHA-1 needs from ordinary integer arithmetic).
 ; ===========================================================================
 ;
band(a,b)
 new r,p,ba,bb
 set r=0,p=1
 for  quit:(a=0)&(b=0)  do
 . set ba=a#2,bb=b#2
 . if ba=1,bb=1 set r=r+p
 . set a=a\2,b=b\2,p=p*2
 quit r
 ;
bxor(a,b)
 new r,p,ba,bb
 set r=0,p=1
 for  quit:(a=0)&(b=0)  do
 . set ba=a#2,bb=b#2
 . if ba'=bb set r=r+p
 . set a=a\2,b=b\2,p=p*2
 quit r
 ;
bnot32(a) quit 4294967295-a
 ;
rotl32(x,n)
 ; Built bit by bit rather than via x*2^n: for x up to 2^32-1 and n up to 31,
 ; that product needs up to 63 significant decimal digits of exact intermediate
 ; precision, well past what YottaDB's numeric type keeps exact (confirmed
 ; empirically: 4023233417*1073741824 rounds its last digit). Every quantity
 ; here -- a single bit and a single power of two -- stays far inside the
 ; exact range instead.
 new r,i,bit,destPos
 set r=0
 for i=0:1:31 do
 . set bit=x#2
 . set x=x\2
 . if bit=1 do
 . . set destPos=(i+n)#32
 . . set r=r+cxPow2(destPos)
 quit r
 ;
be32(b0,b1,b2,b3) ; assemble a big-endian 32-bit word from four bytes
 quit (b0*16777216)+(b1*65536)+(b2*256)+b3
 ;
 ; sha1(text) -> 20 raw digest bytes.
sha1(text)
 new bitLen,padded,i,blockCount,block,w,h0,h1,h2,h3,h4,a,b,c,d,e,f,k,temp,t
 set bitLen=$length(text)*8
 set padded=text_$char(128)
 for  quit:(($length(padded)#64)=56)  set padded=padded_$char(0)
 for i=7:-1:0 set padded=padded_$char((bitLen\cxPow2(i*8))#256)
 set h0=1732584193,h1=4023233417,h2=2562383102,h3=271733878,h4=3285377520
 set blockCount=$length(padded)/64
 for block=0:1:blockCount-1 do
 . kill w
 . for i=0:1:15 do
 . . new base set base=(block*64)+(i*4)+1
 . . set w(i)=$$be32($ascii(padded,base),$ascii(padded,base+1),$ascii(padded,base+2),$ascii(padded,base+3))
 . for i=16:1:79 set w(i)=$$rotl32($$bxor($$bxor(w(i-3),w(i-8)),$$bxor(w(i-14),w(i-16))),1)
 . set a=h0,b=h1,c=h2,d=h3,e=h4
 . for t=0:1:79 do
 . . if t<20 set f=$$bxor($$band(b,c),$$band($$bnot32(b),d)),k=1518500249
 . . else  if t<40 set f=$$bxor($$bxor(b,c),d),k=1859775393
 . . else  if t<60 set f=$$bxor($$bxor($$band(b,c),$$band(b,d)),$$band(c,d)),k=2400959708
 . . else  set f=$$bxor($$bxor(b,c),d),k=3395469782
 . . set temp=($$rotl32(a,5)+f+e+k+w(t))#4294967296
 . . set e=d,d=c,c=$$rotl32(b,30),b=a,a=temp
 . set h0=(h0+a)#4294967296,h1=(h1+b)#4294967296,h2=(h2+c)#4294967296
 . set h3=(h3+d)#4294967296,h4=(h4+e)#4294967296
 quit $$be32ToBytes(h0)_$$be32ToBytes(h1)_$$be32ToBytes(h2)_$$be32ToBytes(h3)_$$be32ToBytes(h4)
 ;
be32ToBytes(w)
 quit $char((w\16777216)#256)_$char((w\65536)#256)_$char((w\256)#256)_$char(w#256)
 ;
 ; ===========================================================================
 ; Base64
 ; ===========================================================================
 ;
b64Alphabet() quit "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
 ;
b64Encode(bytes)
 new alphabet,out,i,n,b0,b1,b2,v
 set alphabet=$$b64Alphabet()
 set out="",n=$length(bytes)
 for i=1:3:n do
 . set b0=$ascii(bytes,i)
 . set b1=$select(i+1<=n:$ascii(bytes,i+1),1:-1)
 . set b2=$select(i+2<=n:$ascii(bytes,i+2),1:-1)
 . set v=(b0*65536)+($select(b1<0:0,1:b1)*256)+$select(b2<0:0,1:b2)
 . set out=out_$extract(alphabet,(v\262144)+1,(v\262144)+1)
 . set out=out_$extract(alphabet,((v\4096)#64)+1,((v\4096)#64)+1)
 . set out=out_$select(b1<0:"=",1:$extract(alphabet,((v\64)#64)+1,((v\64)#64)+1))
 . set out=out_$select(b2<0:"=",1:$extract(alphabet,(v#64)+1,(v#64)+1))
 quit out
 ;
b64DecodeValue(c,alphabet)
 new p set p=$find(alphabet,c)
 if p=0 quit -1
 quit p-2
 ;
b64Decode(text)
 new alphabet,out,i,c0,c1,c2,c3,v,n
 set alphabet=$$b64Alphabet()
 set out="",n=$length(text)
 for i=1:4:n do
 . set c0=$$b64DecodeValue($extract(text,i),alphabet)
 . set c1=$$b64DecodeValue($extract(text,i+1),alphabet)
 . new ch2 set ch2=$extract(text,i+2)
 . new ch3 set ch3=$extract(text,i+3)
 . set c2=$select(ch2="="!(ch2=""):-1,1:$$b64DecodeValue(ch2,alphabet))
 . set c3=$select(ch3="="!(ch3=""):-1,1:$$b64DecodeValue(ch3,alphabet))
 . if c0<0!(c1<0) quit
 . set v=(c0*262144)+(c1*4096)+($select(c2<0:0,1:c2)*64)+$select(c3<0:0,1:c3)
 . set out=out_$char((v\65536)#256)
 . if c2>=0 set out=out_$char((v\256)#256)
 . if c3>=0 set out=out_$char(v#256)
 quit out
 ;
 ; Compare two base64-encoded big-endian byte strings (Convex sync timestamps)
 ; as unsigned integers without ever materializing them as an M number, so a
 ; nanosecond-scale timestamp never loses precision. -1/0/1, like a normal
 ; three-way compare.
tsCmp(a,b)
 ; Convex encodes each sync-protocol timestamp as base64 of a little-endian
 ; uint64 (confirmed empirically: little-endian decode of a transition's
 ; endVersion.ts lines up with the accompanying decimal serverTs field, while
 ; the big-endian reading does not). The most significant byte is therefore
 ; the LAST byte of the decoded string, so this compares from the end.
 new ba,bb,la,lb,i,result,x,y
 set ba=$$b64Decode(a),bb=$$b64Decode(b)
 set la=$length(ba),lb=$length(bb)
 if la'=lb quit $select(la<lb:-1,1:1) ; both are always 8 bytes in practice
 set result=0
 for i=la:-1:1 do  quit:result'=0
 . set x=$ascii(ba,i),y=$ascii(bb,i)
 . if x<y set result=-1 quit
 . if x>y set result=1
 quit result
 ;
 ; ===========================================================================
 ; WebSocket: RFC 6455 handshake and frame codec over the same plain or TLS
 ; socket primitives the HTTP layer uses.
 ; ===========================================================================
 ;
wsGuid() quit "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
 ;
 ; wsHandshake(deadline) -> a socket handle already upgraded to WebSocket, or
 ; "" with cxErr* set. Any bytes read past the handshake response are kept in
 ; cxWsBuf for the frame reader.
wsHandshake(deadline)
 new handle,key,accept,request,buffer,headerEnd,status,headers,outcome,chunk
 set handle=$$sockOpen(cxHost,cxPort,cxSecure,$$remaining(deadline))
 if handle="" quit ""
 ; randomHex returns hex text, not raw bytes; a 16-byte nonce needs 16 random
 ; bytes, so decode the hex back to bytes before base64-encoding it.
 set key=$$b64Encode($$hexToBytes($$randomHex(16)))
 set accept=$$b64Encode($$sha1(key_$$wsGuid()))
 ;
 set request="GET /api/sync HTTP/1.1"_$char(13,10)
 set request=request_"Host: "_cxHostHeader_$char(13,10)
 set request=request_"Upgrade: websocket"_$char(13,10)
 set request=request_"Connection: Upgrade"_$char(13,10)
 set request=request_"Sec-WebSocket-Key: "_key_$char(13,10)
 set request=request_"Sec-WebSocket-Version: 13"_$char(13,10)
 set request=request_"Convex-Client: "_cxClientVer_$char(13,10,13,10)
 new wok set wok=$$sockWrite(handle,request,$$remaining(deadline))
 ;
 set buffer="",headerEnd=0
 for  quit:headerEnd>0  do  quit:headerEnd<0
 . set outcome=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . if outcome="ok" do  quit
 . . set buffer=buffer_chunk
 . . set headerEnd=$find(buffer,$char(13,10,13,10))
 . if outcome="error" do
 . . set cxErrTransport=$$fail("TransportError","the WebSocket upgrade did not complete")
 . . set headerEnd=-1
 . else  do
 . . set cxErrTransport=$$fail("TransportError","the WebSocket upgrade did not complete")
 . . set headerEnd=-1
 if headerEnd<0 do sockClose(handle) quit ""
 ;
 set status=$$parseStatusLine($extract(buffer,1,headerEnd-5))
 if status'=101 do  do sockClose(handle) quit ""
 . set cxErrProto=$$fail("ProtocolError","the WebSocket upgrade returned status "_status)
 new ok2 set ok2=$$parseHeaders($extract(buffer,1,headerEnd-5),.headers)
 if 'ok2 do sockClose(handle) quit ""
 if $get(headers("sec-websocket-accept"))'=accept do  do sockClose(handle) quit ""
 . set cxErrProto=$$fail("ProtocolError","the WebSocket upgrade returned the wrong accept digest")
 ;
 set cxWsBuf=$extract(buffer,headerEnd,$length(buffer))
 quit handle
 ;
hexToBytes(hex)
 new out,i
 set out=""
 for i=1:2:$length(hex) set out=out_$char($$hexValue($extract(hex,i,i+1)))
 quit out
 ;
 ; A masked client -> server data frame carrying the whole message in one
 ; frame; every message this client sends is a short sync-protocol control
 ; message, so fragmentation on the way out is never needed.
wsSend(handle,opcode,payload,timeoutMs)
 new maskBytes,frame,lengthField,i,masked,n
 set maskBytes=$$randomHex(4)
 set maskBytes=$$hexToBytes(maskBytes)
 set n=$length(payload)
 set frame=$char(128+opcode)
 if n<126 set lengthField=$char(128+n)
 else  if n<65536 set lengthField=$char(254)_$char((n\256)#256)_$char(n#256)
 else  set lengthField=$char(255)_$char(0)_$char(0)_$char(0)_$char(0)_$char((n\16777216)#256)_$char((n\65536)#256)_$char((n\256)#256)_$char(n#256)
 set frame=frame_lengthField_maskBytes
 set masked=""
 for i=1:1:n do
 . new mb set mb=$ascii(maskBytes,((i-1)#4)+1)
 . set masked=masked_$char($$bxor($ascii(payload,i),mb))
 set frame=frame_masked
 quit $$sockWrite(handle,frame,timeoutMs)
 ;
 ; Ensures cxWsBuf holds at least `need` bytes, reading more from `handle` as
 ; needed. Returns "ok"/"timeout"/"eof"/"error"; on "ok" cxWsBuf has >= need.
wsFill(handle,need,deadline)
 new outcome,chunk
 for  quit:$length(cxWsBuf)>=need  do  quit:outcome'="ok"
 . set outcome=$$sockRead(handle,65536,$$remaining(deadline),.chunk)
 . if outcome="ok" set cxWsBuf=cxWsBuf_chunk
 if $length(cxWsBuf)>=need quit "ok"
 quit outcome
 ;
 ; Reads exactly one WebSocket frame (server frames are never masked).
wsReadFrame(handle,deadline,fin,opcode,payload)
 new outcome,b0,b1,lenField,extra,maskLen
 set payload=""
 set outcome=$$wsFill(handle,2,deadline)
 if outcome'="ok" quit outcome
 set b0=$ascii(cxWsBuf,1),b1=$ascii(cxWsBuf,2)
 set fin=b0\128
 set opcode=b0#16
 set lenField=b1#128 ; the mask bit from a server frame is always 0
 set extra=2
 if lenField=126 do
 . set outcome=$$wsFill(handle,4,deadline)
 . if outcome="ok" set lenField=($ascii(cxWsBuf,3)*256)+$ascii(cxWsBuf,4),extra=4
 else  if lenField=127 do
 . set outcome=$$wsFill(handle,10,deadline)
 . if outcome="ok" do
 . . new hi set hi=$$be32($ascii(cxWsBuf,3),$ascii(cxWsBuf,4),$ascii(cxWsBuf,5),$ascii(cxWsBuf,6))
 . . new lo set lo=$$be32($ascii(cxWsBuf,7),$ascii(cxWsBuf,8),$ascii(cxWsBuf,9),$ascii(cxWsBuf,10))
 . . if hi>0!(lo>cxWsMaxFrame) set lenField=cxWsMaxFrame+1
 . . else  set lenField=lo
 . set extra=10
 if outcome'="ok" quit outcome
 if lenField>cxWsMaxFrame do  quit "error"
 . set cxErrProto=$$fail("ProtocolError","WebSocket frame exceeds the adapter's frame limit")
 set outcome=$$wsFill(handle,extra+lenField,deadline)
 if outcome'="ok" quit outcome
 set payload=$extract(cxWsBuf,extra+1,extra+lenField)
 set cxWsBuf=$extract(cxWsBuf,extra+lenField+1,$length(cxWsBuf))
 quit "ok"
 ;
 ; Reassembles continuation frames into one logical message, answers PINGs
 ; inline, and reports a peer CLOSE as its own outcome so the caller never
 ; mistakes it for an ordinary data message.
wsRecvMessage(handle,deadline,opcode,payload)
 new outcome,fin,frameOpcode,framePayload,messageOpcode,assembling
 set payload="",assembling=0,messageOpcode=0
 for  do  quit:outcome'="more"
 . set outcome=$$wsReadFrame(handle,deadline,.fin,.frameOpcode,.framePayload)
 . if outcome'="ok" quit
 . if frameOpcode=9 do  quit
 . . new wok set wok=$$wsSend(handle,10,framePayload,$$remaining(deadline))
 . . set outcome="more"
 . if frameOpcode=10 set outcome="more" quit
 . if frameOpcode=8 set outcome="close" quit
 . if 'assembling set messageOpcode=frameOpcode,assembling=1
 . set payload=payload_framePayload
 . if 'fin set outcome="more"
 set opcode=messageOpcode
 quit outcome
 ;
 ; ===========================================================================
 ; Live: the Convex sync protocol state machine.
 ;
 ; Scope: a single connection that is brought up on the first subscribe and
 ; torn down on close. This section owns the wire protocol itself -- Connect,
 ; ModifyQuerySet (Add/Remove), and validating a Transition before publishing
 ; any part of it -- plus liveMaybeReconnect, which the adapter's main loop
 ; polls every pass to bring a dropped connection back with exponential
 ; backoff (see liveMaybeReconnect below). The adapter-only debugDisconnect
 ; command itself just calls liveRetire directly; liveMaybeReconnect is what
 ; notices the empty socket afterwards and re-establishes it.
 ; ===========================================================================
 ;
liveConnectMessage()
 new message
 set message="{""type"":""Connect"",""sessionId"":"_$$jQuote(cxSession)
 set message=message_",""connectionCount"":"_cxLiveConnectionCount
 set message=message_",""lastCloseReason"":"_$$jQuote(cxLiveLastClose)
 set message=message_",""clientTs"":0"
 if cxLiveMaxTimestamp'=cxLiveInitialTimestamp set message=message_",""maxObservedTimestamp"":"_$$jQuote(cxLiveMaxTimestamp)
 quit message_"}"
 ;
liveAddModification(queryId)
 quit "{""type"":""Add"",""queryId"":"_queryId_",""udfPath"":"_$$jQuote(subPath(queryId))_",""args"":["_subArgs(queryId)_"]}"
 ;
 ; Bring up a connection and replay the whole active query set. Every
 ; reconnect resends these Add operations, which is what lets a subscription
 ; survive a dropped socket.
liveConnect()
 new deadline,handle,modifications,count,queryId,message
 set deadline=$$nowMs()+cxLiveConnectMs
 set handle=$$wsHandshake(deadline)
 if handle="" do  quit 0
 . ; A handshake that never completed never became a connection the server
 . ; saw, so it must not inflate connectionCount -- only cxLiveLastClose (the
 . ; reason reported in the *next* attempt's Connect message) is updated.
 . set cxLiveLastClose=cxErrMsg
 set cxLiveSocket=handle
 set cxLiveRemoteQuerySet=0,cxLiveRemoteIdentity=0,cxLiveRemoteTimestamp=cxLiveInitialTimestamp
 set cxLiveQuerySetVersion=0
 ; A successful handshake is what resets backoff, per Convex client
 ; convention: a healthy connection must not inherit a stale maximum delay
 ; from an earlier run of failures.
 set cxLiveBackoffMs=cxLiveBackoffBaseMs,cxLiveRetryAt=0
 ;
 new wok set wok=$$wsSend(handle,1,$$liveConnectMessage(),$$remaining(deadline))
 set cxLiveConnectionCount=cxLiveConnectionCount+1
 ;
 set modifications="",count=0
 new qid set qid=""
 for  set qid=$order(subPath(qid)) quit:qid=""  do
 . if count>0 set modifications=modifications_","
 . set modifications=modifications_$$liveAddModification(qid)
 . set count=count+1
 . ; Every resent Add is a candidate for an unchanged rehydration, but only
 . ; when the subscription's last delivery was a real value: a subscription
 . ; that has never delivered anything yet (freshly registered, mid drop) or
 . ; whose last delivery was an error still wants its next value delivered
 . ; unconditionally, so only arm suppression on a prior success.
 . set subAwaitingRehydration(qid)=($get(subHasValue(qid))=1)&('$data(subErrName(qid)))
 if count>0 do
 . set message="{""type"":""ModifyQuerySet"",""baseVersion"":0,""newVersion"":1,"
 . set message=message_"""modifications"":["_modifications_"]}"
 . new wok2 set wok2=$$wsSend(handle,1,message,$$remaining(deadline))
 . set cxLiveQuerySetVersion=1
 quit 1
 ;
liveEnsureConnection()
 if cxLiveSocket'="" quit 1
 quit $$liveConnect()
 ;
subscribe(tag,path,arguments)
 new mark,node,queryId,charge,message
 if cxUrl="" quit $$fail("ConfigError","the client is not open")
 if $find(path,":")=0 quit $$fail("ClientError","function path must be module:function")
 set mark=$$jMark()
 set node=$$jParse(arguments)
 if node<0!($$jType(node)'="object") do  quit $$fail("ClientError","subscription arguments must be a JSON object")
 . do jRelease(mark)
 set arguments=$$jEncode(node)
 do jRelease(mark)
 ;
 if $data(tagToQid(tag)) do
 . new discard set discard=$$unsubscribe(tag)
 ;
 set queryId=cxLiveNextQueryId
 set cxLiveNextQueryId=cxLiveNextQueryId+1
 set subPath(queryId)=path,subArgs(queryId)=arguments,subTag(queryId)=tag
 set tagToQid(tag)=queryId
 set subHasValue(queryId)=0
 ;
 if cxLiveSocket="" do  quit:'$$liveEnsureConnection() $$fail("TransportError","Live connection failed: "_cxLiveLastClose)
 . ; liveConnect() below replays every active subscription, this one included
 if cxLiveSocket'="" quit 1
 ;
 set message="{""type"":""ModifyQuerySet"",""baseVersion"":"_cxLiveQuerySetVersion
 set message=message_",""newVersion"":"_(cxLiveQuerySetVersion+1)
 set message=message_",""modifications"":["_$$liveAddModification(queryId)_"]}"
 new wok set wok=$$wsSend(cxLiveSocket,1,message,cxLiveWriteMs)
 if 'wok do  quit $$fail("TransportError","Live subscribe failed")
 . kill subPath(queryId),subArgs(queryId),subTag(queryId),tagToQid(tag),subHasValue(queryId)
 set cxLiveQuerySetVersion=cxLiveQuerySetVersion+1
 quit 1
 ;
unsubscribe(tag)
 new queryId,message
 if '$data(tagToQid(tag)) quit 1
 set queryId=tagToQid(tag)
 if cxLiveSocket'="" do
 . set message="{""type"":""ModifyQuerySet"",""baseVersion"":"_cxLiveQuerySetVersion
 . set message=message_",""newVersion"":"_(cxLiveQuerySetVersion+1)
 . set message=message_",""modifications"":[{""type"":""Remove"",""queryId"":"_queryId_"}]}"
 . new wok set wok=$$wsSend(cxLiveSocket,1,message,cxLiveWriteMs)
 . if wok set cxLiveQuerySetVersion=cxLiveQuerySetVersion+1
 kill subPath(queryId),subArgs(queryId),subTag(queryId),subValue(queryId),subLogs(queryId)
 kill subErrName(queryId),subErrMsg(queryId),subErrData(queryId),subHasValue(queryId),tagToQid(tag)
 kill subAwaitingRehydration(queryId)
 quit 1
 ;
 ; ---------------------------------------------------------------------------
 ; Server -> client messages
 ; ---------------------------------------------------------------------------
 ;
liveVersion(node,querySet,identity,ts)
 new qsNode,idNode,tsNode
 set querySet=-1
 if node<0!($$jType(node)'="object") quit 0
 set qsNode=$$jFind(node,"querySet")
 set idNode=$$jFind(node,"identity")
 set tsNode=$$jFind(node,"ts")
 if qsNode<0!($$jType(qsNode)'="number") quit 0
 if idNode<0!($$jType(idNode)'="number") quit 0
 if tsNode<0!($$jType(tsNode)'="string") quit 0
 if '$$integral($$jText(qsNode))!('$$integral($$jText(idNode))) quit 0
 set querySet=$$jText(qsNode)+0,identity=$$jText(idNode)+0,ts=$$jText(tsNode)
 quit 1
 ;
liveHandleMessage(text)
 new mark,root,kindNode,kind,result
 set mark=$$jMark()
 set root=$$jParse(text)
 if root<0!($$jType(root)'="object") do  do jRelease(mark) quit 0
 . do liveRetire("ProtocolError","Live message is not a JSON object")
 set kindNode=$$jFind(root,"type")
 if kindNode<0!($$jType(kindNode)'="string") do  do jRelease(mark) quit 0
 . do liveRetire("ProtocolError","Live message has no type")
 set kind=$$jText(kindNode)
 ;
 if kind="Transition" do
 . set result=$$liveTransition(root)
 . do jRelease(mark)
 if kind="Transition" quit result
 if (kind="Ping")!(kind="MutationResponse")!(kind="ActionResponse") do jRelease(mark) quit 1
 if (kind="FatalError")!(kind="AuthError") do
 . new msgNode,message set msgNode=$$jFind(root,"error")
 . set message=$select(msgNode>=0&($$jType(msgNode)="string"):$$jText(msgNode),1:kind)
 . do jRelease(mark)
 . do liveRetire("ProtocolError","Live server reported "_kind_": "_message)
 if (kind="FatalError")!(kind="AuthError") quit 0
 do jRelease(mark)
 do liveRetire("ProtocolError","unsupported Live server message: "_kind)
 quit 0
 ;
liveTransition(root)
 new startQS,startId,startTs,endQS,endId,endTs,modifications,position,change
 new kind,queryId,order,count,bad,badReason
 set bad=0
 if '$$liveVersion($$jFind(root,"startVersion"),.startQS,.startId,.startTs) set bad=1,badReason="Live transition has an invalid state version"
 if 'bad,'$$liveVersion($$jFind(root,"endVersion"),.endQS,.endId,.endTs) set bad=1,badReason="Live transition has an invalid state version"
 if 'bad,(startQS'=cxLiveRemoteQuerySet)!(startId'=cxLiveRemoteIdentity)!(startTs'=cxLiveRemoteTimestamp) set bad=1,badReason="Live transition does not continue the local state"
 if 'bad,$$tsCmp(endTs,startTs)<0 set bad=1,badReason="Live timestamp moved backwards"
 if 'bad,((endQS<startQS)!(endId<startId)) set bad=1,badReason="Live state version counter moved backwards"
 if 'bad set modifications=$$jFind(root,"modifications")
 if 'bad,(modifications<0!($$jType(modifications)'="array")) set bad=1,badReason="Live transition has no modifications array"
 if bad do liveRetire("ProtocolError",badReason) quit 0
 ;
 kill cxChangeKind,cxChangeOrder
 set count=0
 for position=1:1:$$jCount(modifications) do
 . if bad quit
 . set change=$$jChild(modifications,position)
 . new kindNode,qidNode set kindNode=-1,qidNode=-1
 . if $$jType(change)'="object" set bad=1,badReason="Live modification is not an object"
 . if 'bad set kindNode=$$jFind(change,"type"),qidNode=$$jFind(change,"queryId")
 . if 'bad,(kindNode<0!($$jType(kindNode)'="string")!(qidNode<0)!($$jType(qidNode)'="number")) set bad=1,badReason="Live modification is malformed"
 . if 'bad,'$$integral($$jText(qidNode)) set bad=1,badReason="Live modification is malformed"
 . if bad quit
 . set kind=$$jText(kindNode),queryId=$$jText(qidNode)+0
 . if '$$liveChange(change,kind,queryId) set bad=1 quit
 . if $data(subPath(queryId)) do
 . . if '$data(cxChangeKind(queryId)) set count=count+1,cxChangeOrder(count)=queryId
 . . set cxChangeKind(queryId)=kind
 if bad do liveRetire("ProtocolError",badReason) quit 0
 ;
 set cxLiveRemoteQuerySet=endQS,cxLiveRemoteIdentity=endId,cxLiveRemoteTimestamp=endTs
 if $$tsCmp(endTs,cxLiveMaxTimestamp)>0 set cxLiveMaxTimestamp=endTs
 for order=1:1:count do
 . set queryId=cxChangeOrder(order)
 . new isUpdated,isFailed,rehydrating,suppress
 . set isUpdated=(cxChangeKind(queryId)="QueryUpdated")
 . set isFailed=(cxChangeKind(queryId)="QueryFailed")
 . set rehydrating=$get(subAwaitingRehydration(queryId))=1
 . ; A reconnect resends the whole active query set, so the server's first
 . ; Transition after it is exactly as likely to be a genuine rehydration of
 . ; the value the subscriber already has as a real change. Only a
 . ; byte-identical QueryUpdated during that one rehydration window is
 . ; suppressed; an error is never suppressed (the caller must still learn a
 . ; reconnect reproduced a failing query), and any later Transition on this
 . ; subscription is a normal update again.
 . set suppress=isUpdated&rehydrating&($get(subValue(queryId))=cxChangeValue(queryId))
 . if isUpdated!isFailed kill subAwaitingRehydration(queryId)
 . if isUpdated,'suppress set subValue(queryId)=cxChangeValue(queryId)
 . if isUpdated,'suppress set subLogs(queryId)=cxChangeLogs(queryId)
 . if isUpdated,'suppress kill subErrName(queryId),subErrMsg(queryId),subErrData(queryId)
 . if isUpdated,'suppress set subHasValue(queryId)=1,subVersion(queryId)=$get(subVersion(queryId),0)+1
 . if isFailed set subErrName(queryId)="FunctionError",subErrMsg(queryId)=cxChangeMessage(queryId)
 . if isFailed set subErrData(queryId)=cxChangeData(queryId),subLogs(queryId)=cxChangeLogs(queryId)
 . if isFailed kill subValue(queryId)
 . if isFailed set subHasValue(queryId)=1,subVersion(queryId)=$get(subVersion(queryId),0)+1
 quit 1
 ;
liveChange(change,kind,queryId)
 new logsNode,logs,valueNode,msgNode,dataNode
 set logsNode=$$jFind(change,"logLines")
 set logs=$select(logsNode<0:"[]",1:$$encodeLogs(logsNode))
 if logs="" do  quit 0
 . do liveRetire("ProtocolError","Live logLines must be an array of strings")
 if kind="QueryUpdated" do  quit 1
 . set valueNode=$$jFind(change,"value")
 . if valueNode<0 do  quit
 . . do liveRetire("ProtocolError","QueryUpdated has no value")
 . . set cxChangeValue(queryId)="null"
 . set cxChangeValue(queryId)=$$jEncode(valueNode),cxChangeLogs(queryId)=logs
 if kind="QueryFailed" do  quit 1
 . set msgNode=$$jFind(change,"errorMessage"),dataNode=$$jFind(change,"errorData")
 . if msgNode<0!($$jType(msgNode)'="string") do  quit
 . . do liveRetire("ProtocolError","QueryFailed has no error message")
 . set cxChangeMessage(queryId)=$$jText(msgNode)
 . set cxChangeData(queryId)=$select(dataNode>=0:$$jEncode(dataNode),1:"null")
 . set cxChangeLogs(queryId)=logs
 if kind="QueryRemoved" quit 1
 do liveRetire("ProtocolError","unsupported Live modification: "_kind)
 quit 0
 ;
 ; A transport or protocol fault retires the socket but keeps every
 ; subscription: liveMaybeReconnect() (polled from livePump on every adapter
 ; loop tick) replays the whole active set on the next successful connect.
 ; cxLiveRetryAt is reset to "now" so the very next reconnect attempt is
 ; immediate, at the base backoff -- a drop from a previously healthy
 ; connection should not inherit a stale, grown delay from some earlier,
 ; unrelated run of failures (liveConnect() already resets cxLiveBackoffMs
 ; itself on the next success; this only controls the timing of that attempt).
liveRetire(name,message)
 if cxLiveSocket'="" do sockClose(cxLiveSocket)
 set cxLiveSocket=""
 set cxLiveRemoteQuerySet=0,cxLiveRemoteIdentity=0,cxLiveRemoteTimestamp=cxLiveInitialTimestamp
 set cxLiveQuerySetVersion=0
 set cxLiveLastClose=message
 set cxErrTransport=$$fail(name,message)
 set cxLiveRetryAt=$$nowMs()
 quit
 ;
 ; Reconnect-on-drop with exponential backoff. Only attempts a connection
 ; when one is actually wanted (at least one subscription is registered) and
 ; the backoff window has elapsed; a fresh subscribe() with no active
 ; connection still goes straight through liveEnsureConnection() rather than
 ; waiting on this schedule. A failed attempt here reuses liveConnect()'s own
 ; failure bookkeeping and only advances the backoff timer -- it never
 ; surfaces an error to a caller, since nothing is waiting synchronously on a
 ; background reconnect.
liveMaybeReconnect()
 new qid,ok
 if cxLiveSocket'="" quit
 if $$nowMs()<cxLiveRetryAt quit
 set qid=$order(subPath(""))
 if qid="" quit
 set ok=$$liveConnect()
 if ok quit
 ; liveConnect() already recorded the failure reason in cxLiveLastClose;
 ; this only schedules the next attempt, doubling the wait up to the cap.
 set cxLiveRetryAt=$$nowMs()+cxLiveBackoffMs
 set cxLiveBackoffMs=cxLiveBackoffMs*2
 if cxLiveBackoffMs>cxLiveBackoffMaxMs set cxLiveBackoffMs=cxLiveBackoffMaxMs
 quit
 ;
 ; Pump the Live socket for up to timeoutMs, first giving a dropped
 ; connection a chance to reconnect. Returns "ok" if a message was
 ; processed, "timeout" if nothing arrived (including while merely waiting
 ; out backoff), "retired" if the connection just failed (subscriptions
 ; remain registered for the next connect attempt).
livePump(timeoutMs)
 new deadline,outcome,opcode,payload
 do liveMaybeReconnect()
 if cxLiveSocket="" quit "timeout"
 set deadline=$$nowMs()+timeoutMs
 set outcome=$$wsRecvMessage(cxLiveSocket,deadline,.opcode,.payload)
 if outcome="timeout" quit "timeout"
 if outcome="ok" do  quit "ok"
 . new discard set discard=1
 . if opcode=1 set discard=$$liveHandleMessage(payload)
 do liveRetire("TransportError","the Live connection closed")
 quit "retired"
 ;
 ; Block until `tag`'s subscription has published a new value or error, or
 ; timeoutMs elapses. Used by the canonical example, which only ever needs
 ; the next update on one subscription rather than the adapter's general
 ; multi-subscription fan-out.
waitUpdate(tag,timeoutMs,hasError,errName,errMsg,value)
 new deadline,queryId,startVersion,outcome
 set deadline=$$nowMs()+timeoutMs
 if '$data(tagToQid(tag)) quit $$fail("ClientError","unknown subscription tag")
 set queryId=tagToQid(tag)
 set startVersion=$get(subVersion(queryId),0)
 for  do  quit:$get(subVersion(queryId),0)'=startVersion  quit:$$remaining(deadline)=0
 . set outcome=$$livePump($$remaining(deadline))
 if $get(subVersion(queryId),0)=startVersion quit $$fail("TransportError","timed out waiting for a Live update")
 set hasError=$data(subErrName(queryId))>0
 if hasError do  quit 1
 . set errName=subErrName(queryId),errMsg=subErrMsg(queryId)
 set value=subValue(queryId)
 quit 1
 ;
closeLive(timeoutMs)
 new tag
 if cxLiveSocket'="" do
 . new wok set wok=$$wsSend(cxLiveSocket,8,"",timeoutMs)
 . do sockClose(cxLiveSocket)
 set cxLiveSocket=""
 set tag=""
 for  set tag=$order(tagToQid(tag)) quit:tag=""  do
 . new qid set qid=tagToQid(tag)
 . kill subPath(qid),subArgs(qid),subTag(qid),subValue(qid),subLogs(qid)
 . kill subErrName(qid),subErrMsg(qid),subErrData(qid),subHasValue(qid),subVersion(qid)
 . kill subAwaitingRehydration(qid)
 kill tagToQid
 quit
