Rebol [
    Title: "Convex REBOL client -- HTTP transport, JSON envelope, and Live sync"
    Purpose: {
        Ties together client/json.r3 (strict JSON codec) and client/x509.r3
        (hardened TLS chain/hostname verification) into a working Convex
        client: HTTP query/mutation/action calls, and the RFC 6455 WebSocket
        + `/api/sync` Live state machine.

        All client state lives in one module-level object, `cx` -- REBOL's
        equivalent of the flat routine-local globals other hand-rolled
        clients in this repo use, chosen as a single object (rather than a
        pile of bare globals) specifically so that every mutating function
        below can be declared with plain FUNC and still safely write `cx/field:
        value` regardless of FUNC vs FUNCTION: a set-PATH like `cx/field:` is
        never auto-gathered as a function-local by FUNCTION (only a bare
        set-WORD like `field:` is), so this design sidesteps that trap by
        construction rather than by vigilance. The one place that trap still
        applies is the handful of low-level socket helpers below that must
        mutate a bare local across a nested `awake` closure -- each of those
        is called out with its own comment.

        Session state here supports exactly one open client at a time,
        matching every other hand-rolled client in this repo and the
        adapter's own single-owner design: one worker (the adapter's main
        loop, or the canonical example) drives the Live socket, reconnects,
        and query-set version changes; nothing else touches it concurrently.
    }
]

do %json.r3
do %x509.r3

;; ===========================================================================
;; Module state
;; ===========================================================================

cx: object [
    url: none
    secure: false
    host: ""
    port-number: 0
    host-header: ""
    token: ""
    session: ""
    client-version: "rebol-0.1.0"
    trust-bundle: none          ; loaded once per convex-open, from client/ca-bundle/
    epoch: none                 ; now/precise captured at convex-open, for now-ms

    err-name: none
    err-message: none
    err-data: none

    http-connect-timeout-ms: 5000
    http-total-timeout-ms: 15000

    live-connect-timeout-ms: 5000
    live-write-timeout-ms: 2000
    live-socket: none
    live-connection-count: 0
    live-last-close: "InitialConnect"
    live-initial-timestamp: "AAAAAAAAAAA="
    live-max-timestamp: "AAAAAAAAAAA="
    live-remote-query-set: 0
    live-remote-identity: 0
    live-remote-timestamp: "AAAAAAAAAAA="
    live-query-set-version: 0
    live-next-query-id: 0
    live-backoff-base-ms: 250
    live-backoff-max-ms: 30000
    live-backoff-ms: 250
    live-retry-at: 0
    ws-buf: #{}

    subs: none         ; map! queryId(string) -> subscription object!
    tag-to-qid: none   ; map! tag(string) -> queryId(string)
]

;; ---------------------------------------------------------------------
;; Errors: one channel. A structured client-side failure always returns
;; false/none so a call site can `unless convex-... [...]` without a
;; separate check. errorData is REBOL-native (already decoded), matching
;; the value shape convex-query/mutation/action itself returns.
;; ---------------------------------------------------------------------

set-client-error: func [name [string!] message [string!]] [
    cx/err-name: name
    cx/err-message: message
    cx/err-data: none
    false
]

convex-error-name: does [cx/err-name]
convex-error-message: does [cx/err-message]
convex-error-data: does [cx/err-data]

;; ===========================================================================
;; Time: a monotonic-enough millisecond clock built from DIFFERENCE (date-
;; aware, so it is safe across a midnight rollover, unlike subtracting two
;; /time components directly) against an epoch captured once at open.
;; ===========================================================================

now-ms: does [
    to-integer ((to-decimal difference now/precise cx/epoch) * 1000)
]

remaining-ms: function [deadline [integer!]] [
    left: deadline - now-ms
    either left < 0 [0] [left]
]

;; ===========================================================================
;; Randomness and UUIDs. random/secure is this fork's CSPRNG (confirmed
;; against a real TLS handshake elsewhere in this client -- rsa/ecdsa key
;; material is real, so the interpreter's own secure RNG is trustworthy
;; here too). Building raw bytes from `random/secure 256` needs `to binary!
;; reduce [n]` rather than `to-char n` + append: TO-CHAR treats a value
;; above 127 as a Unicode code point and a binary APPEND of a char! UTF-8-
;; encodes it, silently expanding a single byte 0x80-0xFF into two or more
;; -- confirmed directly by probing this build. `to binary! reduce [n]`
;; instead produces the exact single raw byte every time.
;; ===========================================================================

random-bytes: function [n [integer!]] [
    result: make binary! n
    repeat i n [append result to binary! reduce [(random/secure 256) - 1]]
    result
]

uuid-v4: function [] [
    raw: random-bytes 16
    ;; RFC 4122 version 4 / variant bits.
    poke raw 7 (to-integer (raw/7 and 15)) or 64
    poke raw 9 (to-integer (raw/9 and 63)) or 128
    hex: lowercase enbase raw 16
    rejoin [
        copy/part hex 8 "-"
        copy/part (at hex 9) 4 "-"
        copy/part (at hex 13) 4 "-"
        copy/part (at hex 17) 4 "-"
        copy/part (at hex 21) 12
    ]
]

;; ===========================================================================
;; URL parsing. Convex deployment URLs never carry a path, query, or
;; fragment, so this deliberately does not try to parse one -- only the
;; scheme, host, and optional port.
;; ===========================================================================

digit-charset: charset [#"0" - #"9"]
all-digits?: function [s [string!]] [all [not empty? s parse s [some digit-charset]]]
parse-nonneg-int: function [s [string!]] [either all-digits? s [to-integer s] [none]]

parse-convex-url: function [url [string!]] [
    case [
        (copy/part url 8) == "https://" [secure: true rest: copy at url 9]
        (copy/part url 7) == "http://" [secure: false rest: copy at url 8]
        true [return object [ok: false reason: "the deployment URL must start with http:// or https://"]]
    ]
    if empty? rest [return object [ok: false reason: "the deployment URL has no host"]]
    slash: find rest "/"
    if slash [rest: copy/part rest (index? slash) - 1]
    if empty? rest [return object [ok: false reason: "the deployment URL has no host"]]
    colon: find rest ":"
    either colon [
        host: copy/part rest (index? colon) - 1
        port-text: copy next colon
        port-number: parse-nonneg-int port-text
        if none? port-number [return object [ok: false reason: "the deployment URL port is invalid"]]
    ] [
        host: rest
        port-number: either secure [443] [80]
    ]
    if empty? host [return object [ok: false reason: "the deployment URL has no host"]]
    if any [port-number < 1 port-number > 65535] [
        return object [ok: false reason: "the deployment URL port is invalid"]
    ]
    host-header: either colon [rejoin [host ":" port-number]] [host]
    ;; NOTE: object construction rebinds any bare word in this spec block
    ;; that also names one of ITS OWN fields to the new (as yet unset)
    ;; object's own slot instead of the outer local of the same name --
    ;; the same object-construction trap client/json.r3's header comment
    ;; documents for make-parse-state. `secure: secure`/`host: host`/etc
    ;; would each silently read back none. Building a fixed-shape skeleton
    ;; first and then filling it in with ordinary SET-PATHs sidesteps this
    ;; entirely: a set-path (`out/field:`) is never rebound by object
    ;; construction the way a bare set-word in the spec block is, and
    ;; unlike COMPOSE it never re-quotes a word!-typed value into
    ;; evaluable source either (COMPOSE's other trap -- splicing a bare
    ;; word! value like a status symbol makes the object spec try to
    ;; evaluate it as a variable reference instead of storing it as data;
    ;; caught directly here by sock-read-once's `outcome` field, which
    ;; holds symbols like 'ok/'timeout).
    out: make object! [ok: none secure: none host: none port-number: none host-header: none]
    out/ok: true
    out/secure: secure
    out/host: host
    out/port-number: port-number
    out/host-header: host-header
    out
]

;; ===========================================================================
;; Low-level sockets. Every async round trip below follows the same shape:
;; install an awake that stops waiting (returns the literal TRUE) on exactly
;; the event this call cares about, transparently re-opening on `lookup`
;; (the DNS-resolved handshake step every tcp:// port needs before it can
;; actually connect), and call `wait` exactly once. The caller's own loop
;; (in http-request / ws-recv-message / livePump) decides whether to issue
;; another round trip, not this layer -- this keeps every deadline budget
;; explicit and visible at the call site, matching AGENTS.md's single-owner
;; requirement for Live's socket.
;;
;; NOTE: these two helpers are the one place in this file where a nested
;; `awake` closure must mutate a plain local belonging to its enclosing
;; function -- exactly the FUNCTION-vs-FUNC trap this file's header warns
;; about. Both enclosing functions are declared with `func` (not `function`)
;; specifically so the inner closure's bare set-words resolve to the outer
;; function's own /local slots instead of silently becoming new locals of
;; the inner closure that vanish the moment `wait` returns.
;; ===========================================================================

open-plain-tcp: func [host [string!] port-number [integer!] timeout-secs [integer!] /local result] [
    result: object [ok: false port: none reason: "connection did not complete"]
    tcp-port: make port! to-url rejoin ["tcp://" host ":" port-number]
    tcp-port/awake: func [event] [
        switch event/type [
            lookup [open event/port return false]
            connect [result: object [ok: true port: event/port reason: none] return true]
            close [result: object [ok: false port: none reason: "connection closed before it was established"] return true]
            error [result: object [ok: false port: none reason: "connection error"] return true]
        ]
        false
    ]
    open tcp-port
    unless port? wait reduce [tcp-port timeout-secs] [
        result: object [ok: false port: none reason: "connection timed out"]
    ]
    result
]

sock-write-once: func [port [port!] data [string! binary!] timeout-secs [decimal! integer!] /local ok] [
    ok: false
    port/awake: func [event] [
        switch event/type [
            wrote [ok: true return true]
            close [return true]
            error [return true]
        ]
        false
    ]
    write port data
    port? wait reduce [port timeout-secs]
    ok
]

;; Reads whatever arrives within timeout-secs. Returns an object with
;; outcome: 'ok / 'timeout / 'eof / 'error and bytes: a fresh binary! of
;; only the newly-arrived data. `port/data` ACCUMULATES across separate
;; read cycles in this build rather than resetting (confirmed directly:
;; two sequential read+wait cycles against a two-chunk drip source showed
;; 5 bytes then 10, not 5 then 5) -- so this copies it out and CLEARS it
;; every call. Skipping that clear would silently re-deliver already-
;; consumed bytes on the next read and grow port/data without bound over
;; a long Live session.
sock-read-once: func [port [port!] timeout-secs [decimal! integer!] /local outcome bytes out] [
    outcome: 'timeout
    port/awake: func [event] [
        switch event/type [
            read [outcome: 'ok return true]
            close [outcome: 'eof return true]
            error [outcome: 'error return true]
        ]
        false
    ]
    read port
    port? wait reduce [port timeout-secs]
    ;; port/data is none rather than an empty binary! until this port has
    ;; ever actually delivered a byte (observed directly: a plain tcp://
    ;; port used for a two-chunk local probe already held an empty
    ;; binary! before its first read, but a verified tls:// port from
    ;; connect-verified-tls did not) -- treat a none the same as "nothing
    ;; new arrived" rather than letting COPY fault on it.
    bytes: either port/data [copy port/data] [make binary! 0]
    if port/data [clear port/data]
    ;; See parse-convex-url's comment: a skeleton object filled in via
    ;; SET-PATH avoids both the self-shadow trap AND (since `outcome` here
    ;; holds a bare word! like 'ok/'timeout) COMPOSE's separate trap of
    ;; re-quoting a spliced word! value into evaluable source.
    out: make object! [outcome: none bytes: none]
    out/outcome: outcome
    out/bytes: bytes
    out
]

sock-close: function [port] [
    if port [try [close port]]
]

;; Opens a connection to cx/host:cx/port-number, verified TLS when
;; cx/secure, plain tcp:// otherwise (the local self-hosted backend runs
;; plain HTTP inside the docker network). Returns the open port, or none
;; with cx/err-* set.
sock-open: func [/local outcome] [
    either cx/secure [
        outcome: connect-verified-tls cx/host cx/port-number cx/trust-bundle
        either outcome/ok [
            outcome/port
        ] [
            set-client-error "TransportError" rejoin ["TLS handshake to " cx/host " failed: " outcome/reason]
            none
        ]
    ] [
        outcome: open-plain-tcp cx/host cx/port-number 10
        either outcome/ok [
            outcome/port
        ] [
            set-client-error "TransportError" rejoin ["cannot connect to " cx/host ":" cx/port-number]
            none
        ]
    ]
]

;; ===========================================================================
;; HTTP/1.1: one request, one connection, one deadline covering connect,
;; write, and the whole response. Buffers are BINARY! throughout (the raw
;; type port/data itself uses) so header search and body slicing are exact
;; byte operations; only the final decoded JSON body is converted to
;; STRING! right before handing it to json-decode.
;; ===========================================================================

crlf2: #{0D0A0D0A}
crlf: #{0D0A}

;; Grows `buffer` (a shared reference -- APPEND mutates the same series the
;; caller holds, so nothing needs to be returned just to grow it) via
;; reads on `port` until it has at least `needed` bytes. Returns true on
;; success, false with cx/err-* set on a transport failure.
read-until-bytes: func [port [port!] deadline [integer!] buffer [binary!] needed [integer!] /local outcome] [
    until [
        if (length? buffer) >= needed [return true]
        outcome: sock-read-once port (remaining-ms deadline) / 1000.0
        case [
            outcome/outcome == 'ok [append buffer outcome/bytes]
            true [set-client-error "TransportError" "the response body ended early" return false]
        ]
        false
    ]
]

;; Grows `buffer` via reads on `port` until `marker` appears in it (or a
;; transport failure/timeout occurs). Returns the FIND position (a series
;; at the marker's start) once found, or none with cx/err-* set.
read-until-marker: func [port [port!] deadline [integer!] buffer [binary!] marker [binary!] /local pos outcome] [
    until [
        pos: find buffer marker
        if pos [return pos]
        outcome: sock-read-once port (remaining-ms deadline) / 1000.0
        case [
            outcome/outcome == 'ok [append buffer outcome/bytes]
            true [set-client-error "TransportError" "the response ended before an expected marker" return none]
        ]
        false
    ]
]

;; Reads from `port` until `buffer` contains at least one full header
;; block (a blank line), or a transport failure/timeout occurs. Returns an
;; object [ok header-end buffer] where header-end is the index? of the
;; first byte after the blank line, or [ok: false] with cx/err-* set.
read-http-headers: func [port [port!] deadline [integer!] buffer [binary!] /local pos out] [
    pos: read-until-marker port deadline buffer crlf2
    unless pos [return object [ok: false]]
    ;; `buffer: buffer` would self-shadow; see parse-convex-url's comment.
    out: make object! [ok: none header-end: none buffer: none]
    out/ok: true
    out/header-end: (index? pos) + 4
    out/buffer: buffer
    out
]

parse-status-line: function [line [string!]] [
    if (copy/part line 5) <> "HTTP/" [return none]
    code: copy/part (at line 10) 3
    either all-digits? code [to-integer code] [none]
]

parse-header-lines: function [lines [block!]] [
    headers: make map! []
    foreach line lines [
        if empty? line [continue]
        colon: find line ":"
        unless colon [continue]
        name: lowercase copy/part line (index? colon) - 1
        value: trim copy next colon
        put headers name value
    ]
    headers
]

http-max-body: 1048576

;; Reads one chunked-transfer-encoding body to completion. `buffer` holds
;; whatever bytes already arrived past the headers; it is consumed (RE-
;; SLICED, not just appended to) as each chunk is read, so the trailing
;; `buffer:` reassignments below matter -- COPY AT makes a fresh series
;; reference starting past the consumed bytes, which the caller does not
;; see unless this function keeps reassigning its own local and returns
;; the final decoded body explicitly (unlike a plain APPEND, reslicing
;; does not mutate anything the caller can see).
read-chunked-body: func [
    port [port!] deadline [integer!] buffer [binary!]
    /local body pos size-line semicolon size done out
][
    body: make binary! 0
    done: false
    until [
        pos: read-until-marker port deadline buffer crlf
        unless pos [return object [ok: false]]
        size-line: to string! copy/part buffer (index? pos) - 1
        semicolon: find size-line ";"
        if semicolon [size-line: copy/part size-line (index? semicolon) - 1]
        size: attempt [to-issue-hex size-line]
        if none? size [
            set-client-error "ProtocolError" "chunked HTTP size is invalid"
            return object [ok: false]
        ]
        buffer: copy at buffer (index? pos) + 2
        either size = 0 [
            done: true
        ] [
            if (length? body) + size > http-max-body [
                set-client-error "ProtocolError" "HTTP body exceeds the response limit"
                return object [ok: false]
            ]
            unless read-until-bytes port deadline buffer (size + 2) [return object [ok: false]]
            if (copy/part at buffer (size + 1) 2) <> crlf [
                set-client-error "ProtocolError" "chunked HTTP data is missing its terminator"
                return object [ok: false]
            ]
            append body copy/part buffer size
            buffer: copy at buffer (size + 3)
        ]
        done
    ]
    ;; `body: body` would self-shadow; see parse-convex-url's comment.
    out: make object! [ok: none body: none]
    out/ok: true
    out/body: body
    out
]

;; Reads the body once headers are known, honoring Content-Length,
;; Transfer-Encoding: chunked, or (neither) a connection-closed body.
;; Returns an object [ok body] with body a BINARY!.
read-http-body: func [
    port [port!] deadline [integer!] headers [map!] buffer [binary!]
    /local outcome length done
][
    if all [(select headers "transfer-encoding") (select headers "content-length")] [
        set-client-error "ProtocolError" "HTTP response has both Transfer-Encoding and Content-Length"
        return object [ok: false]
    ]
    case [
        (lowercase any [select headers "transfer-encoding" ""]) == "chunked" [
            read-chunked-body port deadline buffer
        ]
        (select headers "content-length") [
            length: parse-nonneg-int (select headers "content-length")
            if none? length [
                set-client-error "ProtocolError" "HTTP Content-Length is invalid"
                return object [ok: false]
            ]
            if length > http-max-body [
                set-client-error "ProtocolError" "HTTP body exceeds the response limit"
                return object [ok: false]
            ]
            unless read-until-bytes port deadline buffer length [return object [ok: false]]
            object [ok: true body: copy/part buffer length]
        ]
        true [
            ;; No Content-Length and not chunked: the body runs until the
            ;; peer closes the connection.
            done: false
            until [
                outcome: sock-read-once port (remaining-ms deadline) / 1000.0
                switch outcome/outcome [
                    ok [append buffer outcome/bytes]
                    eof [done: true]
                    timeout [set-client-error "TransportError" "the HTTP body did not complete" return object [ok: false]]
                    error [set-client-error "TransportError" "the HTTP body did not complete" return object [ok: false]]
                ]
                if (length? buffer) > http-max-body [
                    set-client-error "ProtocolError" "HTTP body exceeds the response limit"
                    return object [ok: false]
                ]
                done
            ]
            object [ok: true body: buffer]
        ]
    ]
]

;; A small hex-text-to-integer reader for chunked transfer-encoding size
;; lines, built the same explicit digit-by-digit way client/json.r3 reads a
;; \u escape's four hex digits -- not handed to REBOL's own literal loader,
;; which does not parse bare hex text the same way HTTP chunk framing does.
hex-digit-value: function [c] [
    case [
        all [c (c >= #"0") (c <= #"9")] [(to-integer c) - (to-integer #"0")]
        all [c (c >= #"a") (c <= #"f")] [10 + (to-integer c) - (to-integer #"a")]
        all [c (c >= #"A") (c <= #"F")] [10 + (to-integer c) - (to-integer #"A")]
        true [none]
    ]
]
to-issue-hex: function [s [string!]] [
    if empty? s [do make error! "empty chunk size"]
    v: 0
    foreach c s [
        d: hex-digit-value c
        unless d [do make error! "invalid hex digit"]
        v: (v * 16) + d
    ]
    v
]

;; Performs one HTTP/1.1 POST and returns an object [ok status body] with
;; body a STRING! (the response is always JSON text), or [ok: false] with
;; cx/err-* set on a transport/protocol failure. Any completed HTTP status
;; is `ok: true`; the caller decides what to do with a non-2xx status.
http-request: func [
    path [string!] body [string!]
    /local deadline port request headers-outcome header-text lines status headers body-outcome remainder out
][
    deadline: now-ms + cx/http-total-timeout-ms
    port: sock-open
    unless port [return object [ok: false]]

    request: rejoin [
        "POST " path " HTTP/1.1" "^M^/"
        "Host: " cx/host-header "^M^/"
        "Content-Type: application/json" "^M^/"
        "Accept: application/json" "^M^/"
        "Connection: close" "^M^/"
        "Convex-Client: " cx/client-version "^M^/"
    ]
    if not empty? cx/token [
        append request rejoin ["Authorization: Bearer " cx/token "^M^/"]
    ]
    append request rejoin ["Content-Length: " (length? to binary! body) "^M^/" "^M^/" body]

    unless sock-write-once port request (remaining-ms deadline) / 1000.0 [
        sock-close port
        set-client-error "TransportError" "writing the HTTP request failed"
        return object [ok: false]
    ]

    headers-outcome: read-http-headers port deadline make binary! 0
    unless headers-outcome/ok [sock-close port return object [ok: false]]

    header-text: to string! copy/part headers-outcome/buffer headers-outcome/header-end - 5
    lines: split header-text "^M^/"
    status: parse-status-line lines/1
    unless status [
        sock-close port
        set-client-error "ProtocolError" "HTTP status line is invalid"
        return object [ok: false]
    ]
    headers: parse-header-lines next lines

    remainder: copy at headers-outcome/buffer headers-outcome/header-end
    body-outcome: read-http-body port deadline headers remainder
    sock-close port
    unless body-outcome/ok [return object [ok: false]]

    ;; `status: status` would self-shadow; see parse-convex-url's comment.
    out: make object! [ok: none status: none body: none]
    out/ok: true
    out/status: status
    out/body: to string! body-outcome/body
    out
]

;; ===========================================================================
;; Convex HTTP functions: build the {"path","args","format"} envelope,
;; POST it to /api/<operation>, and decode Convex's own success/error
;; envelope. `args` is already a decoded REBOL value (a map!) -- the
;; adapter and the example both decode the incoming JSON once and pass the
;; native value straight through, rather than re-serializing text the way
;; a text-only client must.
;; ===========================================================================

encode-logs: function [value] [
    ;; Convex's logLines is documented as an array of strings; a
    ;; self-hosted deployment may omit the key entirely when a function
    ;; logged nothing, so a missing key is treated the same as [].
    either all [block? value] [
        foreach item value [unless string? item [return none]]
        value
    ] [
        either none? value [copy []] [none]
    ]
]

convex-call: func [
    operation [string!] path [string!] args [map!]
    /local envelope body response payload status decoded error-message logs out
][
    if cx/url = none [set-client-error "ConfigError" "the client is not open" return object [ok: false]]
    if not find path ":" [set-client-error "ClientError" "function path must be module:function" return object [ok: false]]

    envelope: make map! []
    put envelope "path" path
    put envelope "args" args
    put envelope "format" "json"
    body: json-encode envelope

    response: http-request rejoin ["/api/" operation] body
    unless response/ok [return object [ok: false]]
    if any [response/status < 200 response/status >= 300] [
        set-client-error "TransportError" rejoin ["Convex HTTP request returned status " response/status]
        return object [ok: false]
    ]

    decoded: json-decode response/body
    unless all [decoded/ok map? decoded/value] [
        set-client-error "ProtocolError" rejoin ["HTTP " response/status " returned a non-Convex body"]
        return object [ok: false]
    ]
    payload: decoded/value

    logs: encode-logs select payload "logLines"
    unless logs [
        set-client-error "ProtocolError" "Convex logLines must be an array of strings"
        return object [ok: false]
    ]

    status: select payload "status"
    if status = "success" [
        unless find payload "value" [
            set-client-error "ProtocolError" "a successful Convex response has no value"
            return object [ok: false]
        ]
        ;; `logs: logs` would self-shadow; see parse-convex-url's comment.
        out: make object! [ok: none value: none logs: none]
        out/ok: true
        out/value: select payload "value"
        out/logs: logs
        return out
    ]
    if status = "error" [
        error-message: select payload "errorMessage"
        unless string? error-message [
            set-client-error "ProtocolError" "a failed Convex response has no errorMessage string"
            return object [ok: false]
        ]
        cx/err-name: "FunctionError"
        cx/err-message: error-message
        cx/err-data: select payload "errorData"
        return object [ok: false]
    ]
    set-client-error "ProtocolError" rejoin ["HTTP " response/status " response has an unknown status"]
    object [ok: false]
]

convex-query: function [path [string!] args [map!]] [convex-call "query" path args]
convex-mutation: function [path [string!] args [map!]] [convex-call "mutation" path args]
convex-action: function [path [string!] args [map!]] [convex-call "action" path args]

;; ===========================================================================
;; Convex integral-decimal rule and safe field access, re-exposed here for
;; example/adapter callers so they need not reach back into json.r3
;; directly for these two very common checks.
;; ===========================================================================

convex-field-integer: function [value-map [map!] key [string!]] [
    node: select value-map key
    either all [(convex-integral? node)] [convex-integral-to-integer node] [none]
]

;; Rebuilds a map! without `key`. map!'s own REMOVE/KEY was observed, in a
;; direct probe against this build, to leave FIND still reporting a key as
;; present after REMOVE/KEY had already made it disappear from MOLD and
;; FOREACH -- a real inconsistency between map!'s hash lookup and its
;; iteration/print paths, not a hypothetical. Rebuilding a fresh map that
;; simply omits the one key sidesteps that inconsistency entirely rather
;; than depending on it.
map-without-key: function [m [map!] key [string!]] [
    result: make map! []
    foreach [k v] m [unless k = key [put result k v]]
    result
]

;; ===========================================================================
;; WebSocket: RFC 6455 handshake and frame codec over the same verified TLS
;; or plain tcp:// socket the HTTP layer uses. checksum .../sha1 and
;; enbase/debase (this fork's own crypto/base64 natives, already proven
;; against a real TLS handshake by x509.r3's signature checks) make the
;; Sec-WebSocket-Accept digest a one-liner -- no hand-rolled SHA-1 needed,
;; unlike a language whose runtime has no built-in digest. Masking is
;; likewise a single binary XOR: confirmed directly that XOR between a
;; longer and a shorter binary! CYCLES the shorter operand byte-for-byte
;; (exactly RFC 6455's repeating mask key), rather than erroring or
;; truncating.
;; ===========================================================================

ws-guid: does ["258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]
ws-max-frame: 1048576

u16be: function [n [integer!]] [to binary! reduce [(n >> 8) and 255 n and 255]]
u32be: function [n [integer!]] [
    to binary! reduce [(n >> 24) and 255 (n >> 16) and 255 (n >> 8) and 255 n and 255]
]

;; Opens a fresh connection and completes the RFC 6455 upgrade handshake
;; against /api/sync. Returns the open port (any bytes read past the
;; handshake response are kept in cx/ws-buf for the frame reader), or none
;; with cx/err-* set.
ws-handshake: func [
    /local port key accept request deadline headers-outcome header-text lines status headers
][
    port: sock-open
    unless port [return none]
    deadline: now-ms + cx/live-connect-timeout-ms

    key: enbase (random-bytes 16) 64
    accept: enbase (checksum (to-binary rejoin [key ws-guid]) 'sha1) 64

    request: rejoin [
        "GET /api/sync HTTP/1.1" "^M^/"
        "Host: " cx/host-header "^M^/"
        "Upgrade: websocket" "^M^/"
        "Connection: Upgrade" "^M^/"
        "Sec-WebSocket-Key: " key "^M^/"
        "Sec-WebSocket-Version: 13" "^M^/"
        "Convex-Client: " cx/client-version "^M^/" "^M^/"
    ]
    unless sock-write-once port request (remaining-ms deadline) / 1000.0 [
        sock-close port
        set-client-error "TransportError" "the WebSocket upgrade write failed"
        return none
    ]

    headers-outcome: read-http-headers port deadline make binary! 0
    unless headers-outcome/ok [sock-close port return none]
    header-text: to string! copy/part headers-outcome/buffer headers-outcome/header-end - 5
    lines: split header-text "^M^/"
    status: parse-status-line lines/1
    unless status = 101 [
        sock-close port
        set-client-error "ProtocolError" rejoin ["the WebSocket upgrade returned status " any [status "?"]]
        return none
    ]
    headers: parse-header-lines next lines
    if (select headers "sec-websocket-accept") <> accept [
        sock-close port
        set-client-error "ProtocolError" "the WebSocket upgrade returned the wrong accept digest"
        return none
    ]

    cx/ws-buf: copy at headers-outcome/buffer headers-outcome/header-end
    port
]

;; A masked client -> server data frame carrying the whole message in one
;; frame; every message this client sends is a short sync-protocol control
;; message, so fragmentation on the way out is never needed.
ws-send: func [
    port [port!] opcode [integer!] payload [string! binary!] timeout-secs [decimal! integer!]
    /local raw mask n length-field frame masked
][
    raw: to binary! payload
    mask: random-bytes 4
    n: length? raw
    frame: to binary! reduce [128 + opcode]
    length-field: case [
        n < 126 [to binary! reduce [128 + n]]
        n < 65536 [rejoin [to binary! reduce [254] u16be n]]
        true [rejoin [to binary! reduce [255 0 0 0 0] u32be n]]
    ]
    masked: either empty? raw [raw] [raw xor mask]
    sock-write-once port (rejoin [frame length-field mask masked]) timeout-secs
]

ws-frame-failure: function [outcome-symbol [word!]] [
    out: make object! [outcome: none fin: none opcode: none payload: none]
    out/outcome: outcome-symbol
    out
]

;; Ensures cx/ws-buf holds at least `need` bytes, reading more from `port`
;; as needed. Returns 'ok / 'timeout / 'eof / 'error; on 'ok, cx/ws-buf has
;; at least `need` bytes.
ws-fill: func [port [port!] deadline [integer!] need [integer!] /local outcome] [
    until [
        if (length? cx/ws-buf) >= need [return 'ok]
        outcome: sock-read-once port (remaining-ms deadline) / 1000.0
        case [
            outcome/outcome == 'ok [append cx/ws-buf outcome/bytes]
            true [return outcome/outcome]
        ]
        false
    ]
]

;; Reads exactly one WebSocket frame (server frames are never masked).
ws-read-frame: func [
    port [port!] deadline [integer!]
    /local outcome fin opcode len-field extra hi lo payload out
][
    outcome: ws-fill port deadline 2
    unless outcome == 'ok [return ws-frame-failure outcome]
    fin: (cx/ws-buf/1 and 128) <> 0
    opcode: cx/ws-buf/1 and 15
    len-field: cx/ws-buf/2 and 127   ; the mask bit on a server frame is always 0
    extra: 2
    case [
        len-field = 126 [
            outcome: ws-fill port deadline 4
            unless outcome == 'ok [return ws-frame-failure outcome]
            len-field: (cx/ws-buf/3 * 256) + cx/ws-buf/4
            extra: 4
        ]
        len-field = 127 [
            outcome: ws-fill port deadline 10
            unless outcome == 'ok [return ws-frame-failure outcome]
            hi: to-integer copy/part at cx/ws-buf 3 4
            lo: to-integer copy/part at cx/ws-buf 7 4
            len-field: either hi > 0 [ws-max-frame + 1] [lo]
            extra: 10
        ]
        true [none]
    ]
    if len-field > ws-max-frame [return ws-frame-failure 'toolarge]
    outcome: ws-fill port deadline (extra + len-field)
    unless outcome == 'ok [return ws-frame-failure outcome]
    payload: copy/part at cx/ws-buf (extra + 1) len-field
    cx/ws-buf: copy at cx/ws-buf (extra + len-field + 1)
    out: make object! [outcome: none fin: none opcode: none payload: none]
    out/outcome: 'ok
    out/fin: fin
    out/opcode: opcode
    out/payload: payload
    out
]

;; Reassembles continuation frames into one logical message, answers PINGs
;; inline, and reports a peer CLOSE as its own outcome so the caller never
;; mistakes it for an ordinary data message. Only a data/continuation
;; frame's own FIN bit can end the loop -- a ping is always FIN=1 by RFC
;; 6455 but must never itself look like the end of the message it may be
;; interleaved into.
ws-recv-message: func [
    port [port!] deadline [integer!]
    /local frame message-opcode payload assembling done out
][
    payload: make binary! 0
    assembling: false
    message-opcode: 0
    done: false
    until [
        frame: ws-read-frame port deadline
        case [
            frame/outcome <> 'ok [
                out: make object! [outcome: none opcode: none payload: none]
                out/outcome: frame/outcome
                return out
            ]
            frame/opcode = 9 [   ; ping: answer inline, message is not done
                ws-send port 10 frame/payload (remaining-ms deadline) / 1000.0
            ]
            frame/opcode = 10 [none]   ; unsolicited pong: ignore
            frame/opcode = 8 [
                out: make object! [outcome: none opcode: none payload: none]
                out/outcome: 'close
                return out
            ]
            true [
                unless assembling [message-opcode: frame/opcode assembling: true]
                append payload frame/payload
                if frame/fin [done: true]
            ]
        ]
        done
    ]
    out: make object! [outcome: none opcode: none payload: none]
    out/outcome: 'ok
    out/opcode: message-opcode
    out/payload: payload
    out
]

;; ===========================================================================
;; Live: the Convex sync protocol state machine over /api/sync.
;;
;; Scope matches every other hand-rolled client in this repo: a single
;; connection is brought up on the first subscribe and torn down on close.
;; This section owns the wire protocol itself -- Connect, ModifyQuerySet
;; (Add/Remove), and validating a Transition before publishing any part of
;; it -- plus live-maybe-reconnect, which the adapter/example's own main
;; loop polls on every pass to bring a dropped connection back with
;; exponential backoff. debugDisconnect itself just calls live-retire
;; directly; live-maybe-reconnect is what notices the empty socket
;; afterwards and re-establishes it.
;; ===========================================================================

;; Compares two Convex sync-protocol timestamps -- base64 of a LITTLE-
;; endian uint64, confirmed empirically elsewhere in this project against a
;; live transition's endVersion.ts lined up against its accompanying
;; decimal serverTs -- so the most significant byte is the LAST byte of
;; the decoded string. -1/0/1, like a normal three-way compare.
ts-compare: function [a [string!] b [string!]] [
    ba: debase a 64
    bb: debase b 64
    la: length? ba
    lb: length? bb
    either la <> lb [either la < lb [-1] [1]] [
        result: 0
        i: la
        while [all [(result = 0) (i >= 1)]] [
            x: pick ba i
            y: pick bb i
            case [
                x < y [result: -1]
                x > y [result: 1]
                true [none]
            ]
            i: i - 1
        ]
        result
    ]
]

live-connect-message: function [] [
    m: make map! []
    put m "type" "Connect"
    put m "sessionId" cx/session
    put m "connectionCount" cx/live-connection-count
    put m "lastCloseReason" cx/live-last-close
    put m "clientTs" 0
    if cx/live-max-timestamp <> cx/live-initial-timestamp [
        put m "maxObservedTimestamp" cx/live-max-timestamp
    ]
    m
]

live-add-modification: function [qid [string!]] [
    sub: select cx/subs qid
    m: make map! []
    put m "type" "Add"
    put m "queryId" (to-integer qid)
    put m "udfPath" sub/path
    args-block: copy []
    append/only args-block sub/args
    put m "args" args-block
    m
]

live-remove-modification: function [qid [string!]] [
    m: make map! []
    put m "type" "Remove"
    put m "queryId" (to-integer qid)
    m
]

;; Brings up a connection and replays the whole active query set. Every
;; reconnect resends these Add operations, which is what lets a
;; subscription survive a dropped socket. Returns true/false; on failure
;; cx/live-last-close carries the reason the *next* Connect message
;; reports.
live-connect: func [
    /local port qid sub modifications count envelope mods
][
    port: ws-handshake
    unless port [
        cx/live-last-close: any [cx/err-message "connection failed"]
        return false
    ]
    cx/live-socket: port
    cx/live-remote-query-set: 0
    cx/live-remote-identity: 0
    cx/live-remote-timestamp: cx/live-initial-timestamp
    cx/live-query-set-version: 0
    ;; A successful handshake resets backoff: a healthy connection must not
    ;; inherit a stale maximum delay from an earlier run of failures.
    cx/live-backoff-ms: cx/live-backoff-base-ms
    cx/live-retry-at: 0

    ws-send port 1 (json-encode live-connect-message) (cx/live-write-timeout-ms / 1000.0)
    cx/live-connection-count: cx/live-connection-count + 1

    modifications: copy []
    count: 0
    foreach [qid sub] cx/subs [
        append/only modifications live-add-modification qid
        ;; Every resent Add is a candidate for an unchanged rehydration,
        ;; but only when the subscription's last delivery was a real
        ;; value: one that has never delivered anything yet, or whose
        ;; last delivery was an error, still wants its next value
        ;; delivered unconditionally.
        sub/awaiting-rehydration: all [sub/has-value (not sub/err-name)]
        count: count + 1
    ]
    if count > 0 [
        envelope: make map! []
        put envelope "type" "ModifyQuerySet"
        put envelope "baseVersion" 0
        put envelope "newVersion" 1
        put envelope "modifications" modifications
        ws-send port 1 (json-encode envelope) (cx/live-write-timeout-ms / 1000.0)
        cx/live-query-set-version: 1
    ]
    true
]

live-ensure-connection: func [] [
    if cx/live-socket [return true]
    live-connect
]

convex-subscribe: func [
    tag [string!] path [string!] args [map!]
    /local qid sub was-connected envelope mods
][
    if cx/url = none [return set-client-error "ConfigError" "the client is not open"]
    if not find path ":" [return set-client-error "ClientError" "function path must be module:function"]

    if select cx/tag-to-qid tag [convex-unsubscribe tag]

    qid: form cx/live-next-query-id
    cx/live-next-query-id: cx/live-next-query-id + 1
    sub: make object! [
        path: none args: none tag: none value: none logs: none
        err-name: none err-message: none err-data: none
        has-value: false version: 0 awaiting-rehydration: false
    ]
    sub/path: path
    sub/args: args
    sub/tag: tag
    sub/has-value: false
    sub/version: 0
    put cx/subs qid sub
    put cx/tag-to-qid tag qid

    ;; Whether a connection was already up has to be captured BEFORE
    ;; calling live-ensure-connection: that call itself flips cx/live-
    ;; socket from none to a real port on a successful cold start, so
    ;; testing cx/live-socket again afterwards can no longer tell the two
    ;; cases apart. A cold start's own Add was already sent by live-
    ;; connect's replay above; only a subscribe on an ALREADY-open
    ;; connection needs its own incremental Add sent here.
    was-connected: not none? cx/live-socket
    unless was-connected [
        unless live-ensure-connection [
            return set-client-error "TransportError" rejoin ["Live connection failed: " cx/live-last-close]
        ]
        return true
    ]

    envelope: make map! []
    put envelope "type" "ModifyQuerySet"
    put envelope "baseVersion" cx/live-query-set-version
    put envelope "newVersion" (cx/live-query-set-version + 1)
    mods: copy []
    append/only mods live-add-modification qid
    put envelope "modifications" mods
    unless ws-send cx/live-socket 1 (json-encode envelope) (cx/live-write-timeout-ms / 1000.0) [
        cx/subs: map-without-key cx/subs qid
        cx/tag-to-qid: map-without-key cx/tag-to-qid tag
        return set-client-error "TransportError" "Live subscribe failed"
    ]
    cx/live-query-set-version: cx/live-query-set-version + 1
    true
]

convex-unsubscribe: func [tag [string!] /local qid envelope mods] [
    qid: select cx/tag-to-qid tag
    unless qid [return true]
    if cx/live-socket [
        envelope: make map! []
        put envelope "type" "ModifyQuerySet"
        put envelope "baseVersion" cx/live-query-set-version
        put envelope "newVersion" (cx/live-query-set-version + 1)
        mods: copy []
        append/only mods live-remove-modification qid
        put envelope "modifications" mods
        if ws-send cx/live-socket 1 (json-encode envelope) (cx/live-write-timeout-ms / 1000.0) [
            cx/live-query-set-version: cx/live-query-set-version + 1
        ]
    ]
    cx/subs: map-without-key cx/subs qid
    cx/tag-to-qid: map-without-key cx/tag-to-qid tag
    true
]

;; ---------------------------------------------------------------------
;; Server -> client messages
;; ---------------------------------------------------------------------

live-version: function [node] [
    unless map? node [return none]
    qs-node: select node "querySet"
    id-node: select node "identity"
    ts-node: select node "ts"
    unless all [(convex-integral? qs-node) (convex-integral? id-node) (string? ts-node)] [return none]
    out: make object! [query-set: none identity: none ts: none]
    out/query-set: convex-integral-to-integer qs-node
    out/identity: convex-integral-to-integer id-node
    out/ts: ts-node
    out
]

;; Validates and stages one modification. Returns an object with either
;; [value logs] (QueryUpdated), [message data logs] (QueryFailed), or all
;; none (QueryRemoved), or none on a malformed modification -- the caller
;; treats none as a protocol failure.
live-change: function [change [map!] kind [string!]] [
    logs-node: select change "logLines"
    logs: either logs-node [encode-logs logs-node] [copy []]
    unless logs [return none]
    case [
        kind = "QueryUpdated" [
            unless find change "value" [return none]
            out: make object! [value: none logs: none message: none data: none]
            out/value: select change "value"
            out/logs: logs
            out
        ]
        kind = "QueryFailed" [
            msg-node: select change "errorMessage"
            unless string? msg-node [return none]
            out: make object! [value: none logs: none message: none data: none]
            out/message: msg-node
            out/data: select change "errorData"
            out/logs: logs
            out
        ]
        kind = "QueryRemoved" [make object! [value: none logs: none message: none data: none]]
        true [none]
    ]
]

;; Validates a Transition against the locally-tracked remote state, applies
;; every modification for a subscription this client actually has (in
;; first-seen order within the transition, matching every other client in
;; this repo), and publishes the result. A reconnect resends the whole
;; active query set, so the server's first Transition after it is exactly
;; as likely to be a genuine rehydration of an already-known value as a
;; real change: only a byte-identical QueryUpdated during that one
;; rehydration window is suppressed; an error is never suppressed, and any
;; later Transition on the same subscription is a normal update again.
live-transition: func [
    root [map!]
    /local start end mods bad bad-reason order staged change kind-node qid-node kind qid staged-entry
    sub is-updated is-failed rehydrating suppress
][
    bad: false
    bad-reason: none
    start: live-version select root "startVersion"
    end: live-version select root "endVersion"
    case [
        any [not start not end] [bad: true bad-reason: "Live transition has an invalid state version"]
        any [
            (start/query-set <> cx/live-remote-query-set)
            (start/identity <> cx/live-remote-identity)
            (start/ts <> cx/live-remote-timestamp)
        ] [bad: true bad-reason: "Live transition does not continue the local state"]
        (ts-compare end/ts start/ts) < 0 [bad: true bad-reason: "Live timestamp moved backwards"]
        any [(end/query-set < start/query-set) (end/identity < start/identity)] [
            bad: true bad-reason: "Live state version counter moved backwards"
        ]
        true [none]
    ]
    unless bad [
        mods: select root "modifications"
        unless block? mods [bad: true bad-reason: "Live transition has no modifications array"]
    ]

    order: copy []            ; qid strings, first-seen order, subs this client has only
    staged: make map! []      ; qid -> object [kind entry]
    unless bad [
        foreach change mods [
            if bad [break]
            unless map? change [bad: true bad-reason: "Live modification is not an object" break]
            kind-node: select change "type"
            qid-node: select change "queryId"
            unless all [string? kind-node (convex-integral? qid-node)] [
                bad: true bad-reason: "Live modification is malformed" break
            ]
            kind: kind-node
            qid: form convex-integral-to-integer qid-node
            staged-entry: live-change change kind
            unless staged-entry [bad: true bad-reason: rejoin ["Live modification is malformed: " kind] break]
            if select cx/subs qid [
                unless select staged qid [append order qid]
                slot: make object! [kind: none entry: none]
                slot/kind: kind
                slot/entry: staged-entry
                put staged qid slot
            ]
        ]
    ]

    if bad [live-retire "ProtocolError" bad-reason return false]

    cx/live-remote-query-set: end/query-set
    cx/live-remote-identity: end/identity
    cx/live-remote-timestamp: end/ts
    if (ts-compare end/ts cx/live-max-timestamp) > 0 [cx/live-max-timestamp: end/ts]

    foreach qid order [
        sub: select cx/subs qid
        staged-entry: select staged qid
        kind: staged-entry/kind
        is-updated: kind = "QueryUpdated"
        is-failed: kind = "QueryFailed"
        rehydrating: sub/awaiting-rehydration
        suppress: all [is-updated rehydrating (sub/value = staged-entry/entry/value)]
        if any [is-updated is-failed] [sub/awaiting-rehydration: false]
        if all [is-updated (not suppress)] [
            sub/value: staged-entry/entry/value
            sub/logs: staged-entry/entry/logs
            sub/err-name: none
            sub/err-message: none
            sub/err-data: none
            sub/has-value: true
            sub/version: sub/version + 1
        ]
        if is-failed [
            sub/err-name: "FunctionError"
            sub/err-message: staged-entry/entry/message
            sub/err-data: staged-entry/entry/data
            sub/logs: staged-entry/entry/logs
            sub/value: none
            sub/has-value: true
            sub/version: sub/version + 1
        ]
    ]
    true
]

live-handle-message: func [text [string!] /local decoded root kind-node kind message-node message] [
    decoded: json-decode text
    unless all [decoded/ok map? decoded/value] [
        live-retire "ProtocolError" "Live message is not a JSON object"
        return false
    ]
    root: decoded/value
    kind-node: select root "type"
    unless string? kind-node [
        live-retire "ProtocolError" "Live message has no type"
        return false
    ]
    kind: kind-node
    if kind = "Transition" [return live-transition root]
    if any [kind = "Ping" kind = "MutationResponse" kind = "ActionResponse"] [return true]
    if any [kind = "FatalError" kind = "AuthError"] [
        message-node: select root "error"
        message: either string? message-node [message-node] [kind]
        live-retire "ProtocolError" rejoin ["Live server reported " kind ": " message]
        return false
    ]
    live-retire "ProtocolError" rejoin ["unsupported Live server message: " kind]
    false
]

;; A transport or protocol fault retires the socket but keeps every
;; subscription: live-maybe-reconnect (polled from live-pump on every
;; adapter/example loop tick) replays the whole active set on the next
;; successful connect. cx/live-retry-at is reset to "now" so the very next
;; reconnect attempt is immediate, at the base backoff -- a drop from a
;; previously healthy connection should not inherit a stale, grown delay
;; from some earlier, unrelated run of failures (live-connect already
;; resets cx/live-backoff-ms itself on the next success; this only
;; controls the timing of that attempt).
live-retire: func [name [string!] message [string!]] [
    if cx/live-socket [sock-close cx/live-socket]
    cx/live-socket: none
    cx/live-remote-query-set: 0
    cx/live-remote-identity: 0
    cx/live-remote-timestamp: cx/live-initial-timestamp
    cx/live-query-set-version: 0
    cx/live-last-close: message
    set-client-error name message
    cx/live-retry-at: now-ms
]

;; Reconnect-on-drop with exponential backoff. Only attempts a connection
;; when one is actually wanted (at least one subscription is registered)
;; and the backoff window has elapsed; a fresh convex-subscribe with no
;; active connection goes straight through live-ensure-connection instead
;; of waiting on this schedule. A failed attempt here reuses live-
;; connect's own failure bookkeeping and only advances the backoff timer
;; -- it never surfaces an error to a caller, since nothing is waiting
;; synchronously on a background reconnect.
live-maybe-reconnect: func [/local any-subs k v] [
    if cx/live-socket [return none]
    if (now-ms) < cx/live-retry-at [return none]
    any-subs: false
    foreach [k v] cx/subs [any-subs: true]
    unless any-subs [return none]
    unless live-connect [
        cx/live-retry-at: (now-ms) + cx/live-backoff-ms
        cx/live-backoff-ms: cx/live-backoff-ms * 2
        if cx/live-backoff-ms > cx/live-backoff-max-ms [cx/live-backoff-ms: cx/live-backoff-max-ms]
    ]
]

;; Pumps the Live socket for up to timeout-ms, first giving a dropped
;; connection a chance to reconnect. Returns 'ok if a message was
;; processed, 'timeout if nothing arrived (including while merely waiting
;; out backoff), 'retired if the connection just failed (subscriptions
;; remain registered for the next connect attempt).
live-pump: func [timeout-ms [integer!] /local deadline recv text] [
    live-maybe-reconnect
    if cx/live-socket = none [return 'timeout]
    deadline: (now-ms) + timeout-ms
    recv: ws-recv-message cx/live-socket deadline
    if recv/outcome == 'timeout [return 'timeout]
    if recv/outcome == 'ok [
        ;; UTF-8 is validated exactly once, here, after the whole message
        ;; has been reassembled across every fragment -- never per frame.
        text: attempt [to string! recv/payload]
        either text [live-handle-message text] [
            live-retire "ProtocolError" "Live message is not valid UTF-8"
        ]
        return 'ok
    ]
    live-retire "TransportError" "the Live connection closed"
    'retired
]

;; Blocks until `tag`'s subscription has published a new value or error,
;; or timeout-ms elapses. Used by the canonical example, which only ever
;; needs the next update on one subscription rather than the adapter's
;; general multi-subscription fan-out.
convex-wait-update: func [
    tag [string!] timeout-ms [integer!]
    /local deadline qid sub start-version
][
    deadline: (now-ms) + timeout-ms
    qid: select cx/tag-to-qid tag
    unless qid [return set-client-error "ClientError" "unknown subscription tag"]
    sub: select cx/subs qid
    start-version: sub/version
    until [
        live-pump remaining-ms deadline
        sub: select cx/subs qid
        any [(not sub) (sub/version <> start-version) ((remaining-ms deadline) = 0)]
    ]
    sub: select cx/subs qid
    unless all [sub (sub/version <> start-version)] [
        return set-client-error "TransportError" "timed out waiting for a Live update"
    ]
    out: make object! [ok: none has-error: none err-name: none err-message: none err-data: none value: none logs: none]
    out/ok: true
    out/has-error: not none? sub/err-name
    either sub/err-name [
        out/err-name: sub/err-name
        out/err-message: sub/err-message
        out/err-data: sub/err-data
    ] [
        out/value: sub/value
    ]
    out/logs: sub/logs
    out
]

convex-close-live: func [timeout-ms [decimal! integer!]] [
    if cx/live-socket [
        ws-send cx/live-socket 8 "" timeout-ms
        sock-close cx/live-socket
    ]
    cx/live-socket: none
    cx/subs: make map! []
    cx/tag-to-qid: make map! []
]

;; Adapter-only: forces the Live socket to drop as if the transport failed,
;; so the shared conformance controller can prove real reconnects.
;; live-maybe-reconnect (polled every loop tick) is what notices the empty
;; socket afterwards and brings a fresh connection back up.
convex-debug-disconnect: func [] [
    live-retire "TransportError" "debugDisconnect"
    true
]

;; ===========================================================================
;; Lifecycle
;; ===========================================================================

;; `client-dir` is the directory client/convex.r3 itself lives in (the
;; caller's own %./ is whatever directory THEY run from, which is not
;; reliably the client directory once this file is `do`ne from an example
;; or the adapter one level up) -- used to find ca-bundle/ beside this
;; file regardless of the caller's own location. system/script/path
;; already IS the directory of the script currently being evaluated (not
;; the file including its own name -- confirmed directly: a nested `do`
;; changes it to the nested script's own directory for the duration of
;; that script and restores the caller's directory afterward), so this
;; needs no split-path.
client-dir: system/script/path

convex-open: func [url [string!] version [string!] /local parsed] [
    parsed: parse-convex-url url
    unless parsed/ok [return set-client-error "ConfigError" parsed/reason]
    cx/url: url
    cx/secure: parsed/secure
    cx/host: parsed/host
    cx/port-number: parsed/port-number
    cx/host-header: parsed/host-header
    cx/client-version: either empty? version ["rebol-0.1.0"] [version]
    cx/token: ""
    cx/session: uuid-v4
    cx/epoch: now/precise
    cx/trust-bundle: either cx/secure [load-trust-bundle to-file rejoin [client-dir "ca-bundle/"]] [copy []]

    cx/http-connect-timeout-ms: 5000
    cx/http-total-timeout-ms: 15000
    cx/live-connect-timeout-ms: 5000
    cx/live-write-timeout-ms: 2000
    cx/live-initial-timestamp: "AAAAAAAAAAA="
    cx/live-last-close: "InitialConnect"
    cx/live-max-timestamp: cx/live-initial-timestamp
    cx/live-remote-query-set: 0
    cx/live-remote-identity: 0
    cx/live-remote-timestamp: cx/live-initial-timestamp
    cx/live-connection-count: 0
    cx/live-query-set-version: 0
    cx/live-socket: none
    cx/live-next-query-id: 0
    cx/live-backoff-base-ms: 250
    cx/live-backoff-max-ms: 30000
    cx/live-backoff-ms: 250
    cx/live-retry-at: 0
    cx/ws-buf: #{}
    cx/subs: make map! []
    cx/tag-to-qid: make map! []
    true
]

convex-set-auth: func [token [string!]] [
    cx/token: token
    true
]

convex-runtime-version: does [
    rejoin ["Rebol/Bulk " system/product " " (mold system/version) "; native-rebol-0.1.0"]
]
