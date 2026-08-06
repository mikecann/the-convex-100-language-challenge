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
    array set clients {}
    variable initialTimestamp AAAAAAAAAAA=
    variable maximumResponseBytes [expr {2 * 1024 * 1024}]
    variable callbackDepth 0

    # Tcl's http package invokes this command with host and port. Keeping SNI
    # and certificate validation here makes HTTPS and WSS use the same CA-backed
    # transport without a shell command or a delegated client runtime.
    proc tls_socket {args} {
        # http::register supplies the socket command's normal host/port tail.
        # Keeping it intact avoids assuming which optional async arguments the
        # HTTP package prepends, while Tcl TLS still performs CA validation.
        return [::tls::socket -autoservername 1 {*}$args]
    }
    ::http::register https 443 [list ::convex::tls_socket]
}

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

proc ::convex::new {url {clientVersion tcl-0.1.0} {authToken ""}} {
    variable nextClient
    variable clients
    if {![valid_url $url]} { error "Convex deployment URL must be an absolute HTTP(S) URL" }
    set id [incr nextClient]
    set url [string trimright $url /]
    set clients($id) [dict create url $url version $clientVersion auth $authToken closed 0 socket "" \
        subscriptions {} nextQueryId 0 querySet 0 remote [object [list querySet 0 identity 0 ts [quote $::convex::initialTimestamp]]] \
        connectionCount 0 lastCloseReason InitialConnect reconnectTimer "" connecting 0 reconnectDelay 100 \
        maxTimestamp "" wsStage closed wsBuffer "" wsFragments "" wsFragmentOpcode -1 wsKey "" wsOut ""]
    return $id
}

proc ::convex::state {id} { variable clients; return $clients($id) }
proc ::convex::put {id key value} { variable clients; dict set clients($id) $key $value }

proc ::convex::set_auth {id token} {
    if {[dict get [state $id] closed]} { error "client is closed" }
    put $id auth $token
}

proc ::convex::http_call {id operation path argsRaw} {
    variable maximumResponseBytes
    set client [state $id]
    if {[dict get $client closed]} { error "client is closed" }
    if {![regexp {^[^:]+:[^:]+$} $path]} { error "Convex function path is required" }
    # Parse once to reject malformed or non-object arguments before passing the
    # exact original JSON through to Convex.
    set parsedArgs [decode $argsRaw]
    if {[llength $parsedArgs] % 2} { error "Convex arguments must be a JSON object" }
    set body [object [list path [quote $path] args $argsRaw format [quote json]]]
    set headers [list Content-Type application/json Accept application/json Convex-Client [dict get $client version]]
    if {[dict get $client auth] ne ""} { lappend headers Authorization "Bearer [dict get $client auth]" }
    if {[catch {::http::geturl "[dict get $client url]/api/$operation" -method POST -headers $headers -query $body -timeout 10000} token]} {
        error "TransportError: $token"
    }
    try {
        set raw [::http::data $token]
        if {[string bytelength $raw] > $maximumResponseBytes} { error "TransportError: response exceeds byte limit" }
        set bodyDict [decode $raw]
        set status [dict get $bodyDict status]
        if {$status eq "success"} {
            set logsRaw [field $raw logLines 0]
            if {$logsRaw eq ""} { set logsRaw "\[\]" }
            return [dict create value [field $raw value] logs $logsRaw]
        }
        if {$status eq "error"} {
            set message [expr {[dict exists $bodyDict errorMessage] ? [dict get $bodyDict errorMessage] : "Convex function failed"}]
            set data [field $raw errorData 0]
            set logs [field $raw logLines 0]
            if {$data eq ""} { set data null }
            if {$logs eq ""} { set logs "\[\]" }
            return -code error -errorcode [list CONVEX FunctionError $data $logs] "FunctionError: $message"
        }
        error "ProtocolError: HTTP response had unknown status"
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
    if {$socket eq "" || [dict get $client wsOut] eq ""} { return }
    if {[catch {puts -nonewline $socket [dict get $client wsOut]; flush $socket} error]} {
        # EAGAIN leaves Tcl's nonblocking channel buffer intact. Other channel
        # failures retire this exact connection and make reconnect runnable.
        if {![string match {*would block*} [string tolower $error]]} { retire $id $error }
        return
    }
    put $id wsOut ""
}

proc ::convex::ws_frame {opcode payload} {
    set length [string bytelength $payload]
    if {$length > [expr {2 * 1024 * 1024}]} { error "WebSocket frame exceeds 2 MiB" }
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
        catch {close $socket}
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
        set command [list ::tls::socket -async -require 1 -cafile /etc/ssl/certs/ca-certificates.crt -servername $host $host $port]
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
}

proc ::convex::ws_writable {id socket} {
    if {[dict get [state $id] socket] ne $socket} { return }
    if {[catch {set connectionError [fconfigure $socket -error]} error]} { retire $id $error; return }
    if {$connectionError ne ""} { retire $id $connectionError; return }
    set stage [dict get [state $id] wsStage]
    if {$stage eq "connecting"} {
        set client [state $id]
        set key [::base64::encode [random_bytes 16]]
        put $id wsKey $key
        put $id wsStage handshake
        set request "GET [dict get $client wsPath] HTTP/1.1\r\nHost: [dict get $client wsHost]\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nConvex-Client: [dict get $client version]\r\n\r\n"
        ws_enqueue $id $request
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

proc ::convex::ws_handshake {id} {
    set buffer [dict get [state $id] wsBuffer]
    set end [string first "\r\n\r\n" $buffer]
    if {$end < 0} {
        if {[string bytelength $buffer] > 32768} { error "WebSocket upgrade headers exceed 32 KiB" }
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
    put $id wsStage open
    socket_open $id
}

proc ::convex::byte_at {bytes index} { binary scan $bytes @${index}cu value; return $value }

proc ::convex::ws_frames {id} {
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
        if {$length > [expr {2 * 1024 * 1024}]} { error "WebSocket frame exceeds 2 MiB" }
        if {$opcode >= 8 && (!$fin || $length > 125)} { error "invalid WebSocket control frame" }
        if {[string bytelength $buffer] < $offset + $length} { break }
        set payload [string range $buffer $offset [expr {$offset + $length - 1}]]
        set buffer [string range $buffer [expr {$offset + $length}] end]
        ws_frame_received $id $fin $opcode $payload
    }
    put $id wsBuffer $buffer
}

proc ::convex::ws_frame_received {id fin opcode payload} {
    if {$opcode == 8} { retire $id peer-close; return }
    if {$opcode == 9} { ws_enqueue $id [ws_frame 10 $payload]; return }
    if {$opcode == 10} { return }
    set fragmentOpcode [dict get [state $id] wsFragmentOpcode]
    if {$opcode == 0} {
        if {$fragmentOpcode < 0} { error "unexpected WebSocket continuation" }
        if {[string bytelength [dict get [state $id] wsFragments]] + [string bytelength $payload] > [expr {2 * 1024 * 1024}]} {
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
            if {[string bytelength $payload] > [expr {2 * 1024 * 1024}]} { error "fragmented WebSocket message exceeds 2 MiB" }
            put $id wsFragmentOpcode $opcode
            put $id wsFragments $payload
            return
        }
    } else { error "unsupported WebSocket opcode" }
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
    put $id nextQueryId [expr {$queryId + 1}]
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
    set version [decode $raw]
    foreach key {querySet identity ts} { if {![dict exists $version $key]} { error "state version omitted $key" } }
    timestamp_key [dict get $version ts]
    return [object [list querySet [dict get $version querySet] identity [dict get $version identity] ts [quote [dict get $version ts]]]]
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
        set queryId [dict get $modification queryId]
        if {![dict exists [state $id] subscriptions $queryId]} { continue }
        set kind [dict get $modification type]
        if {$kind eq "QueryUpdated"} {
            dict set pending $queryId [list value [field $modificationRaw value] [field $modificationRaw logLines 0]]
        } elseif {$kind eq "QueryFailed"} {
            set data [field $modificationRaw errorData 0]
            if {$data eq ""} { set data null }
            set logs [field $modificationRaw logLines 0]
            if {$logs eq ""} { set logs "\[\]" }
            set text [expr {[dict exists $modification errorMessage] ? [dict get $modification errorMessage] : "Live query failed"}]
            dict set pending $queryId [list error [object [list name [quote FunctionError] message [quote $text] data $data]] $logs]
        } elseif {$kind ne "QueryRemoved"} { error "ProtocolError: unsupported Live modification $kind" }
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
