cryptotest ; SHA-1, base64, RFC 6455 accept-digest, and sync-timestamp compare
 ; known-answer tests.
 ;
 do setup^convex
 new failures set failures=0
 new hexDigits set hexDigits="0123456789abcdef"
 ;
 new digest set digest=$$sha1^convex("abc")
 new hex,i,b
 set hex=""
 for i=1:1:$length(digest) do
 . set b=$ascii(digest,i)
 . set hex=hex_$extract(hexDigits,(b\16)+1)_$extract(hexDigits,(b#16)+1)
 write "sha1(abc)=",hex,!
 if hex'="a9993e364706816aba3e25717850c26c9cd0d89" write "FAIL sha1 abc",! set failures=failures+1
 ;
 new digest2 set digest2=$$sha1^convex("")
 set hex=""
 for i=1:1:$length(digest2) do
 . set b=$ascii(digest2,i)
 . set hex=hex_$extract(hexDigits,(b\16)+1)_$extract(hexDigits,(b#16)+1)
 write "sha1(empty)=",hex,!
 if hex'="da39a3ee5e6b4b0d3255bfef95601890afd80709" write "FAIL sha1 empty",! set failures=failures+1
 ;
 new digest3 set digest3=$$sha1^convex("The quick brown fox jumps over the lazy dog")
 set hex=""
 for i=1:1:$length(digest3) do
 . set b=$ascii(digest3,i)
 . set hex=hex_$extract(hexDigits,(b\16)+1)_$extract(hexDigits,(b#16)+1)
 write "sha1(fox)=",hex,!
 if hex'="2fd4e1c67a2d28fced849ee1bb76e7391b93eb12" write "FAIL sha1 fox",! set failures=failures+1
 ;
 new b64 set b64=$$b64Encode^convex("Man")
 write "b64(Man)=",b64,!
 if b64'="TWFu" write "FAIL b64 Man",! set failures=failures+1
 new b64b set b64b=$$b64Encode^convex("M")
 write "b64(M)=",b64b,!
 if b64b'="TQ==" write "FAIL b64 M",! set failures=failures+1
 new rt set rt=$$b64Decode^convex($$b64Encode^convex("hello world!!"))
 write "roundtrip=[",rt,"]",!
 if rt'="hello world!!" write "FAIL roundtrip",! set failures=failures+1
 ;
 ; WebSocket handshake known example from RFC 6455 section 1.3
 new key set key="dGhlIHNhbXBsZSBub25jZQ=="
 new guid set guid="258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
 new accept set accept=$$b64Encode^convex($$sha1^convex(key_guid))
 write "accept=",accept,!
 if accept'="s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" write "FAIL RFC6455 accept",! set failures=failures+1
 ;
 ; Convex sync timestamps are little-endian base64 uint64: an all-zero
 ; timestamp compares below one whose low byte is 1, which in turn compares
 ; below one whose HIGH byte is 1 -- not just the low byte, which is what a
 ; (wrongly) big-endian compare would get right by accident.
 new tsZero set tsZero=$$b64Encode^convex($char(0,0,0,0,0,0,0,0))
 new tsOne set tsOne=$$b64Encode^convex($char(0,0,0,0,0,0,0,1))
 new tsHighByte set tsHighByte=$$b64Encode^convex($char(1,0,0,0,0,0,0,0))
 if $$tsCmp^convex(tsZero,tsOne)'=-1 write "FAIL tsCmp zero<one",! set failures=failures+1
 if $$tsCmp^convex(tsOne,tsZero)'=1 write "FAIL tsCmp one>zero",! set failures=failures+1
 if $$tsCmp^convex(tsZero,tsZero)'=0 write "FAIL tsCmp equal",! set failures=failures+1
 if $$tsCmp^convex(tsOne,tsHighByte)'=-1 write "FAIL tsCmp msb dominates",! set failures=failures+1
 ;
 if failures=0 write "ALL CRYPTO TESTS PASSED",!
 else  write failures," FAILURES",!
 zhalt $select(failures=0:0,1:1)
