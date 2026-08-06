# Deterministic loopback HTTP/1.1 peer for the Tcl client tests. It answers with
# exactly the status line, headers, and body bytes a test asks for, including a
# deliberately dishonest Content-Length and a body that never ends, so response
# classification and streaming bounds are exercised against a real socket rather
# than a mocked transport.
namespace eval ::httpfixture {
    variable server ""
    variable responses {}
    variable buffers {}
    variable lastRequestBody ""
    variable lastRequestHeaders ""
    variable sentBodyBytes 0
    # Tests drive their waits from their own event source. This hook lets the
    # fixture report progress without depending on any particular one.
    variable notify ""
}

proc ::httpfixture::signal {} {
    variable notify
    if {$notify ne ""} { uplevel #0 $notify }
}

# Each response is a dict: status, body, and optionally contentLength to declare
# a size the body does not have, omitContentLength for connection-close framing,
# and stall to keep the connection open after the bytes are written.
proc ::httpfixture::start {items} {
    variable server
    variable responses
    variable buffers
    variable lastRequestBody
    variable lastRequestHeaders
    variable sentBodyBytes
    set responses $items
    set buffers {}
    set lastRequestBody ""
    set lastRequestHeaders ""
    set sentBodyBytes 0
    set server [socket -server ::httpfixture::accept -myaddr 127.0.0.1 0]
    return [lindex [fconfigure $server -sockname] end]
}

proc ::httpfixture::stop {} {
    variable server
    variable buffers
    foreach channel [dict keys $buffers] {
        catch {fileevent $channel readable {}}
        catch {close $channel}
    }
    set buffers {}
    if {$server ne ""} {
        catch {close $server}
        set server ""
    }
}

proc ::httpfixture::accept {channel host port} {
    variable buffers
    fconfigure $channel -blocking 0 -buffering none -translation binary -encoding binary
    dict set buffers $channel ""
    fileevent $channel readable [list ::httpfixture::readable $channel]
}

proc ::httpfixture::finish {channel} {
    variable buffers
    catch {fileevent $channel readable {}}
    catch {close $channel}
    if {[dict exists $buffers $channel]} { dict unset buffers $channel }
    signal
}

proc ::httpfixture::readable {channel} {
    variable buffers
    variable responses
    variable lastRequestBody
    variable lastRequestHeaders
    if {![dict exists $buffers $channel]} { return }
    if {[catch {set bytes [read $channel]}]} { finish $channel; return }
    dict append buffers $channel $bytes
    set requestBytes [dict get $buffers $channel]
    set headerEnd [string first "\r\n\r\n" $requestBytes]
    if {$headerEnd < 0} {
        if {[eof $channel]} { finish $channel }
        return
    }
    set contentLength 0
    regexp -nocase {\r\nContent-Length:[ \t]*([0-9]+)} [string range $requestBytes 0 $headerEnd] -> contentLength
    set bodyStart [expr {$headerEnd + 4}]
    if {[string bytelength $requestBytes] - $bodyStart < $contentLength} { return }
    set lastRequestHeaders [string range $requestBytes 0 [expr {$headerEnd + 3}]]
    set wireBody [string range $requestBytes $bodyStart [expr {$bodyStart + $contentLength - 1}]]
    # The client advertises a byte count, so decoding here proves the request
    # body really is the UTF-8 the header promised.
    if {[catch {set lastRequestBody [encoding convertfrom utf-8 $wireBody]} problem]} {
        error "HTTP fixture received invalid UTF-8 request body: $problem"
    }
    if {![llength $responses]} { error "HTTP fixture ran out of scripted responses" }
    set descriptor [lindex $responses 0]
    set responses [lrange $responses 1 end]
    respond $channel $descriptor
}

proc ::httpfixture::respond {channel descriptor} {
    variable sentBodyBytes
    # One scripted response per connection: every reply closes the connection or
    # deliberately stalls, so no further request is read from this socket.
    catch {fileevent $channel readable {}}
    set status 200
    if {[dict exists $descriptor status]} { set status [dict get $descriptor status] }
    set body ""
    if {[dict exists $descriptor body]} { set body [dict get $descriptor body] }
    set wire [encoding convertto utf-8 $body]
    set headers "HTTP/1.1 $status [reason $status]\r\nContent-Type: application/json; charset=utf-8\r\n"
    if {[dict exists $descriptor omitContentLength] && [dict get $descriptor omitContentLength]} {
        # Connection-close framing. The client cannot learn the size in advance,
        # so only its accumulated-byte budget can stop an endless body.
        append headers "Connection: close\r\n\r\n"
    } else {
        set declared [string bytelength $wire]
        if {[dict exists $descriptor contentLength]} { set declared [dict get $descriptor contentLength] }
        append headers "Content-Length: $declared\r\nConnection: close\r\n\r\n"
    }
    if {[catch {
        puts -nonewline $channel $headers
        puts -nonewline $channel $wire
        flush $channel
    }]} {
        finish $channel
        return
    }
    incr sentBodyBytes [string bytelength $wire]
    signal
    if {[dict exists $descriptor stall] && [dict get $descriptor stall]} { return }
    finish $channel
}

proc ::httpfixture::reason {status} {
    switch -- $status {
        200 { return "OK" }
        400 { return "Bad Request" }
        401 { return "Unauthorized" }
        404 { return "Not Found" }
        408 { return "Request Timeout" }
        429 { return "Too Many Requests" }
        500 { return "Internal Server Error" }
        503 { return "Service Unavailable" }
        560 { return "Convex Function Error" }
        default { return "Response" }
    }
}
