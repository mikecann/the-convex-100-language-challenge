#!/usr/local/bin/apl --script
⍝ Language-local unit tests for the GNU APL Convex client: JSON
⍝ encode/decode, HTTP request/response framing helpers, and the
⍝ environment-variable helper -- everything that does not need a
⍝ network connection. HTTP against a real backend is exercised by
⍝ verify-example/verify, not here.

)COPY /opt/convex/client/convex.apl

⍝ Counts failures instead of stopping at the first one, so a single run
⍝ reports everything wrong rather than just the first symptom.
FAILCOUNT←0

∇AssertEq PARAMS;GOT;WANT;LABEL
  GOT←1⊃PARAMS
  WANT←2⊃PARAMS
  LABEL←3⊃PARAMS
  →(GOT≡WANT)⍴0
  FAILCOUNT←FAILCOUNT+1
  'FAIL: ',LABEL,': got ',(⍕GOT),' want ',(⍕WANT)
∇

⍝ ---- JSON round trip ----
AssertEq (JStringify JParseDocument '{"a":1,"b":[1,2,3],"c":"hi","d":true,"e":false,"f":null,"g":-2.5}') '{"a":1,"b":[1,2,3],"c":"hi","d":true,"e":false,"f":null,"g":-2.5}' 'json round trip'

⍝ ---- JSON string escaping ----
AssertEq (JEscapeString 'a"b\c') '"a\"b\\c"' 'json escape quote+backslash'
AssertEq (JEscapeString (⎕UCS 10),'x') '"\nx"' 'json escape newline'

⍝ ---- JSON object field access ----
AssertEq ('count' JGet JParseDocument '{"count":0,"room":"x"}') ('n' 0) 'json object field lookup'
AssertEq ('missing' JHas JParseDocument '{"count":0}') 0 'json object missing key'

⍝ ---- whole-number acceptance (Convex integral-decimal numbers) ----
AssertEq (JWholeNumber 'n' 0) 0 'whole number accepts integral zero'
AssertEq (JWholeNumber 'n' 1) 1 'whole number accepts integral one'
AssertEq (JWholeNumber 'n' 1.5) ¯1 'whole number rejects fraction'
AssertEq (JWholeNumber 's' 'x') ¯1 'whole number rejects non-number'

⍝ ---- URL parsing ----
AssertEq (2⊃UrlParse 'https://example.com') (1 'example.com' 443) 'url parse https default port'
AssertEq (2⊃UrlParse 'http://backend:3210') (0 'backend' 3210) 'url parse http explicit port'

⍝ ---- HTTP status-line word split ----
AssertEq (HttpStatusCode 'HTTP/1.1 200 OK') 200 'http status code extraction'

⍝ ---- header value stripping ----
AssertEq (HStrip '  application/json  ') 'application/json' 'header value strip'

⍝ ---- chunked-body hex sizes ----
AssertEq (HexToDec 'a') 10 'hex to dec single digit'
AssertEq (HexToDec '1a2b') 6699 'hex to dec multi digit'

⍝ ---- environment variable helper ----
AssertEq (EnvGet 'CONVEX_CLIENT_SELFTEST_UNSET_VAR') '' 'env get unset variable'

⍝ ---- HttpClassify: success and structured error envelopes ----
AssertEq (HttpClassify (200 '{"status":"success","value":{"count":1}}')) '{"type":"result","value":{"count":1},"logs":[]}' 'http classify success'
AssertEq (HttpClassify (200 '{"status":"success","value":{"count":1},"logLines":["log one"]}')) '{"type":"result","value":{"count":1},"logs":["log one"]}' 'http classify success with logs'
AssertEq (HttpClassify (200 '{"status":"error","errorMessage":"boom"}')) '{"type":"error","error":{"name":"FunctionError","message":"boom","data":null}}' 'http classify function error'
AssertEq (HttpClassify (200 '{"status":"error","errorMessage":"boom","errorData":{"code":"X"}}')) '{"type":"error","error":{"name":"FunctionError","message":"boom","data":{"code":"X"}}}' 'http classify function error with data'
AssertEq (HttpClassify (500 '')) '{"type":"error","error":{"name":"TransportError","message":"unexpected HTTP status 500"}}' 'http classify transport error'

⍝ Top-level (non-function) script code apparently can't use labels/
⍝ branches directly in this GNU APL build ("Illegal : in immediate
⍝ execution"), unlike inside a ∇...∇ function, so the pass/fail report
⍝ itself is a small function.
∇ReportResults
  →(FAILCOUNT=0)⍴PASS
  'FAILED: ',(⍕FAILCOUNT),' assertion(s)'
  →0
PASS:
  'ALL TESTS PASSED'
∇
ReportResults
)OFF
