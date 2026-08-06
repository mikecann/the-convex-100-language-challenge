# Deterministic loopback WebSocket peer for the Tcl client tests. It speaks the
# real byte protocol on TCP, records every Connect/ModifyQuerySet message, and
# can inject fragmentation, protocol failures, transport failures, and large
# values without borrowing another Convex client.
namespace eval ::livefixture {
    variable server ""
    variable port 0
    variable sockets {}
    variable current ""
    variable acceptedCount 0
    variable notice 0
    variable timestampCounter 0
    variable currentPayload {{"count":0}}
    variable connectRecords {}
    variable modificationRecords {}
    variable pongCount 0
}

proc ::livefixture::signal {} {
    variable notice
    incr notice
}

proc ::livefixture::initial_version {} {
    return {{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="}}
}

proc ::livefixture::timestamp {value} {
    set bytes {}
    for {set index 0} {$index < 8} {incr index} {
        lappend bytes [expr {$value & 255}]
        set value [expr {$value >> 8}]
    }
    return [binary encode base64 -maxlen 0 [binary format cu* $bytes]]
}

proc ::livefixture::next_version {querySet} {
    variable timestampCounter
    incr timestampCounter
    return [::convex::object [list querySet $querySet identity 0 ts [::convex::quote [timestamp $timestampCounter]]]]
}

proc ::livefixture::start {} {
    variable server
    variable port
    variable sockets
    variable current
    variable acceptedCount
    variable notice
    variable timestampCounter
    variable currentPayload
    variable connectRecords
    variable modificationRecords
    variable pongCount
    set sockets {}
    set current ""
    set acceptedCount 0
    set notice 0
    set timestampCounter 0
    set currentPayload {{"count":0}}
    set connectRecords {}
    set modificationRecords {}
    set pongCount 0
    set server [socket -server ::livefixture::accept -myaddr 127.0.0.1 0]
    set port [lindex [fconfigure $server -sockname] end]
    return $port
}

proc ::livefixture::stop {} {
    variable server
    variable sockets
    foreach channel [dict keys $sockets] {
        catch {fileevent $channel readable {}}
        catch {close $channel}
    }
    set sockets {}
    if {$server ne ""} { catch {close $server}; set server "" }
    signal
}

proc ::livefixture::accept {channel host peerPort} {
    variable sockets
    variable current
    variable acceptedCount
    incr acceptedCount
    fconfigure $channel -blocking 0 -buffering none -translation binary -encoding binary
    dict set sockets $channel [dict create stage handshake buffer "" remote [initial_version] querySet 0 active {} closed 0 index [expr {$acceptedCount - 1}]]
    set current $channel
    fileevent $channel readable [list ::livefixture::readable $channel]
    signal
}

proc ::livefixture::disconnect {channel} {
    variable sockets
    variable current
    if {![dict exists $sockets $channel]} { return }
    catch {fileevent $channel readable {}}
    catch {close $channel}
    dict set sockets $channel closed 1
    if {$current eq $channel} { set current "" }
    signal
}

proc ::livefixture::readable {channel} {
    variable sockets
    if {![dict exists $sockets $channel] || [dict get $sockets $channel closed]} { return }
    if {[catch {set bytes [read $channel]} problem]} {
        disconnect $channel
        return
    }
    if {$bytes ne ""} {
        set state [dict get $sockets $channel]
        dict append state buffer $bytes
        dict set sockets $channel $state
    }
    if {[eof $channel]} {
        disconnect $channel
        return
    }
    if {[catch {
        if {[dict get $sockets $channel stage] eq "handshake"} { handshake $channel }
        if {[dict exists $sockets $channel] && ![dict get $sockets $channel closed] && [dict get $sockets $channel stage] eq "open"} {
            frames $channel
        }
    } problem]} {
        if {![string match {*connection reset by peer*} [string tolower $problem]]} {
            puts stderr "loopback WebSocket fixture failed: $problem"
        }
        disconnect $channel
    }
}

proc ::livefixture::handshake {channel} {
    variable sockets
    set buffer [dict get $sockets $channel buffer]
    set end [string first "\r\n\r\n" $buffer]
    if {$end < 0} { return }
    set headers [string range $buffer 0 [expr {$end + 3}]]
    dict set sockets $channel buffer [string range $buffer [expr {$end + 4}] end]
    set key ""
    foreach line [split $headers "\r\n"] {
        if {[regexp -nocase {^Sec-WebSocket-Key:[ \t]*(.+)$} $line -> value]} { set key [string trim $value] }
    }
    if {$key eq ""} { error "fixture handshake omitted Sec-WebSocket-Key" }
    set accept [::base64::encode [::sha1::sha1 -bin "${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11"]]
    set response "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: $accept\r\n\r\n"
    puts -nonewline $channel $response
    flush $channel
    dict set sockets $channel stage open
    signal
}

proc ::livefixture::byte_at {bytes index} {
    binary scan $bytes @${index}cu value
    return $value
}

proc ::livefixture::frames {channel} {
    variable sockets
    variable pongCount
    set buffer [dict get $sockets $channel buffer]
    while {[string bytelength $buffer] >= 2} {
        set first [byte_at $buffer 0]
        set second [byte_at $buffer 1]
        set opcode [expr {$first & 15}]
        set length [expr {$second & 127}]
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
        set masked [expr {($second & 128) != 0}]
        if {!$masked} { error "client WebSocket frame was not masked" }
        if {[string bytelength $buffer] < $offset + 4 + $length} { break }
        set mask [string range $buffer $offset [expr {$offset + 3}]]
        incr offset 4
        set payload [string range $buffer $offset [expr {$offset + $length - 1}]]
        set buffer [string range $buffer [expr {$offset + $length}] end]
        binary scan $mask cu4 maskBytes
        binary scan $payload cu* payloadBytes
        set unmasked {}
        set index 0
        foreach byte $payloadBytes {
            lappend unmasked [expr {$byte ^ [lindex $maskBytes [expr {$index % 4}]]}]
            incr index
        }
        set payload [binary format cu* $unmasked]
        if {$opcode == 1} {
            handle_json $channel [encoding convertfrom utf-8 $payload]
        } elseif {$opcode == 8} {
            disconnect $channel
            return
        } elseif {$opcode == 10} {
            incr pongCount
            signal
        } elseif {$opcode != 9} {
            error "unsupported client fixture opcode $opcode"
        }
    }
    if {[dict exists $sockets $channel]} { dict set sockets $channel buffer $buffer }
}

proc ::livefixture::server_frame_bytes {opcode payload {final 1}} {
    # Convert through an unsigned-byte list before constructing the frame. Tcl
    # strings can carry both a Unicode and byte representation, and using
    # character slicing on a bytearray can silently make the payload length and
    # the bytes appended to the frame disagree.
    binary scan $payload cu* payloadBytes
    set length [llength $payloadBytes]
    set first [expr {($final ? 128 : 0) | $opcode}]
    if {$length < 126} {
        set header [binary format cu2 [list $first $length]]
    } elseif {$length <= 65535} {
        set header "[binary format cu $first][binary format cu 126][binary format S $length]"
    } else {
        set header "[binary format cu $first][binary format cu 127][binary format W $length]"
    }
    append header [binary format cu* $payloadBytes]
    return $header
}

proc ::livefixture::server_frame {opcode payload {final 1}} {
    return [server_frame_bytes $opcode [encoding convertto utf-8 $payload] $final]
}

proc ::livefixture::write_frame {channel opcode payload {final 1}} {
    if {[catch {
        puts -nonewline $channel [server_frame $opcode $payload $final]
        flush $channel
    } problem]} {
        if {![string match {*would block*} [string tolower $problem]]} { error $problem }
    }
}

proc ::livefixture::send_json {channel raw} {
    write_frame $channel 1 $raw
}

proc ::livefixture::handle_json {channel raw} {
    variable sockets
    variable currentPayload
    variable connectRecords
    variable modificationRecords
    set message [::convex::decode $raw]
    set type [dict get $message type]
    if {$type eq "Connect"} {
        lappend connectRecords $message
        signal
        return
    }
    if {$type ne "ModifyQuerySet"} { return }
    set newVersion [dict get $message newVersion]
    set responseModifications {}
    foreach modificationRaw [::convex::elements [::convex::field $raw modifications]] {
        set modification [::convex::decode $modificationRaw]
        set kind [dict get $modification type]
        set queryId [dict get $modification queryId]
        lappend modificationRecords [list [dict get $sockets $channel index] $kind $queryId $message]
        if {$kind eq "Add"} {
            dict set sockets $channel active $queryId 1
            lappend responseModifications [::convex::object [list type [::convex::quote QueryUpdated] queryId $queryId value $currentPayload logLines "\[\]"]]
        } elseif {$kind eq "Remove"} {
            if {[dict exists $sockets $channel active $queryId]} { dict unset sockets $channel active $queryId }
            lappend responseModifications [::convex::object [list type [::convex::quote QueryRemoved] queryId $queryId]]
        } else {
            error "fixture received unsupported modification $kind"
        }
    }
    dict set sockets $channel querySet $newVersion
    transition $channel $newVersion $responseModifications
    signal
}

proc ::livefixture::transition {channel querySet modifications} {
    variable sockets
    set start [dict get $sockets $channel remote]
    set end [next_version $querySet]
    set raw [::convex::object [list type [::convex::quote Transition] startVersion $start endVersion $end modifications [::convex::array $modifications]]]
    send_json $channel $raw
    dict set sockets $channel remote $end
    signal
    return $end
}

proc ::livefixture::update {value {payloadField count}} {
    variable sockets
    variable current
    variable currentPayload
    if {$current eq "" || ![dict exists $sockets $current] || [dict get $sockets $current closed]} { error "fixture has no active WebSocket" }
    set modifications {}
    set valueRaw [::convex::object [list $payloadField [expr {$payloadField eq "count" ? $value : [::convex::quote $value]}]]]
    set currentPayload $valueRaw
    foreach queryId [dict keys [dict get $sockets $current active]] {
        lappend modifications [::convex::object [list type [::convex::quote QueryUpdated] queryId $queryId value $valueRaw logLines "\[\]"]]
    }
    return [transition $current [dict get $sockets $current querySet] $modifications]
}

proc ::livefixture::set_next_payload {raw} {
    variable currentPayload
    # Change only what a later Add rehydrates. No transition is emitted, which
    # lets a test separate output backpressure from an unrelated second parse
    # of the same near-maximum value.
    set currentPayload $raw
}

proc ::livefixture::query_failed {message} {
    variable sockets
    variable current
    set modifications {}
    foreach queryId [dict keys [dict get $sockets $current active]] {
        lappend modifications [::convex::object [list type [::convex::quote QueryFailed] queryId $queryId errorMessage [::convex::quote $message] errorData [::convex::object [list code [::convex::quote FIXTURE]]] logLines [::convex::array [list [::convex::quote "fixture failure log"]]]]]
    }
    return [transition $current [dict get $sockets $current querySet] $modifications]
}

proc ::livefixture::query_failed_without_data {message} {
    variable sockets
    variable current
    set modifications {}
    foreach queryId [dict keys [dict get $sockets $current active]] {
        lappend modifications [::convex::object [list type [::convex::quote QueryFailed] queryId $queryId errorMessage [::convex::quote $message] logLines "\[\]"]]
    }
    return [transition $current [dict get $sockets $current querySet] $modifications]
}

proc ::livefixture::malformed_transition {end modifications} {
    variable sockets
    variable current
    set start [dict get $sockets $current remote]
    set raw [::convex::object [list type [::convex::quote Transition] startVersion $start endVersion $end modifications [::convex::array $modifications]]]
    send_json $current $raw
    signal
}

proc ::livefixture::malformed_version {} {
    variable sockets
    variable current
    variable timestampCounter
    incr timestampCounter
    set end [::convex::object [list querySet [::convex::quote 0] identity 0 ts [::convex::quote [timestamp $timestampCounter]]]]
    set modifications {}
    foreach queryId [dict keys [dict get $sockets $current active]] {
        lappend modifications [::convex::object [list type [::convex::quote QueryUpdated] queryId $queryId value {{"count":800}}]]
    }
    malformed_transition $end $modifications
}

proc ::livefixture::malformed_query_id {} {
    variable sockets
    variable current
    set end [next_version [dict get $sockets $current querySet]]
    set modification [::convex::object [list type [::convex::quote QueryUpdated] queryId [::convex::quote 0] value {{"count":900}}]]
    malformed_transition $end [list $modification]
}

proc ::livefixture::malformed_query_failed {} {
    variable sockets
    variable current
    set end [next_version [dict get $sockets $current querySet]]
    set modification [::convex::object [list type [::convex::quote QueryFailed] queryId 0 errorMessage 7 errorData {{"code":"MALFORMED"}}]]
    malformed_transition $end [list $modification]
}

proc ::livefixture::fragmented_update {value} {
    variable sockets
    variable current
    variable currentPayload
    set modifications {}
    # Keep the fixture marker as literal UTF-8 instead of json::write's escaped
    # surrogate form, so the frame boundary can bisect the real code point.
    set currentPayload "\{\"text\":\"$value\"\}"
    foreach queryId [dict keys [dict get $sockets $current active]] {
        lappend modifications [::convex::object [list type [::convex::quote QueryUpdated] queryId $queryId value $currentPayload logLines "\[\]"]]
    }
    set start [dict get $sockets $current remote]
    set end [next_version [dict get $sockets $current querySet]]
    set raw [::convex::object [list type [::convex::quote Transition] startVersion $start endVersion $end modifications [::convex::array $modifications]]]
    set bytes [encoding convertto utf-8 $raw]
    set marker [encoding convertto utf-8 🟨]
    binary scan $bytes H* payloadHex
    binary scan $marker H* markerHex
    set markerHexStart [string first $markerHex $payloadHex]
    if {$markerHexStart < 0} { error "fragment fixture payload omitted its UTF-8 marker" }
    if {$markerHexStart % 2 != 0} { error "fragment fixture found a half-byte marker offset" }
    binary scan $bytes cu* payloadBytes
    # Split one byte into the four-byte code point, then interleave a Ping.
    set split [expr {$markerHexStart / 2 + 1}]
    set first [binary format cu* [lrange $payloadBytes 0 [expr {$split - 1}]]]
    set second [binary format cu* [lrange $payloadBytes $split end]]
    puts -nonewline $current [server_frame_bytes 1 $first 0]
    puts -nonewline $current [server_frame 9 ping 1]
    puts -nonewline $current [server_frame_bytes 0 $second 1]
    flush $current
    dict set sockets $current remote $end
    signal
    return $end
}

proc ::livefixture::protocol_error {} {
    variable current
    # A server frame must never carry the mask bit. The real parser consumes
    # these bytes and retires this connection as ProtocolError.
    puts -nonewline $current [binary format cu2 [list 129 128]]
    flush $current
    signal
}

proc ::livefixture::stall_partial_frame {} {
    variable current
    # Send the complete frame header and one payload byte, then deliberately
    # leave the TCP connection open. The client must retain these exact bytes
    # until its partial-frame deadline abandons this socket.
    set frame [server_frame 1 {{"type":"Ping"}}]
    binary scan $frame cu* bytes
    set prefix [binary format cu* [lrange $bytes 0 2]]
    puts -nonewline $current $prefix
    flush $current
    signal
}

proc ::livefixture::transport_error {} {
    variable current
    disconnect $current
}

proc ::livefixture::ping {{payload fixture-barrier}} {
    variable current
    write_frame $current 9 $payload
}

proc ::livefixture::connections {} {
    variable acceptedCount
    return $acceptedCount
}

proc ::livefixture::connects {} {
    variable connectRecords
    return $connectRecords
}

proc ::livefixture::modifications {} {
    variable modificationRecords
    return $modificationRecords
}

proc ::livefixture::active_channel {} {
    variable current
    return $current
}

proc ::livefixture::active_remote {} {
    variable sockets
    variable current
    if {$current eq ""} { return "" }
    return [dict get $sockets $current remote]
}
