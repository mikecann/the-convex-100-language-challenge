Rebol [
    Title: "Convex REBOL conformance adapter -- NDJSON protocol v1"
    Purpose: {
        Test infrastructure, not public client code (see AGENTS.md's
        "Conformance executable" section and rebol/README.md): it wraps
        client/convex.r3's public convex-* functions and speaks the shared
        harness's NDJSON adapter protocol v1 over stdin/stdout, or over one
        accepted controller connection when ADAPTER_LISTEN=host:port is set.
        stdout (or the controller socket) carries protocol events only;
        every diagnostic goes to stderr via `diagnose`.

        This process is single threaded and single-owner: the loop below is
        the only thing that ever touches client/convex.r3's Live socket,
        matching AGENTS.md's "one worker" requirement -- there are no
        subscription or controller threads racing it here to begin with.

        Two real environment findings shaped this file's transport code,
        both confirmed directly against Rebol/Bulk 3.22.1 rather than
        assumed from documentation:

        1. `system/ports/input` (stdin) does NOT participate in this
           build's async port model at all. The standard REBOL pattern
           this client already relies on for tcp:// ports elsewhere
           (install `port/awake`, call `read port` to queue the
           operation, then `wait reduce [port timeout]` and let the
           awake handler's 'read event fire) was tested directly against
           stdin with data already sitting in the pipe before the
           process even started: no 'read event ever fired, `wait`
           returned none only after burning the FULL requested timeout
           regardless of its length, and `port/data` stayed empty the
           whole time. A single, ordinary SYNCHRONOUS `read port` call
           (no `wait` involved) works correctly and returns exactly the
           bytes currently available, blocking only when none are yet
           available and returning an empty binary! at EOF -- but with
           no way to bound that block, and with one more sharp edge:
           when the writer closes stdin without a delay after its last
           line, that final line's own trailing newline never arrives at
           all (confirmed directly: two piped lines sent back-to-back
           come back from one `read` with only the line-INTERNAL
           newline intact, and the following `read` reports plain EOF
           rather than ever flushing the missing one). ad-read-command's
           stdio branch treats a non-empty leftover buffer at true EOF as
           one final complete line for exactly this reason, rather than
           silently discarding it. Because of the missing-wait finding,
           stdin/stdout
           transport mode below cannot interleave "pump Live" with
           "wait for the next controller line" the way TCP mode does:
           it pumps Live for one bounded slice, then blocks
           synchronously on the next stdin line. A Live push that
           arrives while stdin is blocked is not lost (the OS socket
           buffers it, and client/convex.r3's own WebSocket read
           buffering does the rest), just delayed until the next time
           control returns to live-pump. TCP mode has no such gap:
           both the accepted controller connection and the Live socket
           are genuine tcp:// ports, whose async wait/timeout behavior
           is exactly what the rest of this client already depends on
           and proves throughout. AGENTS.md documents ADAPTER_LISTEN as
           "the TCP mode used by the shared harness", so the shared
           Live conformance evidence this adapter earns its badge from
           runs over TCP, where this gap does not apply; stdin/stdout
           mode still fully implements protocol v1 (confirmed with a
           build-time hello/close probe, see Dockerfile) for any other
           caller that wants a plain pipe.
        2. A REBOL server (listening) tcp:// port is opened the same way
           client/convex.r3 already opens outbound ones -- `make port!`
           with an `awake` handler installed before `open` -- except the
           URL carries no host (`tcp://:PORT`) and the handler watches
           for `accept` rather than `connect`; the newly accepted
           connection is `first event/port`. Confirmed directly with a
           loopback listener/connector pair in this same Rebol/Bulk
           build before relying on it here.
    }
]

;; Widens REBOL's own file-security sandbox to "allow" before anything
;; else touches a file -- `do %../../client/convex.r3` needs to read it
;; and client/ca-bundle/*.pem, and `diagnose` needs to open %/dev/stderr
;; for writing. Matches examples/basics/main.r3's own top-of-file call for
;; exactly the same reason (this file also runs outside any WORKDIR the
;; Dockerfile's `test` stage sets up for other, non-entrypoint scripts).
secure [file allow]

do %../../convex.r3

;; diagnose(message) -- one line to the real OS stderr, kept entirely
;; separate from the NDJSON events on stdout the shared controller parses.
diagnose: function [message [string!]] [
    err-port: open/write %/dev/stderr
    write err-port rejoin [message "^/"]
    close err-port
]

;; ===========================================================================
;; Adapter state. One global mutable object, matching client/convex.r3's own
;; `cx` -- every function below is declared with FUNCTION (not FUNC) and
;; mutates it through set-PATHs (`ad/field:`), which FUNCTION never auto-
;; locals (only a bare set-WORD is), so this is safe by the same
;; construction convex.r3's own header documents for `cx`.
;; ===========================================================================

ad: object [
    mode: none          ; 'tcp or 'stdio, set by ad-open-transport
    peer: none          ; tcp port! (mode = 'tcp): the accepted controller connection
    listen: none        ; tcp port! (mode = 'tcp): the listening server port
    stdin-port: none    ; port! (mode = 'stdio): system/ports/input
    read-buf: #{}       ; binary! -- bytes read but not yet split into a line
    queue: []           ; block! of objects [text [string!] droppable [logic!]]
    queue-bytes: 0
    published: none     ; map! subscriptionId(string) -> subscription/version already queued
    done: false
]

;; ===========================================================================
;; Transport setup
;; ===========================================================================

;; Splits "host:port" on the LAST colon (defensive against a bracketed
;; IPv6 host, though this project's harness only ever sends a plain
;; IPv4/hostname pair) and returns the port number, or none with a
;; diagnostic already sent to stderr.
ad-parse-listen-port: function [spec [string!] /local colon port-text port-num] [
    colon: find/last spec ":"
    unless colon [
        diagnose "ADAPTER_LISTEN must be host:port"
        return none
    ]
    port-text: copy next colon
    port-num: parse-nonneg-int port-text
    unless port-num [
        diagnose "ADAPTER_LISTEN port is invalid"
        return none
    ]
    port-num
]

;; Opens stdin/stdout (mode 'stdio), or -- when ADAPTER_LISTEN names a
;; "host:port" -- a TCP server that accepts exactly one controller
;; connection and uses it for both directions (mode 'tcp), matching the
;; shared harness's TCP transport. Returns true/false; on failure a
;; diagnostic already went to stderr.
;;
;; Declared with FUNC (not FUNCTION), and its nested `awake` closure below
;; is too: this is the one place in this file where that closure must
;; mutate a plain local (`accepted`) belonging to ITS enclosing function --
;; exactly the FUNCTION-vs-FUNC trap client/convex.r3's own header
;; documents for open-plain-tcp/sock-read-once. FUNCTION would silently
;; auto-local `accepted` inside the awake closure itself the moment it
;; saw the bare set-word `accepted:`, leaving this function's own
;; `accepted` permanently none even after a real accept.
ad-open-transport: func [
    /local listen-spec port-num accepted listener
][
    listen-spec: get-env "ADAPTER_LISTEN"
    if any [none? listen-spec empty? listen-spec] [
        ad/mode: 'stdio
        ad/stdin-port: system/ports/input
        return true
    ]

    port-num: ad-parse-listen-port listen-spec
    unless port-num [return false]

    ad/mode: 'tcp
    accepted: none
    listener: make port! to-url rejoin ["tcp://:" port-num]
    listener/awake: func [event] [
        switch event/type [
            accept [accepted: first event/port return true]
        ]
        false
    ]
    unless attempt [open listener] [
        diagnose rejoin ["listen failed on " listen-spec]
        return false
    ]
    unless port? wait reduce [listener 120] [
        diagnose "no controller connected within 120s"
        close listener
        return false
    ]
    unless accepted [
        diagnose "accept failed"
        close listener
        return false
    ]
    ad/listen: listener
    ad/peer: accepted
    true
]

;; ===========================================================================
;; Reading one NDJSON command line. Bounded by timeout-ms in TCP mode
;; (client/convex.r3's own sock-read-once, the same primitive its HTTP and
;; WebSocket layers use, gives this a real, tested timeout). In stdio mode
;; a plain synchronous `read` is used instead -- see this file's header
;; comment on why `wait` cannot bound it here -- so timeout-ms is only
;; honored there when a complete line is already buffered from a previous
;; read; otherwise this call blocks until the controller sends more or
;; closes stdin.
;;
;; Returns a two-element block [outcome line-or-none]:
;;   'ok        line is the next complete command (newline, and a
;;              defensive trailing \r, already stripped)
;;   'timeout   no complete line arrived within timeout-ms (TCP mode only)
;;   'eof       the transport closed
;; ===========================================================================

ad-read-command: function [
    timeout-ms [integer!]
    /local deadline nl line remaining outcome chunk
][
    deadline: (now-ms) + timeout-ms
    forever [
        nl: find ad/read-buf #{0A}
        if nl [
            line: copy/part ad/read-buf (index? nl) - 1
            ad/read-buf: copy at nl 2
            if all [(not empty? line) ((last line) = 13)] [
                line: copy/part line (length? line) - 1
            ]
            line: attempt [to string! line]
            if none? line [return reduce ['eof none]]
            return reduce ['ok line]
        ]
        either ad/mode = 'tcp [
            remaining: remaining-ms deadline
            if remaining <= 0 [return reduce ['timeout none]]
            outcome: sock-read-once ad/peer (remaining / 1000.0)
            case [
                outcome/outcome = 'ok [
                    if (length? outcome/bytes) > 0 [append ad/read-buf outcome/bytes]
                ]
                any [outcome/outcome = 'eof outcome/outcome = 'error] [
                    return reduce ['eof none]
                ]
                true [return reduce ['timeout none]]
            ]
        ] [
            chunk: read ad/stdin-port
            either empty? chunk [
                either empty? ad/read-buf [
                    return reduce ['eof none]
                ] [
                    ;; Rebol/Bulk's console port silently drops the very
                    ;; last trailing newline once the writer closes stdin
                    ;; (confirmed directly: two piped lines with no delay
                    ;; between them arrive as ONE `read` with only the
                    ;; line-INTERNAL newline intact -- the final line's
                    ;; own terminator never arrives even though the data
                    ;; itself does, and the very next `read` reports a
                    ;; plain EOF rather than ever flushing it). Whatever
                    ;; is left over here at true EOF is therefore treated
                    ;; as one final, complete line even without its own
                    ;; trailing LF, rather than being silently discarded.
                    line: attempt [to string! ad/read-buf]
                    ad/read-buf: #{}
                    either none? line [return reduce ['eof none]] [return reduce ['ok line]]
                ]
            ] [
                append ad/read-buf chunk
            ]
        ]
    ]
]

ad-write-line: function [text [string!]] [
    either ad/mode = 'tcp [
        unless sock-write-once ad/peer (rejoin [text "^/"]) 2.0 [
            diagnose "write to controller failed"
            ad/done: true
        ]
    ] [
        print text
    ]
]

;; ===========================================================================
;; Bounded output queue. Subscription push events are droppable (oldest
;; dropped first, see ad-drop-oldest); hello/result/error/ack/closed
;; responses are not -- if the budget cannot be freed without dropping one
;; of those, the adapter fails loudly rather than growing without bound.
;; 8 slots and a 4 MiB byte budget, comfortably inside the shared 128 MiB
;; adapter limit even under a stopped reader with near-maximum messages.
;; ===========================================================================

ad-queue-max-count: 8
ad-queue-max-bytes: 4194304

ad-charge: function [text [string!]] [(length? to binary! text) + 64]

ad-over-budget?: function [charge [integer!]] [
    any [
        (ad/queue-bytes + charge) > ad-queue-max-bytes
        (length? ad/queue) >= ad-queue-max-count
    ]
]

;; Drops the oldest droppable entry to make room. Returns true if one was
;; dropped, false if nothing droppable remains.
ad-drop-oldest: function [/local i entry] [
    i: 1
    while [i <= length? ad/queue] [
        entry: pick ad/queue i
        either entry/droppable [
            ad/queue-bytes: ad/queue-bytes - (ad-charge entry/text)
            remove at ad/queue i
            return true
        ] [
            i: i + 1
        ]
    ]
    false
]

ad-emit: function [text [string!] droppable [logic!] /local charge entry] [
    charge: ad-charge text
    while [ad-over-budget? charge] [
        unless ad-drop-oldest [break]
    ]
    either ad-over-budget? charge [
        unless droppable [
            diagnose "output budget exhausted by undroppable responses"
            ad/done: true
        ]
    ] [
        entry: make object! [text: none droppable: none]
        entry/text: text
        entry/droppable: droppable
        append/only ad/queue entry
        ad/queue-bytes: ad/queue-bytes + charge
    ]
]

ad-flush: function [/local entry] [
    foreach entry ad/queue [ad-write-line entry/text]
    ad/queue: copy []
    ad/queue-bytes: 0
]

;; ===========================================================================
;; Event construction. Every event is built as a real map! (nesting a
;; second map! for "error" where needed) and handed to json-encode, which
;; already recurses through nested maps/blocks -- no manual JSON string
;; splicing anywhere here, unlike a language whose encoder is text-only.
;; A key that is never PUT is never iterated by json-encode's `foreach
;; [key val] value` loop, so an absent optional field (id on most events,
;; subscriptionId on non-subscription events) is naturally omitted rather
;; than serialized as null; `put m "value" none`/`put m "data" none` DOES
;; store the key (confirmed directly), so a genuinely null Convex value or
;; a genuinely absent error `data` still encodes as an explicit `null`
;; where the schema allows it.
;; ===========================================================================

ad-ready-event: function [id [string!] /local e] [
    e: make map! []
    put e "protocolVersion" 1
    put e "id" id
    put e "type" "ready"
    put e "language" "rebol"
    put e "implementation" "native-rebol-0.1.0"
    put e "runtime" convex-runtime-version
    json-encode e
]

ad-ack-event: function [id [string!] /local e] [
    e: make map! []
    put e "id" id
    put e "type" "ack"
    json-encode e
]

ad-closed-event: function [id [string!] /local e] [
    e: make map! []
    put e "id" id
    put e "type" "closed"
    json-encode e
]

ad-result-event: function [id [string!] value logs [block!] /local e] [
    e: make map! []
    put e "id" id
    put e "type" "result"
    put e "value" value
    put e "logs" logs
    json-encode e
]

ad-error-object: function [name [string!] message [string!] data /local e] [
    e: make map! []
    put e "name" name
    put e "message" message
    put e "data" data
    e
]

;; id is omitted (never sent as "") when this error was raised before any
;; valid command id could be recovered -- the schema's `id` requires
;; minLength 1, so an empty string would not validate either.
ad-error-event: function [id [string!] name [string!] message [string!] data /local e] [
    e: make map! []
    unless empty? id [put e "id" id]
    put e "type" "error"
    put e "error" (ad-error-object name message data)
    json-encode e
]

ad-subscription-value-event: function [sub-id [string!] value logs [block!] /local e] [
    e: make map! []
    put e "type" "subscription"
    put e "subscriptionId" sub-id
    put e "value" value
    put e "logs" logs
    json-encode e
]

ad-subscription-error-event: function [
    sub-id [string!] name [string!] message [string!] data logs [block!]
    /local e
][
    e: make map! []
    put e "type" "subscription"
    put e "subscriptionId" sub-id
    put e "error" (ad-error-object name message data)
    put e "logs" logs
    json-encode e
]

;; ===========================================================================
;; Dispatch
;; ===========================================================================

ad-call: function [id [string!] op [string!] root [map!] /local path args-value response] [
    path: select root "path"
    args-value: select root "args"
    either all [string? path map? args-value] [
        response: convex-call op path args-value
        either response/ok [
            ad-emit (ad-result-event id response/value response/logs) false
        ] [
            ad-emit (ad-error-event id (convex-error-name) (convex-error-message) (convex-error-data)) false
        ]
    ] [
        ad-emit (ad-error-event id "ProtocolError" "command does not match adapter protocol v1" none) false
    ]
]

ad-subscribe: function [id [string!] root [map!] /local sub-id path args-value] [
    sub-id: select root "subscriptionId"
    path: select root "path"
    args-value: select root "args"
    either all [string? sub-id string? path map? args-value] [
        either convex-subscribe sub-id path args-value [
            ad-emit (ad-ack-event id) false
        ] [
            ad-emit (ad-error-event id (convex-error-name) (convex-error-message) (convex-error-data)) false
        ]
    ] [
        ad-emit (ad-error-event id "ProtocolError" "command does not match adapter protocol v1" none) false
    ]
]

ad-unsubscribe: function [id [string!] root [map!] /local sub-id] [
    sub-id: select root "subscriptionId"
    either string? sub-id [
        convex-unsubscribe sub-id
        ad/published: map-without-key ad/published sub-id
        ad-emit (ad-ack-event id) false
    ] [
        ad-emit (ad-error-event id "ProtocolError" "command does not match adapter protocol v1" none) false
    ]
]

ad-set-auth: function [id [string!] root [map!] /local token] [
    token: select root "token"
    either string? token [
        convex-set-auth token
        ad-emit (ad-ack-event id) false
    ] [
        ad-emit (ad-error-event id "ProtocolError" "command does not match adapter protocol v1" none) false
    ]
]

ad-dispatch: function [line [string!] /local decoded parsed id op] [
    decoded: json-decode line
    either all [decoded/ok map? decoded/value] [
        parsed: decoded/value
        id: select parsed "id"
        unless string? id [id: ""]
        op: select parsed "op"
        case [
            op = "hello" [ad-emit (ad-ready-event id) false]
            any [op = "query" op = "mutation" op = "action"] [ad-call id op parsed]
            op = "subscribe" [ad-subscribe id parsed]
            op = "unsubscribe" [ad-unsubscribe id parsed]
            op = "setAuth" [ad-set-auth id parsed]
            op = "debugDisconnect" [
                convex-debug-disconnect
                ad-emit (ad-ack-event id) false
            ]
            op = "close" [
                convex-close-live 2000
                ad-emit (ad-closed-event id) false
                ad/done: true
            ]
            true [ad-emit (ad-error-event id "ProtocolError" "command does not match adapter protocol v1" none) false]
        ]
    ] [
        ad-emit (ad-error-event "" "ProtocolError" "the controller sent invalid JSON" none) false
    ]
]

;; Publishes, as droppable subscription events, every active subscription
;; whose client/convex.r3 delivery version has advanced past what this
;; adapter already queued for it. subscriptionId is used directly as
;; convex.r3's own subscription "tag" (see ad-subscribe), so cx/tag-to-qid
;; is keyed by subscriptionId already -- no separate mapping is needed
;; here. Run once per main-loop pass, right after live-pump.
ad-publish-subscriptions: function [/local sub-id qid sub already] [
    foreach [sub-id qid] cx/tag-to-qid [
        sub: select cx/subs qid
        if sub [
            already: any [(select ad/published sub-id) 0]
            if sub/version > already [
                put ad/published sub-id sub/version
                either sub/err-name [
                    ad-emit (ad-subscription-error-event sub-id sub/err-name sub/err-message sub/err-data sub/logs) true
                ] [
                    ad-emit (ad-subscription-value-event sub-id sub/value sub/logs) true
                ]
            ]
        ]
    ]
]

;; ===========================================================================
;; Lifecycle
;; ===========================================================================

;; How long each main-loop pass spends pumping Live, and (TCP mode only)
;; waiting for the next controller line, before looping back around. Short
;; enough to keep Live push latency low without busy-spinning.
ad-loop-slice-ms: 5000

;; The whole connect-transport-loop-cleanup driver, wrapped in one function
;; rather than left as bare top-level statements, specifically so a unit
;; test can `do` this file (loading every ad-* function and the `ad`
;; state object above) without also dialing a real deployment or blocking
;; on a transport -- see client/tests/conformance/queue-test.r3, which
;; tests ad-emit's bounded output queue directly this way. Called
;; unconditionally at the bottom UNLESS ADAPTER_NO_AUTORUN is set, which
;; only that test file ever sets.
ad-main: function [/local outcome cmd-line deployment-url] [
    deployment-url: get-env "CONVEX_URL"
    if any [none? deployment-url empty? deployment-url] [
        diagnose "CONVEX_URL is required"
        quit/return 2
    ]

    unless convex-open deployment-url "rebol-0.1.0" [
        diagnose convex-error-message
        quit/return 1
    ]

    ad/published: make map! []

    unless ad-open-transport [quit/return 1]

    until [
        live-pump ad-loop-slice-ms
        ad-publish-subscriptions
        ad-flush
        set [outcome cmd-line] ad-read-command ad-loop-slice-ms
        case [
            outcome = 'ok [ad-dispatch cmd-line]
            outcome = 'eof [ad/done: true]
            true [none]
        ]
        ad-flush
        ad/done
    ]

    convex-close-live 2000
    if ad/mode = 'tcp [
        if ad/peer [sock-close ad/peer]
        if ad/listen [try [close ad/listen]]
    ]
]

unless get-env "ADAPTER_NO_AUTORUN" [ad-main]
