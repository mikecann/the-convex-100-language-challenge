// convexhdr.h -- shared declarations for the BCPL Convex client.
//
// Every module of the client is a GET-included source file rather than a
// separately linked object, which is the ordinary way to build a large BCPL
// program on this system. That means all cross-module names live in the global
// vector, and this header is the single place they are numbered.
//
// The Cintcode CLI clears globals from `ug` (200) upwards before each command,
// so every global declared here starts at zero and must be initialised by
// convexInit.

MANIFEST {
// ---------------------------------------------------------------------------
// Native transport boundary: function numbers for sys(Sys_ext, fno, ...).
// These must agree with client/native/convexext.c.
//
// The first three are the distribution's own extension probes rather than
// anything this client calls; they are numbered here because this header is
// the one place the two sides of the boundary agree on what a number means.
// ---------------------------------------------------------------------------
Cx_avail    = 0
Cx_init     = 1
Cx_testfn   = 2

Cx_now      = 100
Cx_getenv   = 101
Cx_random   = 102
Cx_connect  = 103
Cx_read     = 104
Cx_write    = 105
Cx_closefn  = 106
Cx_listen   = 107
Cx_accept   = 108
Cx_wait     = 109
Cx_errtext  = 110
Cx_tlsavail = 111   // reported by the boundary; the client relies on the URL
                    // scheme rather than probing, so nothing calls it

// Pre-installed handles. The launcher hands us the process's real stdout on a
// spare descriptor so the Cintcode system's own console output cannot reach
// the protocol stream.
Cx_hcontrol = 0
Cx_hout     = 1
Cx_hdiag    = 2

// Native results. Byte counts are non-negative, so every failure is negative
// and zero always means "the peer closed cleanly".
Cx_eof        =  0
Cx_timeout    = -1
Cx_failed     = -2
Cx_badhandle  = -3

// ---------------------------------------------------------------------------
// Bounds. The Cintcode memory reserved by the launcher is the hard ceiling;
// these are the per-object budgets that keep the client comfortably inside it
// even when a peer is hostile or a consumer has stopped reading.
// ---------------------------------------------------------------------------
Maxbufferbytes    = 4194304   // 4 MiB: the largest any single buffer may grow
Maxframebytes     = 1048576   // 1 MiB: largest accepted WebSocket frame payload
Maxmessagebytes   = 2097152   // 2 MiB: largest reassembled WebSocket message
Maxbodybytes      = 2097152   // 2 MiB: largest accepted HTTP response body
// The request line, headers and body are assembled in one buffer, so the body
// bound has to leave room for the rest of the message inside Maxbufferbytes. A
// body that would not fit is refused outright rather than sent truncated with
// a Content-Length that no longer describes it.
Maxrequestbytes   = 2097152   // 2 MiB: largest HTTP request body this client sends
Maxheaderbytes    = 32768     // largest accepted HTTP or handshake header block
Maxlinebytes      = 1048576   // largest accepted NDJSON adapter command line
Maxjsondepth      = 64        // nesting limit, so a hostile value cannot
                              // exhaust the Cintcode stack
// Node limit for one parsed value, chosen against the 24 MiB arena rather than
// picked for looking generous. A node costs a three word record plus, for a
// string or a number, a buffer handle and its data vector: call it fifty bytes
// once the allocator's own overhead is counted. Fifty thousand nodes is
// therefore about 2.5 MiB, and the client holds a parsed message and a clone of
// part of it at the same time, so the peak is around 6 MiB beside the 1 MiB
// receive buffer and the 2 MiB reassembly buffer. That fits. Two hundred
// thousand would not.
Maxjsonnodes      = 50000

// A subscription that nobody is draining keeps at most this much. Both bounds
// are enforced: a count alone is not a memory bound when one Convex value can
// approach the maximum frame size. A value too large to queue inside the byte
// bound is reported as an error rather than queued past it.
Maxqueueupdates   = 16
Maxqueuebytes     = 262144    // 256 KiB per subscription

// Per-subscription budgets multiply, so they are not on their own a bound on
// the client. These two are what make the arithmetic honest against the arena:
// at most 16 subscriptions, at most 1 MiB of queued updates across all of them
// together, and at most one retained comparison value per subscription, itself
// inside Maxqueuebytes. Worst case is therefore 1 MiB queued plus 4 MiB
// retained, not 16 times 256 KiB of queue with no ceiling at all.
Maxsubscriptions    = 16
Maxlivequeuebytes   = 1048576 // 1 MiB of queued updates across every
                              // subscription together

// ---------------------------------------------------------------------------
// Timing. All deadlines are absolute values on the native monotonic clock.
// ---------------------------------------------------------------------------
// The shared controller fails a command that is unanswered after 10 seconds,
// so every network operation must resolve, one way or another, inside that.
Httptimeoutms     = 8000
Connecttimeoutms  = 6000
Closetimeoutms    = 2000      // close and unsubscribe are bounded even when
                              // the peer is idle, chatty or stalled mid-frame
Backoffbasems     = 100
Backoffmaxms      = 8000
Pollslicems       = 25        // event-loop slice; BCPL has no threads, so the
                              // single owner interleaves work in slices
// A TCP connection that has silently gone away looks exactly like an idle one,
// and the sync protocol has quiet periods by design. The owner therefore proves
// the connection rather than assuming it: after Livekeepalivems of silence it
// sends one WebSocket ping, and after Liveinactivityms with nothing at all
// coming back it retires the connection and reconnects.
Livekeepalivems   = 20000
Liveinactivityms  = 45000

// lvCompareTimestamps reports this when either side is not a base64 encoded
// eight byte value. It is deliberately not an ordering: a caller that read it
// as "less than" would accept a malformed timestamp as merely older.
Tsinvalid = -2

// ---------------------------------------------------------------------------
// JSON value tags.
// ---------------------------------------------------------------------------
Jt_null   = 0
Jt_true   = 1
Jt_false  = 2
Jt_number = 3
Jt_string = 4
Jt_array  = 5
Jt_object = 6

// Byte buffer: a handle whose data vector can be replaced as it grows.
Bb_cap = 0
Bb_len = 1
Bb_vec = 2
Bb_upb = 2

// Pointer list.
Vl_cap = 0
Vl_len = 1
Vl_vec = 2
Vl_upb = 2

// JSON node. Jt_number and Jt_string hold a byte buffer in Js_a; Jt_array
// holds a pointer list of nodes; Jt_object holds a list of key buffers in
// Js_a and a parallel list of value nodes in Js_b.
Js_type = 0
Js_a    = 1
Js_b    = 2
Js_upb  = 2

// Deployment endpoint.
Ep_tls  = 0
Ep_host = 1
Ep_port = 2
Ep_path = 3
Ep_upb  = 3

// HTTP response.
Hr_status = 0
Hr_body   = 1
Hr_upb    = 1

// WebSocket connection. Ws_rx is an append-only receive buffer and Ws_rxpos is
// the parse cursor into it. Because a partly received frame simply leaves both
// untouched, a timeout can never resynchronise on a false frame boundary.
// Ws_closesent records that this end has already sent its close frame. RFC
// 6455 asks each endpoint to send exactly one, so a peer close that arrives
// after the client's own close is consumed rather than echoed.
//
// Ws_lastrx is the monotonic time of the last complete frame from the peer,
// including the control frames the reader answers itself, and Ws_pingsent
// records that a keepalive ping is outstanding. Together they are what lets the
// Live owner tell a quiet connection from a dead one.
Ws_handle    = 0
Ws_rx        = 1
Ws_rxpos     = 2
Ws_msg       = 3
Ws_msgop     = 4
Ws_broken    = 5
Ws_closesent = 6
Ws_lastrx    = 7
Ws_pingsent  = 8
Ws_upb       = 8

// Values of the global wsStatus after wsNextMessage.
Wss_message   = 0
Wss_none      = 1     // nothing complete yet; state preserved, retry later
Wss_eof       = 2
Wss_protocol  = 3
Wss_transport = 4

// WebSocket opcodes.
Op_continue = #x0
Op_text     = #x1
Op_binary   = #x2
Op_close    = #x8
Op_ping     = #x9
Op_pong     = #xA

// Subscription record.
Sb_queryid    = 0
Sb_subid      = 1
Sb_path       = 2
Sb_args       = 3
Sb_generation = 4
Sb_queue      = 5
Sb_queuebytes = 6
Sb_lasttext   = 7
Sb_rehydrate  = 8
Sb_active     = 9
Sb_upb        = 9

// A queued Live update. The generation stamp is what makes unsubscribe and
// same-identifier replacement safe: a relay that was paused after dequeue
// still carries the old generation and is discarded instead of published.
Up_generation = 0
Up_value      = 1
Up_errname    = 2
Up_errmsg     = 3
Up_errdata    = 4
Up_logs       = 5
Up_bytes      = 6
Up_upb        = 6

// A staged delivery. A Transition is applied in three passes -- validate and
// stage every modification, then commit the version, then publish -- so a
// Transition that turns out to be malformed, or that the client cannot hold in
// memory, publishes nothing at all rather than half of itself. Pn_text is the
// serialised value a Live delivery will compare against on the next reconnect,
// and is 0 for a staged error.
Pn_sub    = 0
Pn_update = 1
Pn_text   = 2
Pn_upb    = 2

// Live manager. One record owns the socket, the query-set version and every
// reconnect decision. Lv_queuebytes is the aggregate across every
// subscription's queue, which is the bound that actually holds.
Lv_ep          = 0
Lv_ws          = 1
Lv_queryversion= 2
Lv_remotequery = 3
Lv_remoteident = 4
Lv_remotets    = 5
Lv_maxts       = 6
Lv_conncount   = 7
Lv_lastclose   = 8
Lv_backoff     = 9
Lv_nextattempt = 10
Lv_subs        = 11
Lv_nextqueryid = 12
Lv_version     = 13
Lv_sessionid   = 14
Lv_queuebytes  = 15
Lv_upb         = 15

// Client.
Cl_ep      = 0
Cl_token   = 1
Cl_live    = 2
Cl_closed  = 3
Cl_version = 4
Cl_upb     = 4

// Call result.
Rs_value = 0
Rs_logs  = 1
Rs_upb   = 1

// Structured failure kinds. These are the ones the adapter must be able to
// report without flattening any of them into a successful value. Ek_internal
// exists so that an allocation this client could not satisfy is reported as a
// failure rather than becoming a successful null.
Ek_none      = 0
Ek_function  = 1
Ek_protocol  = 2
Ek_transport = 3
Ek_closed    = 4
Ek_internal  = 5
}

// ---------------------------------------------------------------------------
// Globals. One auto-incrementing block so the numbering cannot collide. The
// Cintcode root global vector has room for globals up to 1000.
// ---------------------------------------------------------------------------
GLOBAL {
// --- native transport boundary ---
cxInit: ug
cxNow
cxGetenv
cxRandomBytes
cxConnect
cxRead
cxWrite
cxCloseHandle
cxListen
cxAccept
cxWait
cxLastError
cxWriteBuffer
cxOut
cxDiag
cxDiagStr
cxDeadline
cxExpired
cxSleepUntil

// --- byte buffers ---
bbNew
bbFree
bbClear
bbEnsure
bbPush
bbPushBytes
bbPushBuffer
bbPushStr
bbPushNum
bbPushHexDigit
bbGet
bbEqual
bbEqualStr
bbCopy
bbSlice
bbFromStr
bbToStr
bbFind
bbMatchStrAt
bbTrimFront
bbReadInto
bbEqualFoldStr

// --- pointer lists ---
vlNew
vlFree
vlClear
vlPush
vlGet
vlRemoveAt
vlShift

// --- digests and encodings ---
shr32
rotl32
sha1Into
base64Into
base64Decode
utf8Valid

// --- JSON ---
jsNew
jsFree
jsFreeList
jsType
jsNull
jsNumberFromInt
jsStringFromBuffer
jsStringFromStr
jsArray
jsObject
jsArrayPush
jsObjectPut
jsObjectPutStr
jsObjectGet
jsArrayGet
jsCount
jsClone
jsWrite
jsSerialise
jsParse
jsParseBuffer
jsWholeNumber
jsStringEqualsStr
jsWriteStringInto
jsParseError
jpSource
jpPos
jpEnd
jpDepth
jpNodes
jpFail
jpSkipSpace
jpValue
jpString
jpNumber
jpLiteral
jpUtf8Push
jpHex4

// --- HTTP ---
epNew
epFree
epParseUrl
httpRequest
httpFree
httpReadHeaders
httpHeaderValue
httpSendRequest

// --- WebSocket ---
wsConnect
wsFree
wsSendText
wsSendFrame
wsSendControl
wsNextMessage
wsCloseGracefully
wsHandshakeOk
wsCloseCodeValid
wsHandle
wsStatus

// --- Live ---
lvNew
lvFree
lvSubscribe
lvUnsubscribe
lvRetireSubscription
lvStep
lvKeepalive
lvDisconnectForAdapter
lvFindSub
lvClose
lvOpen
lvAnnounce
lvRetire
lvDropConnection
lvSendModifications
lvMakeAdd
lvMakeRemove
lvApplyTransition
lvBackoffAfterFailure
lvStageValue
lvStageError
lvCommitPending
lvFreePending
lvFreeStaged
lvDeliverError
lvBroadcastProtocolError
lvCopyLogs
lvFreeLogs
lvAccount
lvReclaim
lvNoteTimestamp
lvDecodeTimestamp
lvTimestampValid
lvCompareTimestamps
lvVersionMatches
lvFindByQueryId
lvResetVersions
pnNew
upFree
upNew
sbFree
sbDeliver
sbTake
sbSetLastText

// --- client ---
convexInit
convexNew
convexFree
convexSetAuth
convexCall
convexCopyLogs
convexClassify
convexResultFree
convexSubscribe
convexUnsubscribe
convexNextUpdate
convexPump
convexDebugDisconnect
convexClose
convexVersion
convexImplementation
convexRuntime
convexToolchainCommit

// --- structured failure reported by the most recent operation ---
errKind
errName
errMessage
errData
errLogs
errClear
errSet
errSetStr
errFromNative
}
