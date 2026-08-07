\ json-test.fth - the strict JSON reader and writer, and the small primitives
\ the WebSocket handshake and the sync profile depend on.
\
\ The number cases matter most. Convex may send an integral count in decimal
\ form, so `0` and `0.0` must be the same value, while `0.5`, a quoted number
\ and anything outside a signed cell must be refused at the point of use rather
\ than rounded into something plausible.

require test-support.fth

json-new constant test-doc
1024 buf-new constant scratch

: probe-parse ( -- )  probe@ test-doc json-parse ;

: parse-raises ( addr u name-addr name-u -- )
    2>r >probe ['] probe-parse 2r> raises ;

: parse-ok ( addr u name-addr name-u -- )
    2>r >probe ['] probe-parse 2r> succeeds ;

: field ( key-addr key-u -- doc node )
    { key-addr key-count }
    test-doc dup dup doc-root key-addr key-count json-get ;

: field-integer ( key-addr key-u -- value flag )  field json-integer ;

: integral ( text-addr text-u expected name-addr name-u -- )
    0 0 { text-addr text-count expected name-addr name-count value good }
    text-addr text-count test-doc json-parse
    s" v" field-integer to good to value
    good value expected = and  name-addr name-count ok ;

: not-integral ( text-addr text-u name-addr name-u -- )
    0 { text-addr text-count name-addr name-count good }
    text-addr text-count test-doc json-parse
    s" v" field-integer drop to good
    good 0=  name-addr name-count ok ;

\ ---------------------------------------------------------------------------

: test-numbers ( -- )
    s| {"v":0}| 0 s" plain zero" integral
    s| {"v":0.0}| 0 s" integral zero in decimal form" integral
    s| {"v":1.0}| 1 s" integral one in decimal form" integral
    s| {"v":-7}| -7 s" negative integer" integral
    s| {"v":1e2}| 100 s" positive exponent" integral
    s| {"v":1500e-2}| 15 s" negative exponent that stays integral" integral
    s| {"v":9223372036854775807}| 9223372036854775807
        s" largest signed cell" integral
    s| {"v":0.5}| s" fractional value is not integral" not-integral
    s| {"v":1e-1}| s" fractional exponent is not integral" not-integral
    s| {"v":"0"}| s" quoted number is not a number" not-integral
    s| {"v":9223372036854775808}| s" overflowing value is not integral"
        not-integral
    s| {"v":1e40}| s" overflowing exponent is not integral" not-integral
    s| {"v":01}| s" leading zero" parse-raises
    s| {"v":.5}| s" bare decimal point" parse-raises
    s| {"v":1.}| s" trailing decimal point" parse-raises
    s| {"v":NaN}| s" NaN is not JSON" parse-raises
    s| {"v":Infinity}| s" Infinity is not JSON" parse-raises ;

: test-strictness ( -- )
    s| {"a":1}| s" ordinary object" parse-ok
    s| {"a":1} junk| s" trailing bytes" parse-raises
    s| {"a":1,"a":2}| s" duplicate key" parse-raises
    s| {"a":1,}| s" trailing comma" parse-raises
    s| [1,2,3]| s" array" parse-ok
    s\" {\"a\":\"line\nbreak\"}" s" raw control byte in string" parse-raises
    s| {"a":"\uD800"}| s" lone high surrogate" parse-raises
    s| {"a":"\uDC00"}| s" lone low surrogate" parse-raises
    s| {"a":"😀"}| s" literal astral character" parse-ok
    s| {"a":"\q"}| s" unknown escape" parse-raises ;

: test-depth ( -- )
    0 { text }
    2048 buf-new to text
    cvx-max-json-depth 2 + 0 ?do [char] [ text buf-char loop
    cvx-max-json-depth 2 + 0 ?do [char] ] text buf-char loop
    text buf-span s" nesting beyond the depth limit" parse-raises
    text buf-free ;

: test-spans ( -- )
    0 0 { doc node }
    s| {"v":{"count":2},"w":[1,2]}| test-doc json-parse
    s" v" field to node to doc
    doc node json-raw s| {"count":2}| s" object span is exact source text" same
    s" w" field to node to doc
    doc node json-raw s| [1,2]| s" array span is exact source text" same ;

: test-strings ( -- )
    0 0 { doc node }
    s| {"v":"a\u00e9z"}| test-doc json-parse
    s" v" field to node to doc
    doc node json-string@ s\" a\xC3\xA9z" s" \u escape decodes to UTF-8" same
    s| {"v":"\ud83d\ude00"}| test-doc json-parse
    s" v" field to node to doc
    doc node json-string@ s\" \xF0\x9F\x98\x80"
    s" surrogate pair decodes to four bytes" same ;

: test-utf8 ( -- )
    s\" \xC3\xA9" utf8-valid? s" two-byte sequence is valid" ok
    s\" \xC0\xAF" utf8-valid? 0= s" overlong encoding is rejected" ok
    s\" \xED\xA0\x80" utf8-valid? 0= s" surrogate is rejected" ok
    s\" \xF5\x80\x80\x80" utf8-valid? 0= s" beyond U+10FFFF is rejected" ok
    s\" \xE2\x82" utf8-valid? 0= s" truncated sequence is rejected" ok ;

: test-writer ( -- )
    scratch dup buf-reset jw-start
    jw{
        s" a" s\" q\"\\\n" jw-pair-string
        s" b" 12 jw-pair-uint
        s" c" true jw-pair-bool
        s" d" s| [1,2]| jw-pair-raw
    jw}
    scratch buf-span
    s| {"a":"q\"\\\n","b":12,"c":true,"d":[1,2]}|
    s" writer escapes and separators" same
    scratch buf-span s" writer output re-parses" parse-ok ;

: test-log-lines ( -- )
    0 0 { doc node }
    s| {"v":["a","b"]}| test-doc json-parse
    s" v" field to node to doc
    doc node json-log-lines? s" array of strings is accepted" ok
    s| {"v":["a",1]}| test-doc json-parse
    s" v" field to node to doc
    doc node json-log-lines? 0= s" array with a non-string is rejected" ok ;

\ ---------------------------------------------------------------------------
\ Primitives used by the WebSocket handshake and the sync profile
\ ---------------------------------------------------------------------------

create digest-scratch 20 allot

: test-sha1 ( -- )
    s" abc" digest-scratch sha1
    scratch buf-reset
    digest-scratch 20 scratch bytes>buf-hex
    scratch buf-span s" a9993e364706816aba3e25717850c26c9cd0d89d"
    s" SHA-1 of abc" same
    s" " digest-scratch sha1
    scratch buf-reset
    digest-scratch 20 scratch bytes>buf-hex
    scratch buf-span s" da39a3ee5e6b4b0d3255bfef95601890afd80709"
    s" SHA-1 of the empty string" same ;

: test-base64 ( -- )
    scratch buf-reset s" abc" scratch base64-encode
    scratch buf-span s" YWJj" s" base64 of three bytes" same
    scratch buf-reset s" ab" scratch base64-encode
    scratch buf-span s" YWI=" s" base64 with one pad" same
    scratch buf-reset s" a" scratch base64-encode
    scratch buf-span s" YQ==" s" base64 with two pads" same ;

: probe-timestamp ( -- )  probe@ timestamp-decode drop ;

: timestamp-raises ( addr u name-addr name-u -- )
    2>r >probe ['] probe-timestamp 2r> raises ;

: test-timestamps ( -- )
    0 { value }
    s" AAAAAAAAAAA=" timestamp-decode to value
    value 0 s" the initial timestamp decodes to zero" same-n
    scratch buf-reset
    1700000000000000000 scratch timestamp-encode
    scratch buf-span timestamp-decode 1700000000000000000
    s" a realistic timestamp round-trips" same-n
    s" AAAAAAAAAAA" s" a timestamp must be twelve characters" timestamp-raises
    s" AAAAAAAAAAB=" s" padding bits must be zero" timestamp-raises
    s" AAAAAAAAAA!=" s" invalid base64 is rejected" timestamp-raises ;

: test-strings-helpers ( -- )
    s" 1234" str>u drop 1234 s" decimal parse" same-n
    s" 12a4" str>u nip 0= s" non-digits are rejected" ok
    s" 1f" str>hex drop 31 s" hexadecimal parse" same-n
    s"   padded  " str-trim s" padded" s" trim removes blanks" same
    s" Content-Length" s" content-length" istr=
    s" header comparison folds case" ok ;

test-numbers
test-strictness
test-depth
test-spans
test-strings
test-utf8
test-writer
test-log-lines
test-sha1
test-base64
test-timestamps
test-strings-helpers

s" json-test" tests-done
0 convex-exit
