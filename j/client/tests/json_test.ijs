NB. json_test.ijs -- round trips, verbatim number literals, escapes and
NB. surrogate pairs, and rejection of malformed input.

load '/project/client/json.ijs'

TEST_FAILED=: 0

test_fail=: 3 : 0
  TEST_FAILED=: 1
  echo 'FAIL: ', y
  i. 0
)

NB. Parses `input`, re-encodes the result, and checks it against `want`.
check_roundtrip=: 3 : 0
  'label input want'=. y
  r=. cx_json_parse input
  ok=. > 0 { r
  if. -. ok do.
    test_fail label, ': parse failed: ', > 1 { r return.
  end.
  v=. > 1 { r
  out=. cx_json_encode v
  if. -. out -: want do.
    test_fail label, ': got [', out, '] want [', want, ']' return.
  end.
  i. 0
)

check_rejected=: 3 : 0
  'label input'=. y
  r=. cx_json_parse input
  ok=. > 0 { r
  if. ok do.
    test_fail label, ': unexpectedly parsed as [', (cx_json_encode > 1 { r), ']' return.
  end.
  i. 0
)

main=: 3 : 0
check_roundtrip 'object';'{"a":1,"b":"hello","c":[1,2,3],"d":true,"e":false,"f":null}';'{"a":1,"b":"hello","c":[1,2,3],"d":true,"e":false,"f":null}'
check_roundtrip 'nested';'{"a":[],"b":{},"c":{"x":1.5e10}}';'{"a":[],"b":{},"c":{"x":1.5e10}}'
check_roundtrip 'empty object';'{}';'{}'
check_roundtrip 'empty array';'[]';'[]'
check_roundtrip 'escapes';'"line1\nline2\ttab\"quote\\back"';'"line1\nline2\ttab\"quote\\back"'
copyright_text=. '"copy ', (194 169 { a.), ' sign"'
check_roundtrip 'raw utf8 copyright sign';copyright_text;copyright_text
emoji_text=. '"e ', (240 159 152 128 { a.), ' e"'
check_roundtrip 'raw utf8 emoji';emoji_text;emoji_text

NB. \u escapes are a separate code path from raw passthrough (jp_hex4 and
NB. the surrogate-pair math in jp_string), so they get their own literal
NB. backslash-u source text rather than an embedded raw character.
check_roundtrip 'backslash-u escape (copyright)';'"copy \u00A9 sign"';copyright_text
check_roundtrip 'backslash-u surrogate pair (emoji)';'"e \uD83D\uDE00 e"';emoji_text
check_rejected 'unpaired low surrogate';'"\udc00"'
check_rejected 'unpaired high surrogate at end of string';'"\ud800"'
check_roundtrip 'negative integer';'-42';'-42'
check_roundtrip 'float';'3.14159';'3.14159'
check_roundtrip 'exponent';'1.5e-10';'1.5e-10'
check_roundtrip 'big integer verbatim';'9007199254740993';'9007199254740993'
passthrough_text=. '"caf', (195 169 { a.), '"'
check_roundtrip 'raw utf8 passthrough';passthrough_text;passthrough_text

check_rejected 'trailing comma';'{"a":1,}'
check_rejected 'unterminated string';'"abc'
check_rejected 'leading zero';'01'
check_rejected 'duplicate key';'{"a":1,"a":2}'
check_rejected 'lone high surrogate';'"\ud83d"'
check_rejected 'trailing content';'{}x'
check_rejected 'control char in string';'"line1', LF, 'line2"'
check_rejected 'not a value';''
check_rejected 'unclosed array';'[1,2'
check_rejected 'colon missing';'{"a" 1}'

NB. Convex request-body shape, matching the documented HTTP envelope.
mark=. cx_json_parse '{"path":"demo:state","args":{"room":"r1"},"format":"json"}'
if. -. (cx_json_encode > 1 { mark) -: '{"path":"demo:state","args":{"room":"r1"},"format":"json"}' do.
  test_fail 'convex request shape did not round trip'
end.

NB. jfind
obj=. > 1 { cx_json_parse '{"status":"success","value":{"count":5},"logLines":["a","b"]}'
status=. obj jfind 'status'
if. -. (cx_json_encode > status) -: '"success"' do. test_fail 'jfind status wrong' end.
missing=. obj jfind 'nope'
if. missing ~: _1 do. test_fail 'jfind missing key did not return _1' end.


exit TEST_FAILED
)
main ''
