! Strict JSON scanning for the educational Convex client.
!
! Convex values have to survive an exact round trip. Decoding a payload into
! Factor objects and re-encoding it would erase the difference between a JSON
! integer and a float and would reorder object keys, so this vocabulary never
! does that. Every word validates the original text strictly and reports index
! ranges instead, which lets the client forward untouched subtrees to Convex
! or to the conformance controller while still rejecting malformed, oversized,
! or deeply nested documents before they reach the rest of the client.

USING: combinators continuations kernel locals make math math.order
math.parser sequences strings ;
IN: convex.json

ERROR: json-error message ;

! A JSON document shares the same budget as the WebSocket frame or HTTP
! response that carried it. Bounding size, depth, and container width here
! means a drifting or hostile peer cannot force unbounded recursion.
CONSTANT: max-json-bytes 2097152
CONSTANT: max-json-depth 128
CONSTANT: max-json-entries 8192

CONSTANT: max-json-uint32 4294967295
CONSTANT: max-json-integer 9223372036854775807

! The four structural characters that also delimit Factor's own literals are
! named here, so the scanner never has to spell a brace or a bracket as a bare
! token inside a quotation.
CONSTANT: open-brace 123
CONSTANT: close-brace 125
CONSTANT: open-bracket 91
CONSTANT: close-bracket 93

: json-space? ( ch/f -- ? )
    { CHAR: \s CHAR: \t CHAR: \r CHAR: \n } member? ;

: json-digit? ( ch/f -- ? )
    dup [ CHAR: 0 CHAR: 9 between? ] [ drop f ] if ;

: json-hex-digit? ( ch/f -- ? )
    dup [
        [ CHAR: 0 CHAR: 9 between? ]
        [ CHAR: a CHAR: f between? ]
        [ CHAR: A CHAR: F between? ] tri or or
    ] [ drop f ] if ;

:: skip-json-space ( text index -- index' )
    index :> i!
    [ i text ?nth json-space? ] [ i 1 + i! ] while
    i ;

! Compares a fixed literal without running off the end of the document.
:: json-literal-at? ( text index literal -- ? )
    index literal length + text length <= [
        index index literal length + text subseq literal =
    ] [ f ] if ;

! INDEX points at a backslash. Returns the index just past the escape.
:: json-escape-end ( text index -- index' )
    index 1 + text ?nth :> esc
    esc [ "unterminated JSON escape" json-error ] unless
    esc "\"\\/bfnrtu" member? [
        "unsupported JSON string escape" json-error
    ] unless
    esc CHAR: u = [
        index 2 + :> start
        4 <iota> [ start + text ?nth json-hex-digit? ] all? [
            "malformed unicode escape in JSON string" json-error
        ] unless
        index 6 +
    ] [ index 2 + ] if ;

! INDEX points at the opening quote. Returns the index just past the closing
! quote, rejecting the raw control characters that strict JSON forbids.
:: json-string-end ( text index -- index' )
    index 1 + :> i!
    0 :> result!
    [ result 0 = ] [
        i text ?nth :> ch
        {
            { [ ch not ] [ "unterminated JSON string" json-error ] }
            { [ ch CHAR: " = ] [ i 1 + result! ] }
            { [ ch CHAR: \\ = ] [ text i json-escape-end i! ] }
            { [ ch CHAR: \s < ] [
                "unescaped control character in JSON string" json-error
            ] }
            [ i 1 + i! ]
        } cond
    ] while
    result ;

! Numbers, true, false, and null. Convex may spell an integral value as 1.0,
! so a fraction is accepted here and refused later by the words that need a
! whole number. Exponent forms are rejected outright: this client never emits
! one, and quietly accepting one would hide protocol drift.
:: json-number-end ( text index -- index' )
    index :> i!
    i text ?nth CHAR: - = [ i 1 + i! ] when
    i :> integral-start
    [ i text ?nth json-digit? ] [ i 1 + i! ] while
    i integral-start = [ "expected a JSON value" json-error ] when
    integral-start text nth CHAR: 0 = i integral-start 1 + > and [
        "JSON number has a leading zero" json-error
    ] when
    i text ?nth CHAR: . = [
        i 1 + i!
        i :> fraction-start
        [ i text ?nth json-digit? ] [ i 1 + i! ] while
        i fraction-start = [
            "JSON number has an empty fraction" json-error
        ] when
    ] when
    i text ?nth { CHAR: e CHAR: E } member? [
        "exponent JSON numbers are not supported" json-error
    ] when
    i ;

! Returns the index just past a complete JSON value that starts at INDEX.
! Containers are walked with an explicit loop, so the only recursion is the
! self call for one member value, which the depth bound already limits.
:: json-value-end ( text index depth -- index' )
    depth max-json-depth >= [ "JSON nesting is too deep" json-error ] when
    text index skip-json-space :> start
    start text ?nth :> ch
    ch [ "expected a JSON value" json-error ] unless
    {
        { [ ch CHAR: " = ] [ text start json-string-end ] }
        { [ text start "true" json-literal-at? ] [ start 4 + ] }
        { [ text start "false" json-literal-at? ] [ start 5 + ] }
        { [ text start "null" json-literal-at? ] [ start 4 + ] }
        { [ ch open-brace = ch open-bracket = or ] [
            ch open-brace = :> object?
            object? close-brace close-bracket ? :> closer
            start 1 + :> i!
            0 :> result!
            0 :> count!
            [ result 0 = ] [
                text i skip-json-space i!
                i text ?nth :> c
                c [ "unterminated JSON container" json-error ] unless
                c closer = [
                    i 1 + result!
                ] [
                    count 0 > [
                        c CHAR: , = [
                            "malformed JSON container separator" json-error
                        ] unless
                        text i 1 + skip-json-space i!
                    ] when
                    object? [
                        i text ?nth CHAR: " = [
                            "malformed JSON object key" json-error
                        ] unless
                        text text i json-string-end skip-json-space i!
                        i text ?nth CHAR: : = [
                            "malformed JSON object separator" json-error
                        ] unless
                        text i 1 + skip-json-space i!
                    ] when
                    text i depth 1 + json-value-end i!
                    count 1 + count!
                    count max-json-entries > [
                        "JSON container has too many entries" json-error
                    ] when
                ] if
            ] while
            result
        ] }
        [ text start json-number-end ]
    } cond ;

! Validates a complete document and rejects trailing content.
:: check-json ( text -- text )
    text length max-json-bytes > [
        "JSON document exceeds the size limit" json-error
    ] when
    text text 0 0 json-value-end skip-json-space text length = [
        "trailing content after JSON value" json-error
    ] unless
    text ;

: json-text? ( text -- ? )
    ! recover's catch quotation receives the stack as it was when the try
    ! quotation started (here: the input text) plus the error, so both
    ! must be dropped, not just the error.
    [ check-json drop t ] [ 2drop f ] recover ;

:: json-object-text? ( text -- ? )
    text json-text? [
        text 0 skip-json-space text ?nth open-brace =
    ] [ f ] if ;

! Decodes one JSON string token, including surrogate pairs, so the client can
! compare protocol keys and read message text without a general decoder.
:: json-string-value ( raw -- string )
    raw 0 skip-json-space :> start
    start raw ?nth CHAR: " = [ "expected a JSON string" json-error ] unless
    raw start json-string-end :> end
    raw end skip-json-space raw length = [
        "trailing content after JSON string" json-error
    ] unless
    start 1 + :> i!
    [
        [ i end 1 - < ] [
            i raw nth :> ch
            ch CHAR: \\ = [
                i 1 + raw nth :> esc
                esc CHAR: u = [
                    i 2 + i 6 + raw subseq hex> :> unit
                    unit 0xd800 0xdbff between? [
                        i 6 + raw ?nth CHAR: \\ =
                        i 7 + raw ?nth CHAR: u = and [
                            i 8 + i 12 + raw subseq hex> :> low
                            low 0xdc00 0xdfff between? [
                                "malformed surrogate pair" json-error
                            ] unless
                            unit 0xd800 - 10 shift low 0xdc00 - +
                            0x10000 + ,
                            i 12 + i!
                        ] [ "lone surrogate escape" json-error ] if
                    ] [
                        unit 0xdc00 0xdfff between? [
                            "lone surrogate escape" json-error
                        ] when
                        unit ,
                        i 6 + i!
                    ] if
                ] [
                    esc {
                        { CHAR: " [ CHAR: " ] }
                        { CHAR: \\ [ CHAR: \\ ] }
                        { CHAR: / [ CHAR: / ] }
                        { CHAR: b [ 8 ] }
                        { CHAR: f [ 12 ] }
                        { CHAR: n [ CHAR: \n ] }
                        { CHAR: r [ CHAR: \r ] }
                        { CHAR: t [ CHAR: \t ] }
                        [ drop "unsupported JSON string escape" json-error ]
                    } case ,
                    i 2 + i!
                ] if
            ] [ ch , i 1 + i! ] if
        ] while
    ] "" make ;

! Returns the exact source text of KEY's value, or f when the object omits
! it. Keeping the raw subtree is what makes an untouched Convex value
! forwardable without a lossy decode and re-encode.
:: json-field ( text key -- raw/f )
    text 0 skip-json-space :> i!
    i text ?nth open-brace = [ "expected a JSON object" json-error ] unless
    i 1 + i!
    f :> result!
    f :> done!
    [ done not ] [
        text i skip-json-space i!
        i text ?nth :> c
        {
            { [ c not ] [ "unterminated JSON object" json-error ] }
            { [ c close-brace = ] [ t done! ] }
            { [ c CHAR: " = ] [
                text i json-string-end :> key-end
                i key-end text subseq json-string-value :> found
                text key-end skip-json-space i!
                i text ?nth CHAR: : = [
                    "malformed JSON object separator" json-error
                ] unless
                text i 1 + skip-json-space :> value-start
                text value-start 0 json-value-end :> value-end
                found key = [
                    value-start value-end text subseq result!
                    t done!
                ] [
                    text value-end skip-json-space i!
                    i text ?nth CHAR: , = [ i 1 + i! ] when
                ] if
            ] }
            [ "malformed JSON object key" json-error ]
        } cond
    ] while
    result ;

! Returns every key of a JSON object. The conformance adapter uses this to
! reject a command that carries a field its schema does not allow, instead of
! silently ignoring protocol drift.
:: json-keys ( text -- seq )
    text 0 skip-json-space :> i!
    i text ?nth open-brace = [ "expected a JSON object" json-error ] unless
    i 1 + i!
    f :> done!
    [
        [ done not ] [
            text i skip-json-space i!
            i text ?nth :> c
            {
                { [ c not ] [ "unterminated JSON object" json-error ] }
                { [ c close-brace = ] [ t done! ] }
                { [ c CHAR: " = ] [
                    text i json-string-end :> key-end
                    i key-end text subseq json-string-value ,
                    text key-end skip-json-space i!
                    i text ?nth CHAR: : = [
                        "malformed JSON object separator" json-error
                    ] unless
                    text i 1 + skip-json-space :> value-start
                    text value-start 0 json-value-end :> value-end
                    text value-end skip-json-space i!
                    i text ?nth CHAR: , = [ i 1 + i! ] when
                ] }
                [ "malformed JSON object key" json-error ]
            } cond
        ] while
    ] { } make ;

! Returns each element of a JSON array as its own exact source text.
:: json-elements ( text -- seq )
    text 0 skip-json-space :> i!
    i text ?nth open-bracket = [ "expected a JSON array" json-error ] unless
    i 1 + i!
    f :> done!
    [
        [ done not ] [
            text i skip-json-space i!
            i text ?nth :> c
            {
                { [ c not ] [ "unterminated JSON array" json-error ] }
                { [ c close-bracket = ] [ t done! ] }
                [
                    text i 0 json-value-end :> value-end
                    i value-end text subseq ,
                    text value-end skip-json-space i!
                    i text ?nth CHAR: , = [ i 1 + i! ] when
                ]
            } cond
        ] while
    ] { } make ;

! Protocol counters arrive as untyped JSON text. Validating the exact token
! keeps a quoted or boolean lookalike from entering client state.
:: json-uint32 ( raw name -- n )
    raw [ name " is missing" append json-error ] unless
    raw [ json-space? ] trim :> token
    token empty? not token [ json-digit? ] all? and [
        name " must be a JSON integer" append json-error
    ] unless
    token length 1 > token first CHAR: 0 = and [
        name " must not have a leading zero" append json-error
    ] when
    token string>number :> value
    value max-json-uint32 > [
        name " exceeds the uint32 range" append json-error
    ] when
    value ;

! Convex may encode an integral value as 0.0. Accept a mathematically whole
! number in range and reject fractional, quoted, non-finite, or overflowing
! spellings, which is exactly the boundary the canonical example demonstrates.
:: json-whole-number ( raw name -- n )
    raw [ name " is missing" append json-error ] unless
    raw [ json-space? ] trim :> token
    token empty? [ name " must be a JSON number" append json-error ] when
    token first CHAR: - = :> negative?
    negative? [ token rest ] [ token ] if :> digits
    CHAR: . digits index :> dot
    dot [ digits dot head ] [ digits ] if :> integral
    dot [ digits dot 1 + tail ] [ "" ] if :> fraction
    integral empty? not integral [ json-digit? ] all? and [
        name " must be a JSON number" append json-error
    ] unless
    integral length 1 > integral first CHAR: 0 = and [
        name " must not have a leading zero" append json-error
    ] when
    dot [
        fraction empty? not fraction [ CHAR: 0 = ] all? and [
            name " must be a whole number" append json-error
        ] unless
    ] when
    integral string>number :> magnitude
    magnitude max-json-integer > [
        name " is outside the supported integer range" append json-error
    ] when
    negative? [ magnitude neg ] [ magnitude ] if ;

:: json-boolean ( raw name -- ? )
    raw [ name " is missing" append json-error ] unless
    raw [ json-space? ] trim {
        { "true" [ t ] }
        { "false" [ f ] }
        [ drop name " must be a JSON boolean" append json-error ]
    } case ;

! Emitting side. The client only ever builds strings, small integers, and
! literal containers itself; every Convex value passes through as raw text.
:: json-escape-string ( string -- json )
    [
        CHAR: " ,
        string [
            dup {
                { CHAR: " [ drop "\\\"" % ] }
                { CHAR: \\ [ drop "\\\\" % ] }
                { CHAR: \n [ drop "\\n" % ] }
                { CHAR: \r [ drop "\\r" % ] }
                { CHAR: \t [ drop "\\t" % ] }
                { 8 [ drop "\\b" % ] }
                { 12 [ drop "\\f" % ] }
                [
                    ! No leading dup: case's fallback clause runs without
                    ! consuming its match value, so the outer dup above
                    ! already supplies the one copy this branch needs.
                    CHAR: \s < [
                        "\\u" % >hex 4 CHAR: 0 pad-head %
                    ] [ , ] if
                ]
            } case
        ] each
        CHAR: " ,
    ] "" make ;

! PAIRS is a sequence of { key raw-json-value } entries. The value side is
! already-valid JSON text, which is what keeps a Convex value byte-exact.
:: json-object ( pairs -- json )
    [
        open-brace ,
        t :> leading!
        pairs [
            first2 :> ( key raw )
            leading [ f leading! ] [ CHAR: , , ] if
            key json-escape-string % CHAR: : , raw %
        ] each
        close-brace ,
    ] "" make ;

:: json-array ( raws -- json )
    [
        open-bracket ,
        t :> leading!
        raws [ leading [ f leading! ] [ CHAR: , , ] if % ] each
        close-bracket ,
    ] "" make ;

: json-number ( n -- json )
    number>string ;
