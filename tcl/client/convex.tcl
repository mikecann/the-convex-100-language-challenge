# Native Tcl Convex client. Tcllib supplies ordinary TLS, HTTP, JSON, and RFC
# 6455 transport only. Convex's envelopes, response classification, query-set
# versions, reconnect lifecycle, and publication decisions live here.
package require Tcl 8.6
package require http
package require tls
package require json
package require json::write
package require sha1
package require base64

namespace eval ::convex {
    variable nextClient 0
    variable clients
    ::array set clients {}
    variable initialTimestamp AAAAAAAAAAA=
    variable maximumResponseBytes [expr {2 * 1024 * 1024}]
    # The HTTP reader compares its budget against the declared and the received
    # size between blocks, so an oversized response is abandoned while it is
    # still arriving instead of after Tcl has allocated all of it.
    variable responseBlockBytes [expr {64 * 1024}]
    variable maximumFrameBytes [expr {2 * 1024 * 1024}]
    variable maximumHandshakeBytes [expr {32 * 1024}]
    # Incomplete transport work cannot hold the only Live connection forever.
    # Each deadline below is absolute: it starts when the incomplete work starts
    # and a trickle of progress never extends it. Tests shorten these production
    # values explicitly.
    variable partialFrameTimeoutMs 5000
    variable connectDeadlineMs 10000
    variable writeDeadlineMs 10000
    # One TLS policy serves HTTPS and WSS. The CA bundle is the runtime image's,
    # and the identity the peer certificate has to prove is recorded per channel
    # because a trusted certificate issued for another host is still an attack.
    variable tlsCaFile /etc/ssl/certs/ca-certificates.crt
    variable tlsExpectedHost
    ::array set tlsExpectedHost {}
    variable tlsPendingHost ""
    # OpenSSL reports every refusal as the same opaque handshake failure, so the
    # real reason is kept here for stderr diagnostics and for the TLS tests.
    variable tlsLastRejection ""
}

proc ::convex::ip_literal {host} {
    if {[string first : $host] >= 0} { return 1 }
    return [regexp {^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$} $host]
}

# Certificate identities are (kind name) pairs. TclTLS builds differ in how they
# spell subject alternative names, so read every documented spelling. Unlabelled
# tokens are only trusted from a dedicated alternative-name field; the printed
# extension block may contain unrelated text, so only DNS and IP entries are
# taken from it.
proc ::convex::identity_entries {value {labelledOnly 0}} {
    set entries {}
    foreach token [split [string map [list "IP Address:" "IP:" "," " " ";" " "] $value]] {
        set token [string trim $token]
        if {$token eq ""} { continue }
        if {[regexp -nocase {^(DNS|IP|email|URI):(.*)$} $token -> label name]} {
            if {[string equal -nocase $label DNS]} {
                lappend entries [list dns $name]
            } elseif {[string equal -nocase $label IP]} {
                lappend entries [list ip $name]
            }
            continue
        }
        if {!$labelledOnly} { lappend entries [list dns $token] }
    }
    return $entries
}

# A subject is printed as either "CN=host, O=Org" or "/CN=host/O=Org" depending
# on the TclTLS build, so normalise both separators before reading it.
proc ::convex::subject_common_names {subject} {
    set names {}
    foreach part [split [string map {/ ,} $subject] ,] {
        if {[regexp -nocase {^[ \t]*CN[ \t]*=[ \t]*(.+)$} $part -> value]} { lappend names [string trim $value] }
    }
    return $names
}

proc ::convex::certificate_identities {certificate} {
    set identities {}
    foreach key {alternate_names alternateNames subjectAltName subject_alt_name san} {
        if {![dict exists $certificate $key]} { continue }
        foreach entry [identity_entries [dict get $certificate $key]] { lappend identities $entry }
    }
    if {![llength $identities] && [dict exists $certificate extensions]} {
        foreach entry [identity_entries [dict get $certificate extensions] 1] { lappend identities $entry }
    }
    # The common name is the last resort. A certificate that names nothing this
    # client can check produces an empty list, which fails verification.
    if {[dict exists $certificate subject]} {
        foreach name [subject_common_names [dict get $certificate subject]] { lappend identities [list dns $name] }
    }
    return $identities
}

proc ::convex::identity_matches {identity host} {
    lassign $identity kind name
    set name [string tolower [string trim $name]]
    set host [string tolower $host]
    if {$name eq "" || $host eq ""} { return 0 }
    if {$name eq $host} { return 1 }
    # Only a leftmost single-label wildcard matches, and never for an address
    # literal or for a name whose remainder is a single label.
    if {$kind eq "ip" || [ip_literal $host]} { return 0 }
    if {[string range $name 0 1] ne "*."} { return 0 }
    set suffix [string range $name 2 end]
    if {[string first . $suffix] < 0} { return 0 }
    set dot [string first . $host]
    if {$dot < 1} { return 0 }
    return [expr {[string range $host [expr {$dot + 1}] end] eq $suffix}]
}

proc ::convex::verify_hostname {identities host} {
    foreach identity $identities {
        if {[identity_matches $identity $host]} { return 1 }
    }
    return 0
}

proc ::convex::tls_reject {reason} {
    variable tlsLastRejection
    set tlsLastRejection $reason
    puts stderr "Convex TLS refused a connection: $reason"
    return 0
}

# TclTLS reports each certificate in the chain to this callback while the
# handshake is still in progress. Returning 0 aborts it, so this is where an
# untrusted chain and a certificate issued for another host are both refused.
proc ::convex::tls_callback {event channel args} {
    variable tlsExpectedHost
    variable tlsPendingHost
    if {$event ne "verify"} { return 1 }
    lassign $args depth certificate status problem
    if {![string is integer -strict $depth] || [catch {dict size $certificate}]} {
        return [tls_reject "TclTLS verify arguments were not (depth certificate status error)"]
    }
    if {![string is boolean -strict $status] || ![string is true $status]} {
        return [tls_reject "certificate chain rejected at depth $depth: $problem"]
    }
    if {$depth != 0} { return 1 }
    if {[info exists tlsExpectedHost($channel)]} {
        set host $tlsExpectedHost($channel)
    } elseif {$tlsPendingHost ne ""} {
        set host $tlsPendingHost
    } else {
        return [tls_reject "no expected TLS host was recorded for $channel"]
    }
    set identities [certificate_identities $certificate]
    if {![verify_hostname $identities $host]} {
        return [tls_reject "certificate identities {$identities} do not match $host"]
    }
    return 1
}

# Channels are recorded by name, so a name reused after a closed request would
# otherwise inherit a stale expectation. Drop the closed ones on every connect.
# This namespace defines commands called array and close, so every use of the
# built-in command of that name is qualified.
proc ::convex::forget_closed_tls_channels {} {
    variable tlsExpectedHost
    set live [chan names]
    foreach channel [::array names tlsExpectedHost] {
        if {[lsearch -exact $live $channel] < 0} { unset tlsExpectedHost($channel) }
    }
}

# Verify the chain against the image's CA bundle, refuse the obsolete protocol
# versions, send SNI for a named host, and record the identity that the peer
# certificate has to prove. The pending name covers the window in which TclTLS
# could complete a handshake before it has returned the channel name.
proc ::convex::tls_connect {host port args} {
    variable tlsCaFile
    variable tlsExpectedHost
    variable tlsPendingHost
    forget_closed_tls_channels
    set options [list -require 1 -cafile $tlsCaFile -command [list ::convex::tls_callback] \
        -ssl2 0 -ssl3 0 -tls1 0 -tls1.1 0]
    if {![ip_literal $host]} { lappend options -servername $host }
    set tlsPendingHost $host
    try {
        set channel [::tls::socket {*}$args {*}$options $host $port]
    } finally {
        set tlsPendingHost ""
    }
    set tlsExpectedHost($channel) $host
    return $channel
}

# Tcl's http package invokes this command with its own leading options followed
# by host and port. Routing it through the same policy makes HTTPS and WSS share
# one verified transport without a shell command or a delegated client runtime.
proc ::convex::tls_socket {args} {
    return [tls_connect [lindex $args end-1] [lindex $args end] {*}[lrange $args 0 end-2]]
}

::http::register https 443 [list ::convex::tls_socket]

proc ::convex::quote {value} {
    return [::json::write string $value]
}

proc ::convex::object {pairs} {
    set result "\{"
    set first 1
    foreach {key raw} $pairs {
        if {!$first} { append result , }
        set first 0
        append result [quote $key] : $raw
    }
    append result "\}"
    return $result
}

proc ::convex::array {values} {
    return "\[[join $values ,]\]"
}

proc ::convex::valid_url {url} {
    return [regexp {^https?://[^/?#]+(?:/[^?#]*)?$} $url]
}

# The Tcllib decoder is used for metadata. These boundary helpers retain the
# exact JSON subtree for a Convex value, so arrays, booleans, null, and nested
# objects are never guessed from Tcl's deliberately untyped list values.
proc ::convex::skip_space {text index} {
    set length [string length $text]
    while {$index < $length && [string first [string index $text $index] " \t\r\n"] >= 0} {
        incr index
    }
    return $index
}

proc ::convex::string_end {text index} {
    # INDEX points at the opening quote. JSON's backslash escapes consume the
    # following code unit, including a unicode escape's four hex digits.
    incr index
    set length [string length $text]
    while {$index < $length} {
        set character [string index $text $index]
        if {$character eq "\\"} {
            incr index
            if {$index >= $length} { error "unterminated JSON escape" }
            if {[string index $text $index] eq "u"} { incr index 4 }
        } elseif {$character eq "\""} {
            return [expr {$index + 1}]
        }
        incr index
    }
    error "unterminated JSON string"
}

proc ::convex::value_end {text index} {
    set index [skip_space $text $index]
    set length [string length $text]
    if {$index >= $length} { error "expected JSON value" }
    set character [string index $text $index]
    if {$character eq "\""} { return [string_end $text $index] }
    if {$character ni [list "\{" "\["]} {
        set end $index
        while {$end < $length && [string first [string index $text $end] ",\]\} \t\r\n"] < 0} { incr end }
        return $end
    }
    set open $character
    set close [expr {$open eq "\{" ? "\}" : "\]"}]
    set depth 0
    set cursor $index
    while {$cursor < $length} {
        set current [string index $text $cursor]
        if {$current eq "\""} {
            set cursor [string_end $text $cursor]
            continue
        }
        if {$current eq $open} { incr depth }
        if {$current eq $close} {
            incr depth -1
            if {$depth == 0} { return [expr {$cursor + 1}] }
        }
        incr cursor
    }
    error "unterminated JSON container"
}

proc ::convex::field {object name {required 1}} {
    set index [skip_space $object 0]
    if {[string index $object $index] ne "\{"} { error "expected JSON object" }
    incr index
    set length [string length $object]
    while {1} {
        set index [skip_space $object $index]
        if {$index >= $length} { break }
        if {[string index $object $index] eq "\}"} { break }
        if {[string index $object $index] ne "\""} { error "malformed JSON object key" }
        set keyEnd [string_end $object $index]
        set key [::json::json2dict [string range $object $index [expr {$keyEnd - 1}]]]
        set index [skip_space $object $keyEnd]
        if {[string index $object $index] ne ":"} { error "malformed JSON object separator" }
        set start [skip_space $object [expr {$index + 1}]]
        set end [value_end $object $start]
        if {$key eq $name} { return [string range $object $start [expr {$end - 1}]] }
        set index [skip_space $object $end]
        if {$index < $length && [string index $object $index] eq ","} { incr index }
    }
    if {$required} { error "JSON object omitted required field $name" }
    return ""
}

proc ::convex::elements {jsonArray} {
    set index [skip_space $jsonArray 0]
    if {[string index $jsonArray $index] ne "\["} { error "expected JSON array" }
    incr index
    set result {}
    set length [string length $jsonArray]
    while {1} {
        set index [skip_space $jsonArray $index]
        if {$index >= $length || [string index $jsonArray $index] eq "\]"} { return $result }
        set end [value_end $jsonArray $index]
        lappend result [string range $jsonArray $index [expr {$end - 1}]]
        set index [skip_space $jsonArray $end]
        if {$index < $length && [string index $jsonArray $index] eq ","} { incr index; continue }
        if {$index < $length && [string index $jsonArray $index] eq "\]"} { return $result }
        error "malformed JSON array separator"
    }
}

proc ::convex::decode {raw} { return [::json::json2dict $raw] }

# Tcl values do not retain whether JSON supplied a number, string, boolean, or
# null. Validate protocol counters against their exact wire token before using
# the decoded value, and return a canonical decimal integer for state storage.
proc ::convex::json_uint32 {raw fieldName} {
    set token [string trim $raw " \t\r\n"]
    if {![regexp {^(0|[1-9][0-9]*)$} $token] || [expr {$token > 4294967295}]} {
        error "$fieldName must be a JSON uint32 integer"
    }
    return [expr {$token + 0}]
}

proc ::convex::json_string {raw fieldName} {
    set token [string trim $raw " \t\r\n"]
    if {$token eq "" || [string index $token 0] ne "\""} {
        error "$fieldName must be a JSON string"
    }
    if {[catch {set value [decode $token]}]} {
        error "$fieldName must be a JSON string"
    }
    return $value
}

proc ::convex::throw {name message {data null} {logs "\[\]"}} {
    return -code error -errorcode [list CONVEX $name $data $logs] "$name: $message"
}

proc ::convex::new {url {clientVersion tcl-0.1.0} {authToken ""}} {
    variable nextClient
    variable clients
    if {![valid_url $url]} { error "Convex deployment URL must be an absolute HTTP(S) URL" }
    set id [incr nextClient]
    set url [string trimright $url /]
    set clients($id) [dict create url $url version $clientVersion auth $authToken closed 0 socket "" \
        subscriptions {} nextQueryId 0 querySet 0 remote [object [list querySet 0 identity 0 ts [quote $::convex::initialTimestamp]]] \
        connectionCount 0 lastCloseReason InitialConnect reconnectTimer "" connecting 0 reconnectDelay 100 \
        maxTimestamp "" wsStage closed wsBuffer "" wsFragments "" wsFragmentOpcode -1 wsFrameTimer "" \
        wsConnectTimer "" wsWriteTimer "" wsKey "" wsOut ""]
    return $id
}

proc ::convex::state {id} { variable clients; return $clients($id) }
proc ::convex::put {id key value} { variable clients; dict set clients($id) $key $value }

proc ::convex::set_auth {id token} {
    if {[dict get [state $id] closed]} { error "client is closed" }
    put $id auth $token
}

# Convex answers with a JSON envelope for both success and failure, but a proxy,
# a gateway, or a misrouted request can answer with something else entirely.
# These two helpers read an envelope field when there is one and never turn a
# foreign response body into a Tcl error.
proc ::convex::envelope_field {raw name} {
    if {![regexp {^[ \t\r\n]*\{} $raw]} { return "" }
    if {[catch {set value [field $raw $name 0]}]} { return "" }
    return $value
}

proc ::convex::envelope_message {raw fallback} {
    foreach name {errorMessage message} {
        set candidate [envelope_field $raw $name]
        if {$candidate eq "" || [string index $candidate 0] ne "\""} { continue }
        if {[catch {set text [decode $candidate]}] || $text eq ""} { continue }
        return $text
    }
    return $fallback
}

# Tcl's http package reports progress after each block it reads. Abandoning the
# transaction here bounds the response to one block past the budget instead of
# letting Tcl allocate a body this client has already decided to reject. The
# declared length is checked too, so a body that only claims to be enormous is
# refused after the first block rather than after the whole download. A chunked
# response is bounded by its current chunk, because the http package reads a
# complete chunk before it reports progress.
proc ::convex::http_progress {token total current} {
    variable maximumResponseBytes
    if {$total > $maximumResponseBytes || $current > $maximumResponseBytes} {
        ::http::reset $token convex-response-too-large
    }
}

proc ::convex::http_call {id operation path argsRaw} {
    variable maximumResponseBytes
    variable responseBlockBytes
    set client [state $id]
    if {[dict get $client closed]} { error "client is closed" }
    if {![regexp {^[^:]+:[^:]+$} $path]} { throw ProtocolError "Convex function path is required" }
    # Parse once to reject malformed or non-object arguments before passing the
    # exact original JSON through to Convex.
    if {![regexp {^[ \t\r\n]*\{} $argsRaw]} { throw ProtocolError "Convex arguments must be a JSON object" }
    if {[catch {set parsedArgs [decode $argsRaw]} problem]} { throw ProtocolError "invalid Convex arguments: $problem" }
    if {[llength $parsedArgs] % 2} { throw ProtocolError "Convex arguments must be a JSON object" }
    # http::Write sends -query on a binary socket but computes its
    # Content-Length with Tcl's string length. Convert the JSON envelope
    # to UTF-8 bytes first, so character count and transmitted byte count
    # remain identical for non-ASCII arguments.
    set body [encoding convertto utf-8 [object [list path [quote $path] args $argsRaw format [quote json]]]]
    set headers [list Content-Type application/json Accept application/json Convex-Client [dict get $client version]]
    if {[dict get $client auth] ne ""} { lappend headers Authorization "Bearer [dict get $client auth]" }
    if {[catch {set token [::http::geturl "[dict get $client url]/api/$operation" -method POST -headers $headers -query $body -timeout 10000 -binary 1 -blocksize $responseBlockBytes -progress ::convex::http_progress]} problem]} {
        throw TransportError $problem
    }
    try {
        set transaction [::http::status $token]
        if {$transaction eq "convex-response-too-large"} {
            throw TransportError "Convex response exceeded the $maximumResponseBytes byte budget"
        }
        # Tcl's http package reports "eof" instead of "ok" for a Connection:
        # close response whose entire body it did receive: a peer that closes
        # the socket in the same read that delivers the final bytes leaves the
        # package unable to tell that from a genuine mid-response disconnect,
        # and this happens in practice for ordinary multi-byte UTF-8 bodies.
        # Do not turn that into a transport failure here. The classifier below
        # requires a well-formed status field and, on success, a value; a
        # response that really was cut short fails there as ProtocolError
        # instead, so nothing incomplete is ever accepted as a result.
        if {$transaction ne "ok" && $transaction ne "eof"} {
            set detail $transaction
            catch {set detail "$transaction: [::http::error $token]"}
            throw TransportError "Convex HTTP transaction did not complete ($detail)"
        }
        set code [::http::ncode $token]
        set wireRaw [::http::data $token]
        if {[string bytelength $wireRaw] > $maximumResponseBytes} { throw TransportError "response exceeds byte limit" }
        if {[catch {set raw [encoding convertfrom utf-8 $wireRaw]} problem]} {
            throw ProtocolError "invalid UTF-8 HTTP response: $problem"
        }
        # Keep the envelope classifier on raw JSON subtrees. Decoding the
        # complete response into Tcl's deliberately untyped dict representation
        # lets nested values and log strings participate in list parsing before
        # the required status field is checked. The field scanner validates the
        # envelope shape while leaving value, errorData, and logLines exact.
        set statusRaw [envelope_field $raw status]
        set logs [envelope_field $raw logLines]
        if {$logs eq ""} { set logs "\[\]" }
        set data [envelope_field $raw errorData]
        if {$data eq ""} { set data null }
        set status ""
        if {$statusRaw ne "" && [catch {set status [json_string $statusRaw "HTTP response status"]}]} {
            throw ProtocolError "HTTP $code response had a non-string status"
        }
        if {$status eq "success"} {
            if {$code != 200} { throw ProtocolError "HTTP $code response claimed success" }
            set value [envelope_field $raw value]
            if {$value eq ""} { throw ProtocolError "HTTP success response omitted value" }
            return [dict create value $value logs $logs]
        }
        # Convex reports a failed function either inside a 200 envelope or with
        # status 560. Both are the deployment answering correctly about a
        # function that failed, so both stay FunctionError rather than becoming
        # a transport or protocol problem the caller cannot act on.
        if {$status eq "error" || $code == 560} {
            throw FunctionError [envelope_message $raw "Convex function failed"] $data $logs
        }
        if {$code == 200} {
            if {$statusRaw eq ""} { throw ProtocolError "HTTP response omitted status" }
            throw ProtocolError "HTTP response had unknown status"
        }
        set detail [envelope_message $raw "no Convex error envelope"]
        # 5xx, 408, and 429 mean the deployment or something in front of it did
        # not answer this attempt, so a caller may retry them. Every other
        # non-200 is a request the deployment refused and would refuse again.
        if {$code >= 500 || $code == 408 || $code == 429} {
            throw TransportError "HTTP $code from Convex: $detail"
        }
        throw ProtocolError "HTTP $code from Convex: $detail"
    } finally {
        ::http::cleanup $token
    }
}

proc ::convex::query {id path argsRaw} { return [http_call $id query $path $argsRaw] }
proc ::convex::mutation {id path argsRaw} { return [http_call $id mutation $path $argsRaw] }
proc ::convex::action {id path argsRaw} { return [http_call $id action $path $argsRaw] }

proc ::convex::sync_url {url} {
    regsub {^https:} $url wss: url
    regsub {^http:} $url ws: url
    return "$url/api/sync"
}

# The repository requires a bounded close even if a peer stops halfway through
# a WebSocket frame. Tcllib's otherwise useful websocket package performs exact
# blocking reads, so this small stateful RFC 6455 reader deliberately owns the
# channel in nonblocking mode. Every consumed byte remains in wsBuffer until a
# complete frame is available, never restarting from a false boundary.
proc ::convex::random_bytes {count} {
    # RFC 6455 masking keys and the handshake nonce should not be predictable.
    # Prefer the kernel's generator and keep Tcl's own as a fallback for a
    # sandbox that does not expose it.
    if {![catch {set stream [open /dev/urandom rb]}]} {
        try {
            set bytes [read $stream $count]
            if {[string bytelength $bytes] == $count} { return $bytes }
        } finally {
            ::close $stream
        }
    }
    set output ""
    for {set index 0} {$index < $count} {incr index} {
        append output [binary format c [expr {int(rand() * 256) - 128}]]
    }
    return $output
}

proc ::convex::ws_parts {url} {
    if {![regexp {^(ws|wss)://([^/:]+)(?::([0-9]+))?(/.*)?$} $url -> scheme host port path]} {
        error "invalid WebSocket URL"
    }
    if {$port eq ""} { set port [expr {$scheme eq "wss" ? 443 : 80}] }
    if {$path eq ""} { set path / }
    return [list $scheme $host $port $path]
}

proc ::convex::ws_enqueue {id bytes} {
    set pending [dict get [state $id] wsOut]
    put $id wsOut "$pending$bytes"
    ws_flush $id
}

proc ::convex::ws_flush {id} {
    set client [state $id]
    set socket [dict get $client socket]
    if {$socket eq ""} { return }
    if {[dict get $client wsOut] ne ""} {
        set bytes [dict get $client wsOut]
        if {[catch {puts -nonewline $socket $bytes} error]} {
            retire $id "TransportError: $error"
            return
        }
        # Once puts succeeds Tcl owns the complete record, including any bytes
        # held in its nonblocking channel buffer. Clear the source buffer now so
        # a writable retry cannot duplicate an already accepted WebSocket frame.
        put $id wsOut ""
        if {[catch {flush $socket} error]} {
            retire $id "TransportError: $error"
            return
        }
    }
    ws_sync_write_watch $id $socket
}

# A peer that stops reading leaves accepted bytes in Tcl's channel queue. Watch
# that queue with one absolute deadline, and keep the writable event registered
# only while it can do something. A permanently registered writable handler
# fires continuously on a healthy socket and starves the reader.
proc ::convex::ws_sync_write_watch {id socket} {
    variable writeDeadlineMs
    set client [state $id]
    if {[dict get $client socket] ne $socket} { return }
    if {[catch {set pending [chan pending output $socket]}]} { set pending 0 }
    set timer [dict get $client wsWriteTimer]
    if {$pending > 0} {
        if {$timer eq ""} {
            put $id wsWriteTimer [after $writeDeadlineMs [list ::convex::ws_write_timeout $id $socket]]
        }
    } elseif {$timer ne ""} {
        after cancel $timer
        put $id wsWriteTimer ""
    }
    # Only an async connect needs the writable event, and it is how that connect
    # reports it finished. Leaving it registered afterwards makes it fire
    # continuously on a healthy socket and starve the reader, so the deadline
    # above is what covers a peer that stops draining instead.
    if {[dict get $client wsStage] ne "connecting"} { catch {fileevent $socket writable {}} }
}

proc ::convex::ws_write_timeout {id socket} {
    set client [state $id]
    if {[dict get $client socket] ne $socket || [dict get $client wsWriteTimer] eq ""} { return }
    put $id wsWriteTimer ""
    # Tcl drains its own channel queue in the background. A peer that finished
    # draining before the deadline keeps its connection.
    if {[catch {set pending [chan pending output $socket]}]} { set pending 0 }
    if {$pending <= 0 && [dict get $client wsOut] eq ""} { return }
    retire $id "TransportError: WebSocket write deadline exceeded"
}

proc ::convex::ws_connect_timeout {id socket} {
    set client [state $id]
    if {[dict get $client socket] ne $socket || [dict get $client wsConnectTimer] eq ""} { return }
    put $id wsConnectTimer ""
    retire $id "TransportError: WebSocket handshake deadline exceeded"
}

proc ::convex::ws_frame {opcode payload} {
    variable maximumFrameBytes
    set length [string bytelength $payload]
    if {$length > $maximumFrameBytes} { error "WebSocket frame exceeds 2 MiB" }
    set mask [random_bytes 4]
    set header [binary format c [expr {0x80 | $opcode}]]
    if {$length < 126} {
        append header [binary format c [expr {0x80 | $length}]]
    } elseif {$length <= 65535} {
        append header [binary format c 254] [binary format S $length]
    } else {
        # Tcl 8.6's W format is network-order unsigned wide integer.
        append header [binary format c 255] [binary format W $length]
    }
    append header $mask
    binary scan $mask cu4 maskBytes
    binary scan $payload cu* payloadBytes
    set masked {}
    set index 0
    foreach byte $payloadBytes {
        lappend masked [expr {$byte ^ [lindex $maskBytes [expr {$index % 4}]]}]
        incr index
    }
    return "$header[binary format cu* $masked]"
}

proc ::convex::send {id raw} {
    set client [state $id]
    if {[dict get $client socket] eq "" || [dict get $client wsStage] ne "open"} { error "Live WebSocket is not connected" }
    ws_enqueue $id [ws_frame 1 [encoding convertto utf-8 $raw]]
}

proc ::convex::retire {id reason {reconnect 1}} {
    set client [state $id]
    set socket [dict get $client socket]
    # Every deadline belongs to the connection being retired. Cancelling them
    # here keeps a replacement connection from inheriting an expiring timer.
    foreach field {wsFrameTimer wsConnectTimer wsWriteTimer} {
        if {[dict get $client $field] ne ""} {
            after cancel [dict get $client $field]
            put $id $field ""
        }
    }
    if {$reason ne "client-closed" && $reason ne "DebugDisconnect"} { puts stderr "Convex Live retired connection: $reason" }
    # A parser failure and an unexpected peer close are subscription failures,
    # not invisible diagnostics. Keep the subscriptions active so the same
    # callback receives a later valid value after reconnect.
    if {![dict get $client closed] && $reason ne "DebugDisconnect" && $reason ne "client-closed"} {
        set name [expr {[string match {ProtocolError:*} $reason] ? "ProtocolError" : "TransportError"}]
        set message [expr {[string match "${name}:*" $reason] ? [string range $reason [expr {[string length $name] + 2}] end] : $reason}]
        set payload [object [list name [quote $name] message [quote $message] data null]]
        dict for {queryId sub} [dict get $client subscriptions] {
            catch {uplevel #0 [list {*}[dict get $sub callback] error $payload "\[\]"]}
        }
    }
    if {$socket ne ""} {
        catch {fileevent $socket readable {}}
        catch {fileevent $socket writable {}}
        # This namespace defines a command called close, so the built-in one is
        # qualified. An unqualified call would resolve to ::convex::close, be
        # swallowed by the catch, and leave the retired socket open forever.
        catch {::close $socket}
    }
    put $id socket ""
    put $id wsStage closed
    put $id wsBuffer ""
    put $id wsFragments ""
    put $id wsFragmentOpcode -1
    put $id wsOut ""
    put $id connecting 0
    put $id lastCloseReason $reason
    put $id connectionCount [expr {[dict get $client connectionCount] + 1}]
    if {!$reconnect || [dict get $client closed] || [dict size [dict get $client subscriptions]] == 0} { return }
    set delay [dict get $client reconnectDelay]
    put $id reconnectDelay [expr {min($delay * 2, 15000)}]
    put $id reconnectTimer [after $delay [list ::convex::open_live $id]]
}

proc ::convex::schedule_reconnect {id reason} {
    retire $id $reason
}

proc ::convex::open_live {id} {
    variable connectDeadlineMs
    set client [state $id]
    if {[dict get $client closed] || [dict size [dict get $client subscriptions]] == 0 || [dict get $client socket] ne "" || [dict get $client connecting]} { return }
    # This callback consumed the timer that scheduled it. Clearing the handle
    # makes later transport failures schedule exactly one replacement timer.
    put $id reconnectTimer ""
    put $id connecting 1
    if {[catch {lassign [ws_parts [sync_url [dict get $client url]]] scheme host port path} failure]} {
        retire $id $failure
        return
    }
    if {$scheme eq "wss"} {
        # The same verified TLS transport as HTTPS, including the hostname the
        # peer certificate has to prove.
        set command [list ::convex::tls_connect $host $port -async]
    } else {
        set command [list socket -async $host $port]
    }
    if {[catch {set socket [{*}$command]} failure]} { retire $id $failure; return }
    fconfigure $socket -blocking 0 -buffering none -translation binary -encoding binary
    put $id socket $socket
    put $id wsStage connecting
    set client [state $id]
    dict set client wsHost $host
    dict set client wsPath $path
    variable clients
    set clients($id) $client
    fileevent $socket writable [list ::convex::ws_writable $id $socket]
    fileevent $socket readable [list ::convex::ws_readable $id $socket]
    # TCP, TLS, and the upgrade share one absolute deadline. A peer that accepts
    # the connection and then trickles or withholds its response cannot hold the
    # only Live connection open indefinitely.
    put $id wsConnectTimer [after $connectDeadlineMs [list ::convex::ws_connect_timeout $id $socket]]
}

proc ::convex::ws_writable {id socket} {
    if {[dict get [state $id] socket] ne $socket} { return }
    if {[catch {set connectionError [fconfigure $socket -error]} error]} { retire $id $error; return }
    if {$connectionError ne ""} { retire $id $connectionError; return }
    if {[dict get [state $id] wsStage] eq "connecting"} {
        set client [state $id]
        set key [::base64::encode [random_bytes 16]]
        put $id wsKey $key
        put $id wsStage handshake
        set request "GET [dict get $client wsPath] HTTP/1.1\r\nHost: [dict get $client wsHost]\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nConvex-Client: [dict get $client version]\r\n\r\n"
        ws_enqueue $id $request
        return
    }
    ws_flush $id
}

proc ::convex::ws_readable {id socket} {
    if {[dict get [state $id] socket] ne $socket} { return }
    if {[catch {set bytes [read $socket]} error]} { retire $id "TransportError: $error"; return }
    if {$bytes ne ""} { put $id wsBuffer "[dict get [state $id] wsBuffer]$bytes" }
    if {[eof $socket]} { retire $id "TransportError: peer closed"; return }
    if {[catch {
        if {[dict get [state $id] wsStage] eq "handshake"} { ws_handshake $id }
        if {[dict get [state $id] wsStage] eq "open"} { ws_frames $id }
    } error]} { retire $id "ProtocolError: $error" }
}

proc ::convex::ws_partial_timeout {id socket} {
    set client [state $id]
    if {[dict get $client socket] ne $socket || [dict get $client wsFrameTimer] eq ""} { return }
    put $id wsFrameTimer ""
    if {[dict get $client wsBuffer] eq "" && [dict get $client wsFragmentOpcode] < 0} { return }
    retire $id "TransportError: partial WebSocket frame timed out"
}

proc ::convex::ws_sync_partial_timer {id socket} {
    variable partialFrameTimeoutMs
    set client [state $id]
    if {[dict get $client socket] ne $socket} { return }
    set incomplete [expr {[dict get $client wsBuffer] ne "" || [dict get $client wsFragmentOpcode] >= 0}]
    set timer [dict get $client wsFrameTimer]
    if {$incomplete && $timer eq ""} {
        put $id wsFrameTimer [after $partialFrameTimeoutMs [list ::convex::ws_partial_timeout $id $socket]]
    } elseif {!$incomplete && $timer ne ""} {
        after cancel $timer
        put $id wsFrameTimer ""
    }
}

proc ::convex::ws_handshake {id} {
    variable maximumHandshakeBytes
    set buffer [dict get [state $id] wsBuffer]
    set end [string first "\r\n\r\n" $buffer]
    if {$end < 0} {
        if {[string bytelength $buffer] > $maximumHandshakeBytes} { error "WebSocket upgrade headers exceed 32 KiB" }
        return
    }
    set headers [string range $buffer 0 [expr {$end + 3}]]
    put $id wsBuffer [string range $buffer [expr {$end + 4}] end]
    if {![regexp {^HTTP/1\.[01] 101 } $headers]} { error "WebSocket upgrade was not 101" }
    set accept ""
    foreach line [split $headers "\r\n"] {
        if {[regexp -nocase {^Sec-WebSocket-Accept:[ \t]*(.*)$} $line -> value]} { set accept [string trim $value] }
    }
    set expected [::base64::encode [::sha1::sha1 -bin "[dict get [state $id] wsKey]258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]]
    if {$accept eq "" || $accept ne $expected} { error "WebSocket upgrade acceptance failed" }
    # The connection is established, so its connect deadline is discharged. The
    # frame and write deadlines cover everything after this point.
    if {[dict get [state $id] wsConnectTimer] ne ""} {
        after cancel [dict get [state $id] wsConnectTimer]
        put $id wsConnectTimer ""
    }
    put $id wsStage open
    socket_open $id
}

proc ::convex::byte_at {bytes index} { binary scan $bytes @${index}cu value; return $value }

proc ::convex::ws_frames {id} {
    variable maximumFrameBytes
    set socket [dict get [state $id] socket]
    set buffer [dict get [state $id] wsBuffer]
    while {[string bytelength $buffer] >= 2} {
        set first [byte_at $buffer 0]
        set second [byte_at $buffer 1]
        set fin [expr {($first & 0x80) != 0}]
        set opcode [expr {$first & 0x0f}]
        if {($first & 0x70) != 0 || ($second & 0x80) != 0} { error "invalid WebSocket frame flags" }
        set length [expr {$second & 0x7f}]
        set offset 2
        if {$length == 126} {
            if {[string bytelength $buffer] < 4} { break }
            binary scan [string range $buffer 2 3] Su length
            set offset 4
        } elseif {$length == 127} {
            if {[string bytelength $buffer] < 10} { break }
            binary scan [string range $buffer 2 9] Wu length
            set offset 10
        }
        # The declared length is judged from the header alone, before this
        # reader waits for, buffers, or slices a single payload byte.
        if {$length > $maximumFrameBytes} { error "WebSocket frame exceeds 2 MiB" }
        if {$opcode >= 8 && (!$fin || $length > 125)} { error "invalid WebSocket control frame" }
        if {[string bytelength $buffer] < $offset + $length} { break }
        set payload [string range $buffer $offset [expr {$offset + $length - 1}]]
        set buffer [string range $buffer [expr {$offset + $length}] end]
        ws_frame_received $id $fin $opcode $payload
        if {[dict get [state $id] socket] ne $socket} { return }
    }
    put $id wsBuffer $buffer
    ws_sync_partial_timer $id $socket
}

proc ::convex::ws_frame_received {id fin opcode payload} {
    variable maximumFrameBytes
    if {$opcode == 8} { retire $id peer-close; return }
    if {$opcode == 9} { ws_enqueue $id [ws_frame 10 $payload]; return }
    if {$opcode == 10} { return }
    set fragmentOpcode [dict get [state $id] wsFragmentOpcode]
    if {$opcode == 0} {
        if {$fragmentOpcode < 0} { error "unexpected WebSocket continuation" }
        if {[string bytelength [dict get [state $id] wsFragments]] + [string bytelength $payload] > $maximumFrameBytes} {
            error "fragmented WebSocket message exceeds 2 MiB"
        }
        put $id wsFragments "[dict get [state $id] wsFragments]$payload"
        if {!$fin} { return }
        set opcode $fragmentOpcode
        set payload [dict get [state $id] wsFragments]
        put $id wsFragments ""
        put $id wsFragmentOpcode -1
    } elseif {$opcode in {1 2}} {
        if {$fragmentOpcode >= 0} { error "new WebSocket data frame during fragment" }
        if {!$fin} {
            if {[string bytelength $payload] > $maximumFrameBytes} { error "fragmented WebSocket message exceeds 2 MiB" }
            put $id wsFragmentOpcode $opcode
            put $id wsFragments $payload
            return
        }
    } else { error "unsupported WebSocket opcode $opcode" }
    if {$opcode != 1} { error "binary WebSocket data is unsupported" }
    if {[catch {set text [encoding convertfrom utf-8 $payload]} error]} { error "invalid UTF-8 WebSocket text: $error" }
    handle_live_message $id $text
}

proc ::convex::socket_open {id} {
    put $id connecting 0
    put $id reconnectDelay 100
    put $id querySet 0
    put $id remote [object [list querySet 0 identity 0 ts [quote $::convex::initialTimestamp]]]
    set client [state $id]
    # The pinned sync protocol requires exactly 32 hex characters here. Tcl's
    # monotonic microsecond clock supplies the changing portion; zero-padding
    # keeps the wire shape canonical without a delegated UUID helper.
    set fields [list type [quote Connect] sessionId [quote [format %032x [clock microseconds]]] connectionCount [dict get $client connectionCount] lastCloseReason [quote [dict get $client lastCloseReason]] clientTs 0]
    if {[dict get $client maxTimestamp] ne ""} { lappend fields maxObservedTimestamp [quote [dict get $client maxTimestamp]] }
    send $id [object $fields]
    set additions {}
    dict for {queryId sub} [dict get [state $id] subscriptions] { lappend additions [add_modification $queryId $sub] }
    if {[llength $additions]} { modify $id $additions }
}

proc ::convex::subscribe {id path argsRaw callback} {
    set client [state $id]
    if {[dict get $client closed]} { error "client is closed" }
    decode $argsRaw
    set queryId [dict get $client nextQueryId]
    dict set client nextQueryId [expr {$queryId + 1}]
    dict set client subscriptions $queryId [dict create path $path args $argsRaw callback $callback active 1 last ""]
    variable clients
    set clients($id) $client
    open_live $id
    if {[dict get [state $id] wsStage] eq "open"} { modify $id [list [add_modification $queryId [dict get $client subscriptions $queryId]]] }
    return $queryId
}

proc ::convex::add_modification {queryId sub} {
    return [object [list type [quote Add] queryId $queryId udfPath [quote [dict get $sub path]] args [array [list [dict get $sub args]]]]]
}

proc ::convex::modify {id modifications} {
    set client [state $id]
    set current [dict get $client querySet]
    send $id [object [list type [quote ModifyQuerySet] baseVersion $current newVersion [expr {$current + 1}] modifications [array $modifications]]]
    put $id querySet [expr {$current + 1}]
}

proc ::convex::unsubscribe {id queryId} {
    set client [state $id]
    if {![dict exists $client subscriptions $queryId]} { return }
    # Retire the callback before sending Remove. The adapter adds its own
    # generation barrier before it acknowledges the controller.
    dict unset client subscriptions $queryId
    variable clients
    set clients($id) $client
    if {[dict get $client socket] ne ""} { catch {modify $id [list [object [list type [quote Remove] queryId $queryId]]]} }
}

proc ::convex::debug_disconnect {id} {
    set socket [dict get [state $id] socket]
    if {$socket eq ""} { error "Live WebSocket is not connected" }
    retire $id DebugDisconnect
    set client [state $id]
    if {[dict get $client socket] ne "" || [dict get $client reconnectTimer] eq ""} {
        error "debugDisconnect did not retire the old socket and schedule reconnect"
    }
}

proc ::convex::close {id} {
    set client [state $id]
    if {[dict get $client closed]} { return }
    put $id closed 1
    if {[dict get $client reconnectTimer] ne ""} {
        after cancel [dict get $client reconnectTimer]
        put $id reconnectTimer ""
    }
    if {[dict get $client socket] ne ""} { retire $id client-closed 0 }
    put $id subscriptions {}
}

proc ::convex::timestamp_key {encoded} {
    if {[catch {set bytes [binary decode base64 $encoded]}] || [string length $bytes] != 8} { error "invalid canonical timestamp" }
    binary scan $bytes cu* values
    set output ""
    foreach byte [lreverse $values] { append output [format %02x $byte] }
    return $output
}

proc ::convex::normalize_version {raw} {
    # Decode once for whole-object syntax, then validate untyped counters from
    # their raw JSON fields so quoted and boolean lookalikes cannot enter state.
    decode $raw
    set querySet [json_uint32 [field $raw querySet 0] "state version querySet"]
    set identity [json_uint32 [field $raw identity 0] "state version identity"]
    set timestamp [json_string [field $raw ts] "state version ts"]
    timestamp_key $timestamp
    return [object [list querySet $querySet identity $identity ts [quote $timestamp]]]
}

proc ::convex::handle_live_message {id raw} {
    set message [decode $raw]
    set type [dict get $message type]
    if {$type in {Ping MutationResponse ActionResponse}} { return }
    if {$type eq "TransitionChunk"} { error "ProtocolError: TransitionChunk is not implemented" }
    if {$type in {FatalError AuthError}} {
        set detail [::convex::field $raw error 0]
        if {$detail eq ""} { set detail $type }
        error "ProtocolError: $type $detail"
    }
    if {$type ne "Transition"} { error "ProtocolError: unsupported Live message $type" }
    set startRaw [normalize_version [field $raw startVersion]]
    if {$startRaw ne [dict get [state $id] remote]} { error "ProtocolError: transition start version mismatch" }
    set endRaw [normalize_version [field $raw endVersion]]
    set end [decode $endRaw]
    # Apply all validation before publishing. Multiple changes to one query in a
    # transition coalesce to the newest value, so consumers never observe an
    # intermediate transaction state.
    set pending {}
    foreach modificationRaw [elements [field $raw modifications]] {
        set modification [decode $modificationRaw]
        set queryId [json_uint32 [field $modificationRaw queryId 0] "Live queryId"]
        set kind [dict get $modification type]
        if {$kind eq "QueryUpdated"} {
            set item [list value [field $modificationRaw value] [field $modificationRaw logLines 0]]
        } elseif {$kind eq "QueryFailed"} {
            set data [field $modificationRaw errorData 0]
            set logs [field $modificationRaw logLines 0]
            if {$logs eq ""} { set logs "\[\]" }
            set text [json_string [field $modificationRaw errorMessage 0] "QueryFailed.errorMessage"]
            set errorFields [list name [quote FunctionError] message [quote $text]]
            if {$data ne ""} { lappend errorFields data $data }
            set item [list error [object $errorFields] $logs]
        } elseif {$kind ne "QueryRemoved"} { error "ProtocolError: unsupported Live modification $kind" }
        if {![dict exists [state $id] subscriptions $queryId]} { continue }
        if {$kind ne "QueryRemoved"} { dict set pending $queryId $item }
    }
    set previous [dict get [state $id] maxTimestamp]
    set timestamp [dict get $end ts]
    if {$previous eq "" || [string compare [timestamp_key $timestamp] [timestamp_key $previous]] > 0} { put $id maxTimestamp $timestamp }
    put $id remote $endRaw
    dict for {queryId item} $pending {
        if {![dict exists [state $id] subscriptions $queryId]} { continue }
        set sub [dict get [state $id] subscriptions $queryId]
        set signature [join $item \u001f]
        if {$signature eq [dict get $sub last]} { continue }
        dict set sub last $signature
        variable clients
        dict set clients($id) subscriptions $queryId $sub
        uplevel #0 [list {*}[dict get $sub callback] {*}$item]
    }
}
