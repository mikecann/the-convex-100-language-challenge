#!/usr/local/bin/tclsh
# Real loopback HTTP responses, classified through the exact adapter envelopes.
# Convex answers a failed function with status 560, a gateway or proxy can
# answer with something that is not a Convex envelope at all, and a hostile or
# misconfigured peer can announce a body far larger than this client will ever
# hold. Each of those crosses a real socket here.
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]
source [file normalize [file join [file dirname [info script]] http_fixture.tcl]]

proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

proc test_signal {} { incr ::testNotice }
set ::testNotice 0

# Every wait is driven by channel events. There is no polling loop that could
# hide a response the client never classified.
proc wait_for {condition message {timeoutMs 8000}} {
    set ::testTimedOut 0
    set timer [after $timeoutMs { set ::testTimedOut 1; test_signal }]
    while {![uplevel 1 [list expr $condition]] && !$::testTimedOut} {
        vwait ::testNotice
    }
    after cancel $timer
    if {$::testTimedOut} { error "$message (timed out after $timeoutMs ms)" }
}

set ::httpfixture::notify test_signal

# Source the exact adapter without starting its stdin or TCP event loop, then
# capture its real NDJSON output through a channel.
set ::env(ADAPTER_TEST_ONLY) 1
source [file normalize [file join [file dirname [info script]] conformance adapter.tcl]]
unset ::env(ADAPTER_TEST_ONLY)
lassign [chan pipe] adapterRead adapterWrite
fconfigure $adapterRead -blocking 0 -buffering none -translation binary -encoding utf-8
fconfigure $adapterWrite -blocking 0 -buffering none -translation binary -encoding utf-8
set ::adapter::output $adapterWrite
set ::adapterLines {}
set ::adapterBuffer ""

proc adapter_readable {} {
    append ::adapterBuffer [read $::adapterRead]
    while {[set newline [string first "\n" $::adapterBuffer]] >= 0} {
        lappend ::adapterLines [string range $::adapterBuffer 0 [expr {$newline - 1}]]
        set ::adapterBuffer [string range $::adapterBuffer [expr {$newline + 1}] end]
    }
    test_signal
}
fileevent $adapterRead readable adapter_readable

proc adapter_command {raw} {
    set before [llength $::adapterLines]
    ::adapter::handle $raw
    wait_for {[llength $::adapterLines] > $before} "adapter command emitted no envelope"
    return [lindex $::adapterLines $before]
}

proc reset_adapter_client {} {
    if {$::adapter::client ne ""} { catch {::convex::close $::adapter::client} }
    set ::adapter::client ""
}

set httpPort [::httpfixture::start [list \
    {status 200 body {{"status":"success","value":{"ok":true},"logLines":[]}}} \
    {status 560 body {{"status":"error","errorMessage":"fixture 560 failure","errorData":{"code":"UDF"},"logLines":["fixture 560 log"]}}} \
    {status 560 body {{"code":"ConvexError","message":"fixture 560 without envelope"}}} \
    {status 500 body {<html>gateway failure</html>}} \
    {status 400 body {{"code":"BadRequest","message":"fixture 400 rejection"}}} \
    {status 429 body {{"code":"RateLimited","message":"slow down"}}} \
    {status 200 body {{"status":"success","logLines":[]}}} \
]]
set ::env(CONVEX_URL) "http://127.0.0.1:$httpPort"
reset_adapter_client

set success [adapter_command {{"id":"ok","op":"query","path":"demo:state","args":{}}}]
assert {$success eq {{"id":"ok","type":"result","value":{"ok":true}}}} \
    "HTTP 200 success envelope serialization changed: $success"

# A function that failed is still the deployment answering correctly, so 560
# carries the structured FunctionError, its data subtree, and its logs.
set udfEnvelope [adapter_command {{"id":"udf-envelope","op":"query","path":"demo:state","args":{}}}]
assert {$udfEnvelope eq {{"type":"error","id":"udf-envelope","error":{"name":"FunctionError","message":"fixture 560 failure","data":{"code":"UDF"}},"logs":["fixture 560 log"]}}} \
    "HTTP 560 envelope serialization changed: $udfEnvelope"

# 560 without the documented envelope keys still classifies as a function
# failure, and its message survives.
set udfBare [adapter_command {{"id":"udf-bare","op":"mutation","path":"demo:increment","args":{}}}]
assert {$udfBare eq {{"type":"error","id":"udf-bare","error":{"name":"FunctionError","message":"fixture 560 without envelope","data":null}}}} \
    "bare HTTP 560 envelope serialization changed: $udfBare"

# 5xx is something in front of the function failing to answer this attempt, so
# it is a transport failure a caller may retry.
set gateway [adapter_command {{"id":"gateway","op":"query","path":"demo:state","args":{}}}]
assert {$gateway eq {{"type":"error","id":"gateway","error":{"name":"TransportError","message":"HTTP 500 from Convex: no Convex error envelope","data":null}}}} \
    "HTTP 500 envelope serialization changed: $gateway"

# 4xx is a request the deployment refused and would refuse again, so it is a
# protocol failure and it keeps the server's own explanation.
set rejected [adapter_command {{"id":"rejected","op":"query","path":"demo:state","args":{}}}]
assert {$rejected eq {{"type":"error","id":"rejected","error":{"name":"ProtocolError","message":"HTTP 400 from Convex: fixture 400 rejection","data":null}}}} \
    "HTTP 400 envelope serialization changed: $rejected"

set throttled [adapter_command {{"id":"throttled","op":"action","path":"demo:slow","args":{}}}]
assert {$throttled eq {{"type":"error","id":"throttled","error":{"name":"TransportError","message":"HTTP 429 from Convex: slow down","data":null}}}} \
    "HTTP 429 envelope serialization changed: $throttled"

# A 200 that claims success without a value is drift, not an empty result.
set withoutValue [adapter_command {{"id":"no-value","op":"query","path":"demo:state","args":{}}}]
assert {$withoutValue eq {{"type":"error","id":"no-value","error":{"name":"ProtocolError","message":"HTTP success response omitted value","data":null}}}} \
    "success response without a value changed its envelope: $withoutValue"
::httpfixture::stop
reset_adapter_client

# Streaming bounds. The budget is lowered so the fixture stays small, and the
# same production code path enforces it.
set savedResponseBytes $::convex::maximumResponseBytes
set ::convex::maximumResponseBytes [expr {64 * 1024}]
set boundedPort [::httpfixture::start [list \
    [list status 200 contentLength 100000000 stall 1 body [string repeat x 4096]] \
    [list status 200 omitContentLength 1 stall 1 body [string repeat y [expr {256 * 1024}]]]]]
set ::env(CONVEX_URL) "http://127.0.0.1:$boundedPort"

# A body that only claims to be enormous is refused after the first block. The
# fixture never sends the 100 MB it announced, so nothing could have allocated
# it: the declared size alone ends the transaction.
set declaredStart [clock milliseconds]
set declared [adapter_command {{"id":"declared","op":"query","path":"demo:state","args":{}}}]
set declaredElapsed [expr {[clock milliseconds] - $declaredStart}]
set declaredError [::convex::decode [::convex::field $declared error]]
assert {[dict get $declaredError name] eq "TransportError"} \
    "declared oversize response was not a TransportError: $declared"
assert {[string match {*exceeded the 65536 byte budget*} [dict get $declaredError message]]} \
    "declared oversize response lost its budget message: $declared"
assert {$declaredElapsed < 5000} "declared oversize response took ${declaredElapsed}ms to abandon"
assert {$::httpfixture::sentBodyBytes == 4096} \
    "declared oversize fixture sent $::httpfixture::sentBodyBytes body bytes"

# Connection-close framing gives the client no size at all, so only the
# accumulated byte count can stop it. One block of overshoot is the bound.
set streamed [adapter_command {{"id":"streamed","op":"query","path":"demo:state","args":{}}}]
set streamedError [::convex::decode [::convex::field $streamed error]]
assert {[dict get $streamedError name] eq "TransportError"} \
    "unbounded streamed response was not a TransportError: $streamed"
assert {[string match {*exceeded the 65536 byte budget*} [dict get $streamedError message]]} \
    "unbounded streamed response lost its budget message: $streamed"
set ::convex::maximumResponseBytes $savedResponseBytes
::httpfixture::stop
reset_adapter_client

fileevent $adapterRead readable {}
close $adapterRead
close $adapterWrite
unset ::env(CONVEX_URL)
puts "Tcl HTTP status classification and streaming bound tests passed"
