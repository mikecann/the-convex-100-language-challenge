Rebol [
    Title: "json.r3 regression test"
    Purpose: {
        client/json.r3 exists because Rebol/Bulk's own `to-json` mis-encodes
        logic! values and `none`, which Convex's wire protocol needs
        correctly as JSON booleans and null. This proves the hand-rolled
        reader/writer round-trips ordinary values, rejects malformed input
        the same way a strict JSON parser must, and implements AGENTS.md's
        integral-decimal rule for Convex number fields: `0`/`0.0`/`1e3` all
        accepted as integral when in range; a fractional, quoted, or
        overflowing value rejected.
    }
]

do %../json.r3

failures: 0
checks: 0

;; NOTE: this must be FUNC, not FUNCTION -- FUNCTION auto-declares every
;; bare set-word in its body (including `checks:`/`failures:`) as a new
;; function-local variable, which would silently shadow the counters
;; below instead of incrementing them. FUNC has no such auto-locals.
check: func [condition [logic!] label [string!]] [
    checks: checks + 1
    unless condition [
        failures: failures + 1
        print ["FAIL --" label]
    ]
]

;; NOTE: `(some-call ...)/field` does NOT apply `/field` to the call's
;; result in this build -- a `/word` immediately after a closing paren
;; lexes as its own standalone refinement-literal value, not a path
;; continuation, and is silently discarded by whatever evaluated the
;; paren. Every accessor below binds the intermediate result to a real
;; word first and paths off that word instead.

;; round-trips a JSON literal through decode then encode and returns the
;; re-encoded text (or an "<error: ...>" marker on a decode failure).
round-trip: function [text [string!]] [
    outcome: json-decode text
    either outcome/ok [json-encode outcome/value] [rejoin ["<error: " outcome/reason ">"]]
]

decode-fails?: function [text [string!]] [
    outcome: json-decode text
    not outcome/ok
]

;; the decoded value of a JSON literal that is expected to parse cleanly.
decoded: function [text [string!]] [
    outcome: json-decode text
    outcome/value
]

;; the first element of a decoded JSON array literal.
decoded-first: function [text [string!]] [
    first decoded text
]

;; ---- structural round trips -------------------------------------------
check ((round-trip "{}") == "{}") "empty object round trip"
check ((round-trip "[]") == "[]") "empty array round trip"
check ((round-trip {  {"a"  :  1 } }) == {{"a":1}}) "surrounding and internal whitespace is ignored"
check ((round-trip {{"a":[1,2,{"b":null}],"c":true}}) == {{"a":[1,2,{"b":null}],"c":true}}) "nested object/array/null/bool round trip"
check ((round-trip {{"room":"r","count":0,"lastLanguage":null}}) == {{"room":"r","count":0,"lastLanguage":null}}) "Convex-shaped state object round trip"

;; a nested array/object inside an array must stay nested, not flatten
;; into the parent (this is exactly what APPEND/ONLY in json.r3 exists to
;; prevent).
inner: decoded {[1,[2,3],{"x":4}]}
check (3 = length? inner) "outer array keeps 3 elements, not flattened"
check (block? inner/2) "nested array element is still a block"
check (map? inner/3) "nested object element is still a map"

;; ---- numbers ------------------------------------------------------------
check (integer? decoded "0") "bare 0 decodes as integer!"
check (decimal? decoded "0.0") "0.0 decodes as decimal!, not integer!"
check ((round-trip "42") == "42") "plain integer round trip"
check ((round-trip "-42") == "-42") "negative integer round trip"
check ((decoded "1e3") = 1000.0) "exponent form evaluates correctly"
check (decode-fails? "01") "a leading zero is rejected"
check (decode-fails? "1.") "a bare decimal point is rejected"
check (decode-fails? "-") "a bare minus sign is rejected"
check (decode-fails? "1.2.3") "a malformed number is rejected"

;; ---- strings --------------------------------------------------------------
check ((round-trip {["Hello, world"]}) == {["Hello, world"]}) "plain ASCII string round trip"
check ((decoded-first {["é"]}) = "é") {a \u escape and a literal UTF-8 byte both decode to the same character}
check ((decoded-first {["👋"]}) = "👋") "a surrogate pair decodes to one code point"
check ((round-trip {["tab\there"]}) == {["tab\there"]}) "tab is escaped on the way back out"
check ((decoded-first {["quote\"slash\\end"]}) = {quote"slash\end}) "quote and backslash escapes decode correctly"
check ((decoded-first {["solidus\/ok"]}) = "solidus/ok") "an escaped solidus decodes to a plain one"
check (decode-fails? {["\ud83d"]}) "an unpaired high surrogate is rejected"
check (decode-fails? {["\udc4b"]}) "an unpaired low surrogate is rejected"
check (decode-fails? {["\x41"]}) "an unrecognised escape is rejected"
check (decode-fails? {["unterminated}) "an unterminated string is rejected"
raw-control: rejoin [{["raw} to-char 9 {control"]}]
check (decode-fails? raw-control) "a raw unescaped control byte is rejected"

;; ---- rejections -----------------------------------------------------------
check (decode-fails? {{"a":1} trailing}) "trailing content after the value is rejected"
check (decode-fails? {{"a":}}) "a missing value is rejected"
check (decode-fails? {{a:1}}) "an unquoted key is rejected"
check (decode-fails? {[1,]}) "a dangling comma is rejected"
check (decode-fails? {[1 2]}) "a missing comma is rejected"
check (decode-fails? {nul}) "a truncated keyword is rejected"
check (decode-fails? {True}) "keyword matching is case-sensitive"

;; a control byte with no named JSON escape (backslash-n, r, t, b, f) falls
;; back to the generic backslash-u00XX form.
bell: copy ""
append bell to-char 7
expected-bell-json: rejoin ["^"" "\u0007" "^""]
check ((json-encode bell) == expected-bell-json) "an unnamed control byte encodes as \u00XX"

;; ---- booleans and null: exactly what to-json gets wrong ------------------
check ((json-encode true) == "true") "logic! true encodes to JSON true"
check ((json-encode false) == "false") "logic! false encodes to JSON false"
check ((json-encode none) == "null") "none encodes to JSON null"
check ((decoded "true") = true) "JSON true decodes to logic! true"
check ((decoded "false") = false) "JSON false decodes to logic! false"
check (none? decoded "null") "JSON null decodes to none"

;; ---- AGENTS.md's integral-decimal rule for Convex number fields ----------
check (convex-integral? 0) "integer 0 is integral"
check (convex-integral? 0.0) "decimal 0.0 is integral"
check (convex-integral? 1.0) "decimal 1.0 is integral"
check (convex-integral? -3) "negative integer is integral"
check (convex-integral? 1000.0) "value decoded from exponent form is integral"
check (not convex-integral? 0.5) "0.5 is not integral"
check (not convex-integral? 42.25) "a fractional value is not integral"
check (convex-integral? 9007199254740992) "exactly the safe-integer bound is accepted"
check (not convex-integral? 9007199254740993) "one past the safe-integer bound is rejected"
check (not convex-integral? -9007199254740993) "one past the negative safe-integer bound is rejected"
check (not convex-integral? "1") "a quoted value is not integral (wrong type entirely)"
check (not convex-integral? none) "null is not integral"
check (not convex-integral? true) "a boolean is not integral"
check (0 = convex-integral-to-integer 0.0) "0.0 converts to integer 0"
check (1 = convex-integral-to-integer 1.0) "1.0 converts to integer 1"
check (1000 = convex-integral-to-integer 1000.0) "exponent-derived 1000.0 converts to integer 1000"

;; the exact shape a Convex counter query response takes: a JSON object
;; whose "value" field may arrive as 0 or 0.0 -- both must be usable as
;; the same REBOL integer once decoded.
foreach text ["0" "0.0"] [
    json-text: rejoin ["{^"value^":" text "}"]
    field: select decoded json-text "value"
    check (convex-integral? field) rejoin ["Convex value " text " is accepted as integral"]
    check (0 = convex-integral-to-integer field) rejoin ["Convex value " text " converts to REBOL integer 0"]
]

print rejoin [checks " checks, " failures " failures"]
either failures = 0 [
    print "ALL TESTS PASSED"
    quit/return 0
] [
    quit/return 1
]
