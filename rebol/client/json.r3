Rebol [
    Title: "Convex REBOL client -- hand-rolled JSON encoder/decoder"
    Purpose: {
        Rebol/Bulk 3.22.1's built-in `to-json` mezzanine cannot be used for
        Convex's wire protocol: it mis-encodes logic! values and `none` (JSON
        booleans and null), which Convex's HTTP and sync envelopes both use
        (for example a mutation's success/failure shape and an absent
        optional field). This module is a small, strict, from-scratch JSON
        reader and writer built directly on primitive string/char operations
        -- no PARSE dialect, no `load` of untrusted text -- so every decision
        about what is and is not valid JSON is made explicitly here rather
        than inherited from Rebol's own (much more permissive) literal
        syntax.

        Value mapping, chosen to use Rebol's native type system rather than
        a custom tagged-node wrapper:
            JSON object -> map!      (order-preserving; see the round-trip
                                       test -- Rebol/Bulk's map! keeps
                                       insertion order)
            JSON array  -> block!    (values appended with APPEND/ONLY so a
                                       nested array or object is never
                                       flattened into its parent)
            JSON string -> string!
            JSON number -> integer! when the literal has no '.' or exponent,
                            decimal! otherwise
            JSON true/false -> logic! true / false
            JSON null   -> none

        Convex may report a value that is conceptually an integer using the
        decimal literal form `0.0` or `1.0` rather than `0`/`1` (this is a
        property of Convex's own JSON encoding of its `number` type, not a
        REBOL quirk). `convex-integral?`/`convex-integral-to-integer` below
        implement the accept/reject rule client code needs when it expects a
        Convex integer field: accept any JSON number that is mathematically
        integral and within a safe magnitude, whether it was written with a
        decimal point or not; reject a fractional value, a quoted value
        (i.e. anything that did not decode to integer!/decimal! at all), or
        one whose magnitude exceeds the safe-integer bound shared with
        Convex's own `number` type (2^53, the largest magnitude an IEEE-754
        double -- REBOL's own decimal! -- represents every integer up to
        exactly).
    }
]

;; ---------------------------------------------------------------------
;; Decode: a strict, hand-written recursive-descent JSON reader.
;;
;; `s` (the parse "state") is a small mutable object -- text/pos/len -- built
;; with MAKE OBJECT! COMPOSE [...] specifically so the outer `text` argument
;; is spliced in as a literal *before* the object's own fields are bound;
;; naming a field `text` in the object spec block itself would otherwise
;; shadow the argument for the rest of that same block (a well-known REBOL
;; object-construction trap), so the state's fields are deliberately named
;; `txt`/`pos`/`len` -- none of which collide with any surrounding argument
;; name.
;;
;; Every parse-* function either returns a decoded value and leaves
;; `s/pos` at the first unconsumed character, or raises a REBOL error via
;; `json-fail`, which unwinds straight out to the `try` in `json-decode`
;; regardless of recursion depth -- so failure needs no manual threading
;; through every call site.
;; ---------------------------------------------------------------------

json-fail: function [message [string!]] [
    do make error! message
]

make-parse-state: function [text [string!]] [
    make object! compose [txt: (text) pos: 1 len: (length? text)]
]

;; Character at the cursor, or none past the end of input.
peek-char: function [s [object!]] [
    either s/pos > s/len [none] [pick s/txt s/pos]
]

advance: function [s [object!]] [
    s/pos: s/pos + 1
]

is-digit?: function [c] [
    all [c (c >= #"0") (c <= #"9")]
]

whitespace-chars: charset " ^-^/^M"

skip-space: function [s [object!]] [
    while [all [(c: peek-char s) (find whitespace-chars c)]] [advance s]
]

;; Consumes an exact, case-sensitive keyword (`true`/`false`/`null`) and
;; returns the REBOL value it stands for. `=` on strings is case-
;; insensitive in REBOL, which would wrongly accept "TRUE"/"Null"/etc, so
;; this compares with the strict `==` operator instead.
parse-keyword: function [s [object!] word [string!] value] [
    n: length? word
    if (s/pos + n - 1) > s/len [json-fail rejoin ["expected " word]]
    chunk: copy/part (at s/txt s/pos) n
    unless chunk == word [json-fail rejoin ["expected " word]]
    s/pos: s/pos + n
    value
]

;; JSON number grammar: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
;; Scanned by hand (not via REBOL's own permissive number literals, which
;; also accept underscores, radix prefixes, money, tuples, and more) so a
;; malformed literal such as "01" or "1." is rejected exactly where the
;; JSON grammar rejects it, not silently reinterpreted.
parse-number: function [s [object!]] [
    start: s/pos
    if (peek-char s) = #"-" [advance s]
    unless is-digit? peek-char s [json-fail "invalid number"]
    either (peek-char s) = #"0" [
        advance s   ; a leading zero may not be followed by another digit
    ] [
        while [is-digit? peek-char s] [advance s]
    ]
    is-decimal: false
    if (peek-char s) = #"." [
        is-decimal: true
        advance s
        unless is-digit? peek-char s [json-fail "bare decimal point in number"]
        while [is-digit? peek-char s] [advance s]
    ]
    c: peek-char s
    if all [c any [c = #"e" c = #"E"]] [
        is-decimal: true
        advance s
        c: peek-char s
        if all [c any [c = #"+" c = #"-"]] [advance s]
        unless is-digit? peek-char s [json-fail "malformed exponent in number"]
        while [is-digit? peek-char s] [advance s]
    ]
    literal: copy/part (at s/txt start) (s/pos - start)
    either is-decimal [to-decimal literal] [to-integer literal]
]

;; JSON strings only allow the escapes below; any other backslash
;; sequence, and any raw byte under 0x20, is a decode error.
parse-string-literal: function [s [object!]] [
    advance s   ; opening quote, already confirmed by the caller
    buffer: copy ""
    forever [
        if s/pos > s/len [json-fail "unterminated string"]
        c: pick s/txt s/pos
        case [
            c = #"^"" [advance s break]
            c = #"\" [
                advance s
                if s/pos > s/len [json-fail "unterminated escape"]
                e: pick s/txt s/pos
                switch/default e [
                    #"^"" [append buffer #"^"" advance s]
                    #"\" [append buffer #"\" advance s]
                    #"/" [append buffer #"/" advance s]
                    #"b" [append buffer #"^H" advance s]
                    #"f" [append buffer #"^L" advance s]
                    #"n" [append buffer #"^/" advance s]
                    #"r" [append buffer #"^M" advance s]
                    #"t" [append buffer #"^-" advance s]
                    #"u" [
                        advance s
                        code: parse-hex4 s
                        either all [code >= 55296 code <= 56319] [
                            ;; high surrogate: must be followed by a \u low
                            ;; surrogate: combine into one code point rather
                            ;; than emitting two separate, individually
                            ;; invalid, UTF-16 halves.
                            unless all [
                                (s/pos + 1) <= s/len
                                (pick s/txt s/pos) = #"\"
                                (pick s/txt (s/pos + 1)) = #"u"
                            ] [json-fail "unpaired high surrogate"]
                            advance s advance s
                            low: parse-hex4 s
                            unless all [low >= 56320 low <= 57343] [
                                json-fail "high surrogate not followed by a low surrogate"
                            ]
                            append buffer to-char (65536 + ((code - 55296) * 1024) + (low - 56320))
                        ] [
                            if all [code >= 56320 code <= 57343] [
                                json-fail "unpaired low surrogate"
                            ]
                            append buffer to-char code
                        ]
                    ]
                ] [json-fail rejoin ["unknown string escape \" e]]
            ]
            c < #" " [json-fail "unescaped control character in string"]
            true [append buffer c advance s]
        ]
    ]
    buffer
]

;; Value of one hex digit, or none if `c` is not a hex digit.
hex-digit-value: function [c] [
    case [
        all [c (c >= #"0") (c <= #"9")] [(to-integer c) - (to-integer #"0")]
        all [c (c >= #"a") (c <= #"f")] [10 + (to-integer c) - (to-integer #"a")]
        all [c (c >= #"A") (c <= #"F")] [10 + (to-integer c) - (to-integer #"A")]
        true [none]
    ]
]

;; Exactly 4 hex digits, per \uXXXX. Returns the numeric value and leaves
;; `s/pos` just past the 4th digit. Summed digit-by-digit rather than
;; handed to REBOL's own literal loader, which does not parse bare hex
;; text the same way JSON's \u escape needs.
parse-hex4: function [s [object!]] [
    if (s/pos + 3) > s/len [json-fail "truncated \u escape"]
    value: 0
    repeat i 4 [
        d: hex-digit-value pick s/txt (s/pos + i - 1)
        unless d [json-fail "invalid hex digit in \u escape"]
        value: (value * 16) + d
    ]
    s/pos: s/pos + 4
    value
]

parse-object: function [s [object!]] [
    advance s   ; opening brace
    result: make map! []
    skip-space s
    either (peek-char s) = #"}" [advance s] [
        forever [
            skip-space s
            unless (peek-char s) = #"^"" [json-fail "expected a quoted key"]
            key: parse-string-literal s
            skip-space s
            unless (peek-char s) = #":" [json-fail "expected ':' after object key"]
            advance s
            value: parse-value s
            put result key value
            skip-space s
            c: peek-char s
            case [
                c = #"," [advance s]
                c = #"}" [advance s break]
                true [json-fail "expected ',' or '}' in object"]
            ]
        ]
    ]
    result
]

parse-array: function [s [object!]] [
    advance s   ; opening bracket
    result: copy []
    skip-space s
    either (peek-char s) = #"]" [advance s] [
        forever [
            append/only result parse-value s
            skip-space s
            c: peek-char s
            case [
                c = #"," [advance s]
                c = #"]" [advance s break]
                true [json-fail "expected ',' or ']' in array"]
            ]
        ]
    ]
    result
]

parse-value: function [s [object!]] [
    skip-space s
    c: peek-char s
    case [
        none? c [json-fail "unexpected end of input"]
        c = #"{" [parse-object s]
        c = #"[" [parse-array s]
        c = #"^"" [parse-string-literal s]
        c = #"t" [parse-keyword s "true" true]
        c = #"f" [parse-keyword s "false" false]
        c = #"n" [parse-keyword s "null" none]
        any [c = #"-" is-digit? c] [parse-number s]
        true [json-fail rejoin ["unexpected character '" c "'"]]
    ]
]

;; Top-level decode. Rejects trailing content after the single JSON value
;; (a bare `{"a":1} trailing` is not valid JSON), and turns any raised
;; parse error into a plain result object instead of an unhandled REBOL
;; error, so callers check `ok` rather than wrapping every call in `try`
;; themselves.
json-decode: function [text [string!]] [
    s: make-parse-state text
    outcome: try [
        value: parse-value s
        skip-space s
        if s/pos <= s/len [json-fail "trailing content after JSON value"]
        value
    ]
    either error? outcome [
        object [ok: false reason: outcome/arg1 value: none]
    ] [
        object [ok: true reason: none value: outcome]
    ]
]

;; ---------------------------------------------------------------------
;; Encode.
;; ---------------------------------------------------------------------

;; Escapes exactly what JSON requires: the quote and backslash that would
;; otherwise end or corrupt the string, and every control byte (below
;; 0x20) as \u00XX. Everything else, including non-ASCII UTF-8 text,
;; passes through unescaped -- REBOL's own port writers encode string!
;; values as UTF-8 on the wire, so this does not need to.
json-quote: function [text [string!]] [
    result: copy "^""
    foreach c text [
        case [
            c = #"^"" [append result {\"}]
            c = #"\" [append result {\\}]
            c = #"^/" [append result "\n"]
            c = #"^M" [append result "\r"]
            c = #"^-" [append result "\t"]
            c < #" " [
                hex16: form to-hex to-integer c
                append result "\u"
                append result lowercase copy/part (at hex16 13) 4
            ]
            true [append result c]
        ]
    ]
    append result #"^""
    result
]

json-encode: function [value] [
    case [
        none? value ["null"]
        logic? value [either value ["true"] ["false"]]
        integer? value [form value]
        decimal? value [mold value]
        string? value [json-quote value]
        map? value [
            pieces: copy []
            foreach [key val] value [
                append pieces rejoin [json-quote key ":" json-encode val]
            ]
            rejoin ["{" (join-with pieces ",") "}"]
        ]
        block? value [
            pieces: copy []
            foreach item value [append pieces json-encode item]
            rejoin ["[" (join-with pieces ",") "]"]
        ]
        true [json-fail rejoin ["cannot encode a " (mold type? value) " value to JSON"]]
    ]
]

;; REBOL has no built-in "join with separator"; small enough to inline
;; rather than pull in a mezzanine that may not exist across builds.
join-with: function [pieces [block!] separator [string!]] [
    result: copy ""
    first-piece: true
    foreach piece pieces [
        unless first-piece [append result separator]
        append result piece
        first-piece: false
    ]
    result
]

;; ---------------------------------------------------------------------
;; Convex's integral-decimal rule (see the module header). Operates on an
;; already-*decoded* JSON value, so a value that never became integer! or
;; decimal! at all (a quoted number, an object, ...) is rejected by the
;; type check alone.
;; ---------------------------------------------------------------------

convex-safe-magnitude: 9007199254740992   ; 2^53

convex-integral?: function [value] [
    case [
        integer? value [(abs value) <= convex-safe-magnitude]
        decimal? value [
            all [
                (abs value) <= convex-safe-magnitude
                value = to-decimal to-integer value
            ]
        ]
        true [false]
    ]
]

;; Only meaningful after `convex-integral?` returned true; converts either
;; representation to a REBOL integer!.
convex-integral-to-integer: function [value] [
    either integer? value [value] [to-integer value]
]
