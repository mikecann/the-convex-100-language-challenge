\ convex-json.fth - a strict JSON reader and writer written in Forth.
\
\ Two decisions shape this file.
\
\ First, it is strict on input. A Convex response is trusted only after it
\ parses, so trailing bytes, control characters inside strings, lone
\ surrogates, overlong UTF-8, duplicate object keys and unbounded nesting are
\ rejected rather than repaired. A lenient parser turns a protocol failure into
\ a plausible-looking value, which is exactly what the conformance harness
\ exists to catch.
\
\ Second, it never uses floating point. Convex may encode an integral number in
\ decimal form, so `0` and `0.0` are the same count. Rather than routing that
\ through a float and hoping the rounding is benign, a number is analysed as
\ text: its digits, decimal point position and exponent are combined exactly.
\ A value is accepted only when it is mathematically integral and fits a signed
\ 64-bit cell; fractional, non-finite and overflowing values are rejected.
\
\ Every node also records its exact span in the source text, so echoing a
\ Convex value back to the conformance controller is a byte copy of what the
\ server sent rather than a re-encoding that might normalise it.

require convex-config.fth
require convex-error.fth
require convex-buffer.fth

\ ---------------------------------------------------------------------------
\ Node and document representation
\ ---------------------------------------------------------------------------

0 constant json-null-type
1 constant json-false-type
2 constant json-true-type
3 constant json-number-type
4 constant json-string-type
5 constant json-array-type
6 constant json-object-type

0 cells constant nd>type
1 cells constant nd>ival     \ number value, string pool offset, or first child
2 cells constant nd>aux      \ number flags, string length, or child count
3 cells constant nd>next     \ next sibling, -1 at the end
4 cells constant nd>key-off  \ object member key, offset into the pool
5 cells constant nd>key-len
6 cells constant nd>raw-off  \ exact span of this value in the source text
7 cells constant nd>raw-len
8 cells constant nd-size

1 constant json-integral-flag   \ the number is integral and fits a cell

\ A document owns its nodes, its decoded text pool and a copy of the source,
\ because node spans point into that source.
0 cells constant doc>nodes
1 cells constant doc>count
2 cells constant doc>cap
3 cells constant doc>pool
4 cells constant doc>src
5 cells constant doc>root
6 cells constant doc-size

: doc-nodes ( doc -- addr )  doc>nodes + @ ;
: doc-count ( doc -- u )  doc>count + @ ;
: doc-pool ( doc -- buf )  doc>pool + @ ;
: doc-src ( doc -- buf )  doc>src + @ ;
: doc-root ( doc -- index )  doc>root + @ ;

: json-new ( -- doc )
    doc-size allocate throw { doc }
    64 nd-size * allocate throw doc doc>nodes + !
    0 doc doc>count + !
    64 doc doc>cap + !
    1024 buf-new doc doc>pool + !
    1024 buf-new doc doc>src + !
    -1 doc doc>root + !
    doc ;

: json-free ( doc -- )
    dup 0= if drop exit then
    dup doc-pool buf-free
    dup doc-src buf-free
    dup doc-nodes free throw
    free throw ;

: json-reset ( doc -- )
    dup doc-pool buf-reset
    dup doc-src buf-reset
    0 over doc>count + !
    -1 swap doc>root + ! ;

: json-node ( doc index -- addr )  nd-size *  swap doc-nodes + ;
: nd@ ( doc index field -- value )  >r json-node r> + @ ;
: nd! ( value doc index field -- )  >r json-node r> + ! ;

: json-alloc-node ( doc type -- index )
    0 0 { doc type index capacity }
    doc doc-count cvx-max-json-nodes u< 0= if
        s" JSON document has too many nodes" cvx-raise-protocol
    then
    doc doc-count doc doc>cap + @ u< 0= if
        doc doc>cap + @ 2* to capacity
        doc doc-nodes capacity nd-size * resize throw doc doc>nodes + !
        capacity doc doc>cap + !
    then
    doc doc-count to index
    index 1+ doc doc>count + !
    type doc index nd>type nd!
    \ -1, not 0: for an array or object this doubles as "first child", and an
    \ empty container must read as "no child" rather than pointing at node 0.
    -1 doc index nd>ival nd!
    0 doc index nd>aux nd!
    -1 doc index nd>next nd!
    0 doc index nd>key-off nd!
    0 doc index nd>key-len nd!
    0 doc index nd>raw-off nd!
    0 doc index nd>raw-len nd!
    index ;

\ ---------------------------------------------------------------------------
\ UTF-8
\ ---------------------------------------------------------------------------

: utf8-width ( lead -- width )      \ 0 when the byte cannot start a sequence
    dup 128 u< if drop 1 exit then
    dup 194 u< if drop 0 exit then
    dup 224 u< if drop 2 exit then
    dup 240 u< if drop 3 exit then
    245 u< if 4 else 0 then ;

\ Rejects overlong encodings, surrogate code points and anything above
\ U+10FFFF. Convex text arrives as UTF-8, and an invalid sequence is a
\ protocol failure rather than something to substitute a replacement
\ character into.
: utf8-valid? ( addr u -- flag )
    0 0 0 0 0 { addr count index lead width second ok }
    0 to index  true to ok
    begin ok index count u< and while
        addr index + c@ to lead
        lead utf8-width to width
        width 0= if
            false to ok
        else
            index width + count u> if
                false to ok
            else
                width 1 ?do
                    addr index i + + c@ 192 and 128 <> if false to ok leave then
                loop
                ok if
                    width 1 > if
                        addr index 1+ + c@ to second
                        width 3 = if
                            lead 224 = second 160 u< and if false to ok then
                            lead 237 = second 160 u< 0= and if false to ok then
                        then
                        width 4 = if
                            lead 240 = second 144 u< and if false to ok then
                            lead 244 = second 144 u< 0= and if false to ok then
                        then
                    then
                    index width + to index
                then
            then
        then
    repeat
    ok ;

: utf8-append ( codepoint buf -- )
    { point buf }
    point 128 u< if
        point buf buf-char
    else point 2048 u< if
        point 6 rshift 192 or buf buf-char
        point 63 and 128 or buf buf-char
    else point 65536 u< if
        point 12 rshift 224 or buf buf-char
        point 6 rshift 63 and 128 or buf buf-char
        point 63 and 128 or buf buf-char
    else
        point 18 rshift 240 or buf buf-char
        point 12 rshift 63 and 128 or buf buf-char
        point 6 rshift 63 and 128 or buf buf-char
        point 63 and 128 or buf buf-char
    then then then ;

\ ---------------------------------------------------------------------------
\ Scanner state
\
\ The client parses one document at a time on one thread, so the cursor lives
\ in module variables instead of being threaded through every recursive call.
\ ---------------------------------------------------------------------------

variable j-doc
variable j-src
variable j-len
variable j-pos
variable j-depth

: j-fail ( addr u -- )  cvx-raise-protocol ;

: j-end? ( -- flag )  j-pos @ j-len @ u< 0= ;
: j-peek ( -- c )  j-end? if -1 else j-src @ j-pos @ + c@ then ;
: j-at ( offset -- c )  j-src @ + c@ ;
: j-advance ( -- )  1 j-pos +! ;

: j-expect ( c -- )
    j-peek <> if s" unexpected byte in JSON text" j-fail then
    j-advance ;

: j-skip-space ( -- )
    begin
        j-peek dup bl = over 9 = or over 10 = or swap 13 = or
    while
        j-advance
    repeat ;

\ ---------------------------------------------------------------------------
\ Strings
\ ---------------------------------------------------------------------------

: >hex-value ( c -- n )
    dup [char] 0 [char] 9 1+ within if [char] 0 - exit then
    lower dup [char] a [char] f 1+ within if [char] a - 10 + exit then
    drop s" invalid JSON \u escape" j-fail 0 ;

: j-hex4 ( -- value )
    j-pos @ 4 + j-len @ u> if s" truncated JSON escape" j-fail then
    0
    4 0 ?do
        16 *
        j-pos @ j-at >hex-value +
        j-advance
    loop ;

\ Decode one string into the document pool and return its span there. Raw
\ control bytes, unknown escapes and unpaired surrogates are all failures.
: j-string ( doc -- offset length )
    0 0 0 0 0 0 { doc pool start ch escape high low }
    doc doc-pool to pool
    pool buf-len to start
    [char] " j-expect
    begin
        j-end? if s" unterminated JSON string" j-fail then
        j-peek [char] " <>
    while
        j-peek to ch
        ch 32 u< if s" raw control byte in JSON string" j-fail then
        ch [char] \ = if
            j-advance
            j-peek to escape
            j-advance
            escape [char] " = if [char] " pool buf-char else
            escape [char] \ = if [char] \ pool buf-char else
            escape [char] / = if [char] / pool buf-char else
            escape [char] b = if 8 pool buf-char else
            escape [char] f = if 12 pool buf-char else
            escape [char] n = if 10 pool buf-char else
            escape [char] r = if 13 pool buf-char else
            escape [char] t = if 9 pool buf-char else
            escape [char] u = if
                j-hex4 to high
                high 56320 57344 within if
                    s" unpaired low surrogate in JSON string" j-fail
                then
                high 55296 56320 within if
                    j-peek [char] \ <> if
                        s" unpaired high surrogate in JSON string" j-fail
                    then
                    j-advance
                    j-peek [char] u <> if
                        s" unpaired high surrogate in JSON string" j-fail
                    then
                    j-advance
                    j-hex4 to low
                    low 56320 57344 within 0= if
                        s" invalid surrogate pair in JSON string" j-fail
                    then
                    high 55296 - 1024 * low 56320 - + 65536 + pool utf8-append
                else
                    high pool utf8-append
                then
            else
                s" unknown JSON string escape" j-fail
            then then then then then then then then then
        else
            ch pool buf-char
            j-advance
        then
    repeat
    [char] " j-expect
    start  doc doc-pool buf-len start - ;

\ ---------------------------------------------------------------------------
\ Numbers
\ ---------------------------------------------------------------------------

9223372036854775807 constant json-max-integer

: j-digit? ( c -- flag )  [char] 0 [char] 9 1+ within ;

: j-accumulate ( accumulator digit -- accumulator flag )
    { accumulator digit }
    accumulator json-max-integer digit - 10 / u> if 0 false exit then
    accumulator 10 * digit + true ;

: j-scan-digits ( -- count )        \ advances over one or more digits
    0
    begin j-peek j-digit? while 1+ j-advance repeat
    dup 0= if s" JSON number needs at least one digit" j-fail then ;

: j-scale ( value exponent -- value flag )      \ multiply by ten, exactly
    0 { value exponent ok }
    true to ok
    exponent 0 ?do
        value json-max-integer 10 / u> if false to ok  0 to value  leave then
        value 10 * to value
    loop
    value ok ;

: j-unscale ( value exponent -- value flag )    \ divide by ten, only when exact
    0 { value exponent ok }
    true to ok
    exponent 0 ?do
        value 10 mod 0<> if false to ok  0 to value  leave then
        value 10 / to value
    loop
    value ok ;

: j-number ( doc -- index )
    0 0 0 0 0 0 0 0 0 0 0 0 0 0 { doc
       raw-start negative digit-start integer-digits value ok fraction-start fraction-digits
       exponent exponent-negative exponent-start exponent-digits scale index }
    j-pos @ to raw-start
    false to negative  0 to value  true to ok
    0 to fraction-digits  0 to exponent
    j-peek [char] - = if true to negative j-advance then
    j-pos @ to digit-start
    j-peek [char] 0 = if
        j-advance
        j-peek j-digit? if s" JSON number has a leading zero" j-fail then
    else
        j-scan-digits drop
    then
    j-pos @ digit-start - to integer-digits
    integer-digits 0 ?do
        ok if
            value  digit-start i + j-at [char] 0 -  j-accumulate
            to ok to value
        then
    loop
    j-peek [char] . = if
        j-advance
        j-pos @ to fraction-start
        j-scan-digits to fraction-digits
        fraction-digits 0 ?do
            ok if
                value  fraction-start i + j-at [char] 0 -  j-accumulate
                to ok to value
            then
        loop
    then
    j-peek dup [char] e = swap [char] E = or if
        j-advance
        false to exponent-negative
        j-peek [char] - = if
            true to exponent-negative j-advance
        else
            j-peek [char] + = if j-advance then
        then
        j-pos @ to exponent-start
        j-scan-digits to exponent-digits
        exponent-digits 3 u> if
            false to ok  0 to exponent
        else
            0
            exponent-digits 0 ?do
                10 *  exponent-start i + j-at [char] 0 - +
            loop
            exponent-negative if negate then to exponent
        then
    then
    \ The value is digits * 10^(exponent - fraction-digits).
    exponent fraction-digits - to scale
    ok if
        scale 0< if
            value scale negate j-unscale to ok to value
        else
            value scale j-scale to ok to value
        then
    then
    negative if value negate to value then
    doc json-number-type json-alloc-node to index
    value doc index nd>ival nd!
    ok if json-integral-flag else 0 then  doc index nd>aux nd!
    raw-start doc index nd>raw-off nd!
    j-pos @ raw-start - doc index nd>raw-len nd!
    index ;

\ ---------------------------------------------------------------------------
\ Values, arrays and objects
\ ---------------------------------------------------------------------------

defer j-value       \ ( doc -- index ), resolved below so containers can recurse

: j-enter ( -- )
    1 j-depth +!
    j-depth @ cvx-max-json-depth u> if
        s" JSON document is nested too deeply" cvx-raise-protocol
    then ;

: j-leave ( -- )  -1 j-depth +! ;

: j-array ( doc -- index )
    0 0 0 0 0 { doc raw-start index last count child }
    j-pos @ to raw-start
    j-enter
    [char] [ j-expect
    doc json-array-type json-alloc-node to index
    -1 to last  0 to count
    j-skip-space
    j-peek [char] ] <> if
        begin
            doc j-value to child
            last 0< if
                child doc index nd>ival nd!
            else
                child doc last nd>next nd!
            then
            child to last
            count 1+ to count
            j-skip-space
            j-peek [char] , =
        while
            j-advance j-skip-space
        repeat
    then
    [char] ] j-expect
    count doc index nd>aux nd!
    raw-start doc index nd>raw-off nd!
    j-pos @ raw-start - doc index nd>raw-len nd!
    j-leave
    index ;

256 constant json-max-object-keys

: j-duplicate? ( doc index key-off key-len -- flag )
    0 0 0 { doc index key-off key-len pool child found }
    doc doc-pool buf-data to pool
    false to found
    doc index nd>ival nd@ to child
    begin child 0>= found 0= and while
        doc child nd>key-len nd@ key-len = if
            pool doc child nd>key-off nd@ +  doc child nd>key-len nd@
            pool key-off +  key-len  str= if true to found then
        then
        doc child nd>next nd@ to child
    repeat
    found ;

: j-object ( doc -- index )
    0 0 0 0 0 0 0 { doc raw-start index last count child key-off key-len }
    j-pos @ to raw-start
    j-enter
    [char] { j-expect
    doc json-object-type json-alloc-node to index
    -1 to last  0 to count
    j-skip-space
    j-peek [char] } <> if
        begin
            j-skip-space
            doc j-string to key-len to key-off
            j-skip-space
            [char] : j-expect
            j-skip-space
            doc j-value to child
            key-off doc child nd>key-off nd!
            key-len doc child nd>key-len nd!
            doc index key-off key-len j-duplicate? if
                s" duplicate key in JSON object" cvx-raise-protocol
            then
            last 0< if
                child doc index nd>ival nd!
            else
                child doc last nd>next nd!
            then
            child to last
            count 1+ to count
            count json-max-object-keys u> if
                s" JSON object has too many keys" cvx-raise-protocol
            then
            j-skip-space
            j-peek [char] , =
        while
            j-advance
        repeat
    then
    j-skip-space
    [char] } j-expect
    count doc index nd>aux nd!
    raw-start doc index nd>raw-off nd!
    j-pos @ raw-start - doc index nd>raw-len nd!
    j-leave
    index ;

: j-simple ( doc type addr u -- index )
    0 0 { doc type addr count raw-start index }
    j-pos @ to raw-start
    raw-start count + j-len @ u> if s" truncated JSON literal" j-fail then
    j-src @ raw-start +  count  addr count  str= 0= if
        s" unknown JSON literal" j-fail
    then
    count j-pos +!
    doc type json-alloc-node to index
    raw-start doc index nd>raw-off nd!
    count doc index nd>raw-len nd!
    index ;

: j-value-body ( doc -- index )
    0 0 0 0 0 { doc ch raw-start offset length index }
    j-skip-space
    j-peek to ch
    ch [char] { = if doc j-object exit then
    ch [char] [ = if doc j-array exit then
    ch [char] " = if
        j-pos @ to raw-start
        doc j-string to length to offset
        doc json-string-type json-alloc-node to index
        offset doc index nd>ival nd!
        length doc index nd>aux nd!
        raw-start doc index nd>raw-off nd!
        j-pos @ raw-start - doc index nd>raw-len nd!
        index exit
    then
    ch [char] t = if doc json-true-type s" true" j-simple exit then
    ch [char] f = if doc json-false-type s" false" j-simple exit then
    ch [char] n = if doc json-null-type s" null" j-simple exit then
    ch [char] - = ch j-digit? or if doc j-number exit then
    s" unexpected JSON value" cvx-raise-protocol
    0 ;

' j-value-body is j-value

\ Parse text into doc. The text is copied into the document because node spans
\ point into it and the caller's transport buffer is reused immediately.
: json-parse ( addr u doc -- )
    { addr count doc }
    count cvx-max-json-bytes u> if
        s" JSON text exceeds the client byte limit" cvx-raise-protocol
    then
    addr count utf8-valid? 0= if
        s" JSON text is not valid UTF-8" cvx-raise-protocol
    then
    doc json-reset
    addr count doc doc-src buf-append
    doc j-doc !
    doc doc-src buf-data j-src !
    count j-len !
    0 j-pos !
    0 j-depth !
    doc j-value doc doc>root + !
    j-skip-space
    j-end? 0= if s" trailing bytes after JSON value" cvx-raise-protocol then ;

\ ---------------------------------------------------------------------------
\ Accessors
\ ---------------------------------------------------------------------------

: json-type ( doc index -- type )
    dup 0< if 2drop -1 exit then
    nd>type nd@ ;

: json-object? ( doc index -- flag )  json-type json-object-type = ;
: json-array? ( doc index -- flag )  json-type json-array-type = ;
: json-string? ( doc index -- flag )  json-type json-string-type = ;
: json-number? ( doc index -- flag )  json-type json-number-type = ;
: json-null? ( doc index -- flag )  json-type json-null-type = ;
: json-true? ( doc index -- flag )  json-type json-true-type = ;
: json-false? ( doc index -- flag )  json-type json-false-type = ;

: json-boolean? ( doc index -- flag )
    json-type dup json-true-type = swap json-false-type = or ;

: json-count ( doc index -- u )
    dup 0< if 2drop 0 exit then
    nd>aux nd@ ;

: json-first ( doc index -- child )
    dup 0< if 2drop -1 exit then
    nd>ival nd@ ;

: json-next ( doc index -- sibling )
    dup 0< if 2drop -1 exit then
    nd>next nd@ ;

\ The exact bytes the server sent for this value, used when echoing a Convex
\ value back to the conformance controller.
: json-raw ( doc index -- addr u )
    { doc index }
    index 0< if s" null" exit then
    doc doc-src buf-data doc index nd>raw-off nd@ +
    doc index nd>raw-len nd@ ;

: json-string@ ( doc index -- addr u )
    { doc index }
    doc index json-string? 0= if s" " exit then
    doc doc-pool buf-data doc index nd>ival nd@ +
    doc index nd>aux nd@ ;

: json-key@ ( doc index -- addr u )
    { doc index }
    doc doc-pool buf-data doc index nd>key-off nd@ +
    doc index nd>key-len nd@ ;

: json-get ( doc index key-addr key-u -- child )    \ -1 when absent
    0 0 { doc index key-addr key-count child result }
    -1 to result
    doc index json-object? 0= if -1 exit then
    doc index json-first to child
    begin child 0>= result 0< and while
        doc child json-key@ key-addr key-count str= if child to result then
        doc child json-next to child
    repeat
    result ;

: json-has? ( doc index key-addr key-u -- flag )  json-get 0>= ;

: json-item ( doc index position -- child )         \ -1 when out of range
    0 { doc index position child }
    doc index json-first to child
    position 0 ?do
        child 0< if -1 unloop exit then
        doc child json-next to child
    loop
    child ;

\ Integral value in signed 64-bit range, or false. This is the only way the
\ client reads a number, which is what makes `0` and `0.0` the same count while
\ `0.5` stays a hard failure at the point of use.
: json-integer ( doc index -- value flag )
    { doc index }
    doc index json-number? 0= if 0 false exit then
    doc index nd>aux nd@ json-integral-flag and 0= if 0 false exit then
    doc index nd>ival nd@ true ;

\ Convex log lines are always an array of strings. Anything else is a protocol
\ failure rather than something to coerce.
: json-log-lines? ( doc index -- flag )
    0 0 { doc index child ok }
    index 0< if true exit then
    doc index json-array? 0= if false exit then
    true to ok
    doc index json-first to child
    begin child 0>= ok and while
        doc child json-string? 0= if false to ok then
        doc child json-next to child
    repeat
    ok ;

\ ---------------------------------------------------------------------------
\ Writer
\
\ Outgoing JSON is composed straight into a buffer. The client builds one
\ document at a time on one thread, so the writer keeps its separator state in
\ module variables and reads as a small vocabulary at the call site.
\ ---------------------------------------------------------------------------

16 constant jw-max-depth
create jw-first jw-max-depth cells allot
variable jw-out
variable jw-depth

: jw-start ( buf -- )
    jw-out !
    0 jw-depth !
    true jw-first ! ;

: jw-emit ( c -- )  jw-out @ buf-char ;
: jw-text ( addr u -- )  jw-out @ buf-append ;
: jw-slot ( -- addr )  jw-first jw-depth @ cells + ;

: jw-separate ( -- )
    jw-slot dup @ if false swap ! else drop [char] , jw-emit then ;

: jw-push ( -- )
    jw-depth @ 1+ dup jw-max-depth u< 0= if
        drop s" outgoing JSON is nested too deeply" cvx-raise-protocol
    then
    jw-depth !
    true jw-slot ! ;

: jw-pop ( -- )  -1 jw-depth +! ;

: jw-string ( addr u -- )
    0 { addr count ch }
    [char] " jw-emit
    count 0 ?do
        addr i + c@ to ch
        ch [char] " = if s\" \\\"" jw-text else
        ch [char] \ = if s\" \\\\" jw-text else
        ch 8 = if s\" \\b" jw-text else
        ch 12 = if s\" \\f" jw-text else
        ch 10 = if s\" \\n" jw-text else
        ch 13 = if s\" \\r" jw-text else
        ch 9 = if s\" \\t" jw-text else
        ch 32 u< if
            s\" \\u00" jw-text
            ch 4 rshift >hex-digit jw-emit
            ch 15 and >hex-digit jw-emit
        else
            ch jw-emit
        then then then then then then then then
    loop
    [char] " jw-emit ;

: jw{ ( -- )  jw-separate [char] { jw-emit jw-push ;
: jw} ( -- )  jw-pop [char] } jw-emit ;
: jw[ ( -- )  jw-separate [char] [ jw-emit jw-push ;
: jw] ( -- )  jw-pop [char] ] jw-emit ;

\ jw-key marks the following value as the first item at its level so it emits
\ no separator of its own.
: jw-key ( addr u -- )  jw-separate jw-string [char] : jw-emit true jw-slot ! ;

: jw-value-string ( addr u -- )  jw-separate jw-string ;
: jw-uint ( u -- )  jw-separate u>string jw-text ;
: jw-int ( n -- )  jw-separate n>string jw-text ;
: jw-true ( -- )  jw-separate s" true" jw-text ;
: jw-false ( -- )  jw-separate s" false" jw-text ;
: jw-null ( -- )  jw-separate s" null" jw-text ;
: jw-bool ( flag -- )  if jw-true else jw-false then ;

\ Splice already validated JSON text, such as a value echoed back exactly as
\ Convex sent it.
: jw-raw ( addr u -- )  jw-separate jw-text ;

: jw-pair-string ( key-addr key-u value-addr value-u -- )
    2>r jw-key 2r> jw-value-string ;
: jw-pair-raw ( key-addr key-u value-addr value-u -- )
    2>r jw-key 2r> jw-raw ;
: jw-pair-uint ( key-addr key-u value -- )  >r jw-key r> jw-uint ;
: jw-pair-int ( key-addr key-u value -- )  >r jw-key r> jw-int ;
: jw-pair-bool ( key-addr key-u flag -- )  >r jw-key r> jw-bool ;
