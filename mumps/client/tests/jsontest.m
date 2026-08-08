jsontest ; JSON codec: parse/encode round trips, UTF-8 escapes, integral checks,
 ; quoting, and malformed-input rejection.
 ;
 do setup^convex
 new failures set failures=0
 new q set q=$char(34)
 ;
 new doc
 set doc="{"_q_"a"_q_":1,"_q_"b"_q_":[true,false,null,"_q_"hi"_$char(195,169)_"\n\"_q_q_"],"_q_"c"_q_":0.0,"_q_"n"_q_":-9007199254740992}"
 write "doc: ",doc,!
 new root
 set root=$$jParse^convex(doc)
 if root<0 do
 . write "PARSE FAILED: ",cxJErr," at pos ",cxJPos," of ",cxJLen,!
 . set failures=failures+1
 else  do
 . new enc set enc=$$jEncode^convex(root)
 . write "encoded: ",enc,!
 . new a set a=$$jFind^convex(root,"a")
 . if $$jType^convex(a)'="number"!($$jText^convex(a)'="1") write "FAIL a",! set failures=failures+1
 . new b set b=$$jFind^convex(root,"b")
 . if $$jType^convex(b)'="array"!($$jCount^convex(b)'=4) write "FAIL b count",! set failures=failures+1
 . new b4 set b4=$$jChild^convex(b,4)
 . if $$jType^convex(b4)'="string" write "FAIL b4 type ",$$jType^convex(b4),! set failures=failures+1
 . new want set want="hi"_$char(195,169)_$char(10)_q
 . if $$jText^convex(b4)'=want write "FAIL b4 text [",$$jText^convex(b4),"] want [",want,"]",! set failures=failures+1
 ;
 if $$integral^convex("0")'=1 write "FAIL integral 0",! set failures=failures+1
 if $$integral^convex("0.0")'=1 write "FAIL integral 0.0",! set failures=failures+1
 if $$integral^convex("1.5")'=0 write "FAIL integral 1.5",! set failures=failures+1
 if $$integral^convex("1e10")'=0 write "FAIL integral 1e10",! set failures=failures+1
 if $$integral^convex("9007199254740993")'=0 write "FAIL integral overflow",! set failures=failures+1
 ;
 new qtxt set qtxt="a"_q_"b\c"_$char(9)
 new qout set qout=$$jQuote^convex(qtxt)
 new qwant set qwant=q_"a\"_q_"b\\c\t"_q
 if qout'=qwant write "FAIL quote [",qout,"] want [",qwant,"]",! set failures=failures+1
 ;
 new bad set bad=$$jParse^convex("{"_q_"a"_q_":}")
 if bad'=-1 write "FAIL should reject malformed",! set failures=failures+1
 ;
 if failures=0 write "ALL JSON TESTS PASSED",!
 else  write failures," FAILURES",!
 zhalt $select(failures=0:0,1:1)
