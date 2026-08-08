NB. adapter_test.ijs -- local-only regression coverage for the conformance
NB. adapter's own protocol-shape helpers (client/tests/conformance/adapter.ijs
NB. is test infrastructure, not the public client, but AGENTS.md still asks
NB. for language-local coverage of serialized success, structured error, and
NB. close events -- gaps here are exactly what let a real crash reach shared
NB. conformance instead of a local test run).
NB.
NB. ADAPTER_AUTOEXEC=: 0 must be set *before* loading adapter.ijs: its last
NB. line is `if. ADAPTER_AUTOEXEC do. exit adapter_main '' end.`, and
NB. adapter_main opens a real Convex connection and blocks on stdin/TCP, which
NB. this test never wants.
ADAPTER_AUTOEXEC=: 0
load '/project/client/tests/conformance/adapter.ijs'

TEST_FAILED=: 0

test_fail=: 3 : 0
  TEST_FAILED=: 1
  echo 'FAIL: ', y
  i. 0
)

main=: 3 : 0

NB. ---------------------------------------------------------------------------
NB. adapter_id_valid -- regression for the crash this file was added for.
NB. sdlisten's mismarshalled boxed pair was one native-domain-error crash in
NB. this client; adapter_id_valid's stale `a. {~ value` re-conversion of
NB. already-character data was a second, unrelated one, reached only when an
NB. adapter_error response carries a request id at all (every structured
NB. HTTP/query error does). A plain short id like a real controller would
NB. send is exactly the case that went uncovered before this file existed.
NB. ---------------------------------------------------------------------------

if. -. adapter_id_valid 'q1' do. test_fail 'a short plain-ASCII id should validate' end.
if. -. adapter_id_valid 'hello' do. test_fail 'a longer plain-ASCII id should validate' end.
if. adapter_id_valid '' do. test_fail 'an empty id should not validate' end.
NB. UTF-8 for e-acute (U+00E9, a 2-byte sequence) -- a non-ASCII id must not
NB. crash the same codepoint-counting path plain ASCII happened to reach.
eacute_id=. 'id-', (195 169 { a.)
if. -. adapter_id_valid eacute_id do. test_fail 'a valid multi-byte UTF-8 id should validate' end.
NB. A lone continuation byte (0x80) is not valid UTF-8 at all.
if. adapter_id_valid 'id-', (128 { a.) do. test_fail 'an id containing invalid UTF-8 should not validate' end.
NB. 129 codepoints exceeds the documented 1-128 limit.
overlong_id=. 129 # 'a'
if. adapter_id_valid overlong_id do. test_fail 'a 129-codepoint id should not validate' end.

NB. ---------------------------------------------------------------------------
NB. adapter_error -- the structured-error shape a real query failure takes.
NB. This is the exact call adapter_call makes on a FunctionError, with the
NB. same id shape ("q1") the reproduction that found the crash above used.
NB. ---------------------------------------------------------------------------

errjson=. adapter_error 'q1';'FunctionError';'Intentional conformance failure';'{"code":"J_EXPECTED"}'
NB. E. is `needle E. haystack`, not the other way round.
if. -. +./ ('"id":"q1"' E. errjson) do. test_fail 'adapter_error should carry the request id' end.
if. -. +./ ('"type":"error"' E. errjson) do. test_fail 'adapter_error should be type error' end.
if. -. +./ ('"name":"FunctionError"' E. errjson) do. test_fail 'adapter_error should carry the error name' end.
if. -. +./ ('"code":"J_EXPECTED"' E. errjson) do. test_fail 'adapter_error should carry structured error data verbatim' end.

NB. An empty/invalid id must be omitted, not serialised as a bogus "id" field
NB. (matching the shared schema's "omit, never null" rule for optional
NB. members) -- and must not itself crash adapter_id_valid.
noidjson=. adapter_error '';'ProtocolError';'the controller sent invalid JSON';'null'
if. +./ ('"id"' E. noidjson) do. test_fail 'adapter_error should omit id when the id is empty' end.

NB. ---------------------------------------------------------------------------
NB. adapter_result -- the ordinary success shape, for contrast with the error
NB. path above.
NB. ---------------------------------------------------------------------------

okjson=. adapter_result 'q1';'42';'[]'
if. -. +./ ('"type":"result"' E. okjson) do. test_fail 'adapter_result should be type result' end.
if. -. +./ ('"value":42' E. okjson) do. test_fail 'adapter_result should carry the raw value JSON verbatim' end.

exit TEST_FAILED
)
main ''
