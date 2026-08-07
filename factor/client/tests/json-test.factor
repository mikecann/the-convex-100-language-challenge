! Strict JSON scanning tests.
!
! These cover the boundaries a Convex client actually meets: exact subtree
! extraction, the integral-decimal spelling Convex uses for whole numbers,
! and the malformed or oversized documents a drifting peer can send.

USING: kernel locals math sequences strings convex.json
convex.tests.support ;
IN: convex.tests.json

: test-well-formed ( -- )
    "{\"a\":1}" json-text? t "object" check-equal
    "[1,2,3]" json-text? t "array" check-equal
    "\"x\"" json-text? t "string" check-equal
    "true" json-text? t "true" check-equal
    "null" json-text? t "null" check-equal
    "-12.5" json-text? t "negative float" check-equal
    " { \"a\" : [ ] } " json-text? t "whitespace" check-equal ;

: test-malformed ( -- )
    "{\"a\":1," json-text? f "trailing comma" check-equal
    "{a:1}" json-text? f "unquoted key" check-equal
    "{\"a\":01}" json-text? f "leading zero" check-equal
    "{\"a\":1e3}" json-text? f "exponent" check-equal
    "{\"a\":.5}" json-text? f "bare fraction" check-equal
    "{\"a\":1.}" json-text? f "empty fraction" check-equal
    "\"unterminated" json-text? f "unterminated string" check-equal
    "\"raw\ncontrol\"" json-text? f "raw control" check-equal
    "{\"a\":1}x" json-text? f "trailing content" check-equal
    "[1,]" json-text? f "empty array element" check-equal ;

! 91 and 93 are the bracket characters, spelled numerically so the literal
! never has to be read as a token inside a quotation.
: test-depth-bound ( -- )
    [
        200 91 <string> 200 93 <string> append check-json drop
    ] "deep nesting" check-raises ;

! Extraction must return the exact source text of a value, because that is
! how a Convex value reaches the controller byte-for-byte.
: test-field-extraction ( -- )
    "{\"a\":{\"b\":[1,2]},\"c\":\"x\"}" "a" json-field
    "{\"b\":[1,2]}" "nested object subtree" check-equal
    "{\"a\":{\"b\":[1,2]},\"c\":\"x\"}" "c" json-field
    "\"x\"" "string subtree" check-equal
    "{\"a\":1}" "missing" json-field f "absent field" check-equal
    "{\"a\\\"b\":1}" "a\"b" json-field "1" "escaped key" check-equal ;

: test-keys-and-elements ( -- )
    "{\"a\":1,\"b\":[2,3]}" json-keys { "a" "b" } "object keys" check-equal
    "[1,{\"x\":2},\"y\"]" json-elements
    { "1" "{\"x\":2}" "\"y\"" } "array elements" check-equal
    "[]" json-elements { } "empty array" check-equal ;

: test-string-values ( -- )
    "\"plain\"" json-string-value "plain" "plain string" check-equal
    "\"a\\nb\"" json-string-value "a\nb" "escaped newline" check-equal
    "\"\\u0041\"" json-string-value "A" "unicode escape" check-equal
    "\"\\ud83d\\udc4b\"" json-string-value 0 swap nth 128075
    "surrogate pair" check-equal
    [ "\"\\ud83d\"" json-string-value drop ] "lone surrogate" check-raises ;

: test-uint32 ( -- )
    "7" "x" json-uint32 7 "plain uint32" check-equal
    "0" "x" json-uint32 0 "zero" check-equal
    [ "\"7\"" "x" json-uint32 drop ] "quoted uint32" check-raises
    [ "true" "x" json-uint32 drop ] "boolean uint32" check-raises
    [ "07" "x" json-uint32 drop ] "leading zero uint32" check-raises
    [ "4294967296" "x" json-uint32 drop ] "uint32 overflow" check-raises
    [ f "x" json-uint32 drop ] "missing uint32" check-raises ;

! Convex may spell an integral count as 0.0 or 1.0. Accepting that while
! rejecting a real fraction is the regression this repository asks for.
: test-whole-numbers ( -- )
    "0" "c" json-whole-number 0 "integer zero" check-equal
    "0.0" "c" json-whole-number 0 "integral decimal zero" check-equal
    "1.0" "c" json-whole-number 1 "integral decimal one" check-equal
    "-3.00" "c" json-whole-number -3 "negative integral decimal" check-equal
    [ "1.5" "c" json-whole-number drop ] "fraction" check-raises
    [ "\"1\"" "c" json-whole-number drop ] "quoted number" check-raises
    [ "null" "c" json-whole-number drop ] "null number" check-raises
    [ "1e3" "c" json-whole-number drop ] "exponent number" check-raises
    [ "9223372036854775808" "c" json-whole-number drop ]
    "integer overflow" check-raises ;

: test-booleans ( -- )
    "true" "b" json-boolean t "true" check-equal
    "false" "b" json-boolean f "false" check-equal
    [ "\"true\"" "b" json-boolean drop ] "quoted boolean" check-raises ;

: test-encoding ( -- )
    "a\"b" json-escape-string "\"a\\\"b\"" "quote escape" check-equal
    "a\\b" json-escape-string "\"a\\\\b\"" "backslash escape" check-equal
    "a\nb" json-escape-string "\"a\\nb\"" "newline escape" check-equal
    1 0 <string> json-escape-string "\"\\u0000\"" "control escape" check-equal
    { { "k" "1" } { "s" "\"v\"" } } json-object
    "{\"k\":1,\"s\":\"v\"}" "object builder" check-equal
    { "1" "2" } json-array "[1,2]" "array builder" check-equal
    { } json-object "{}" "empty object" check-equal ;

! An escaped value must survive a round trip through the scanner unchanged.
! The sample is built from code points rather than source escapes so the test
! asserts the scanner's behaviour, not the Factor reader's.
:: test-round-trip ( -- )
    { 72 101 108 108 111 44 32 19990 30028 32 128075 } >string :> sample
    sample json-escape-string :> encoded
    encoded json-text? t "encoded text is valid JSON" check-equal
    encoded json-string-value sample "unicode round trip" check-equal ;

: run-json-tests ( -- )
    "json/well-formed" [ test-well-formed ] run-test
    "json/malformed" [ test-malformed ] run-test
    "json/depth-bound" [ test-depth-bound ] run-test
    "json/field-extraction" [ test-field-extraction ] run-test
    "json/keys-and-elements" [ test-keys-and-elements ] run-test
    "json/string-values" [ test-string-values ] run-test
    "json/uint32" [ test-uint32 ] run-test
    "json/whole-numbers" [ test-whole-numbers ] run-test
    "json/booleans" [ test-booleans ] run-test
    "json/encoding" [ test-encoding ] run-test
    "json/round-trip" [ test-round-trip ] run-test
    finish-tests ;

MAIN: run-json-tests
