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
    bytes: copy port/data
    clear port/data
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
