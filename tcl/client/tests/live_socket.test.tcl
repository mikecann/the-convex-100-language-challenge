#!/usr/local/bin/tclsh
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]
source [file normalize [file join [file dirname [info script]] live_fixture.tcl]]

proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

# Every wait is driven by socket, pipe, or timer events. There is no polling
# loop that can hide a missing reconnect or acknowledgement.
proc wait_for {condition message {timeoutMs 4000}} {
    set ::testTimedOut 0
    set timer [after $timeoutMs { set ::testTimedOut 1; ::livefixture::signal }]
    while {![uplevel 1 [list expr $condition]] && !$::testTimedOut} {
        vwait ::livefixture::notice
    }
    after cancel $timer
    if {$::testTimedOut} { error "$message (timed out after $timeoutMs ms)" }
}

proc quiet_for {milliseconds} {
    set ::quietComplete 0
    after $milliseconds { set ::quietComplete 1; ::livefixture::signal }
    wait_for {$::quietComplete} "quiet interval did not finish" [expr {$milliseconds + 1000}]
}

proc direct_callback {name kind payload logs} {
    lappend ::directEvents($name) [list $kind $payload $logs]
    ::livefixture::signal
}

proc modification_records {connection kind} {
    set matches {}
    foreach record [::livefixture::modifications] {
        if {[lindex $record 0] == $connection && [lindex $record 1] eq $kind} { lappend matches $record }
    }
    return $matches
}

proc client_state_changed {args} {
    ::livefixture::signal
}

proc assert_malformed_live_recovery {fixtureCommand expectedMessage expectedConnections connectionIndex recoveryValue} {
    set before [llength $::adapterLines]
    {*}$fixtureCommand
    wait_for {[llength $::adapterLines] > $before} "malformed Live transition emitted no adapter envelope"
    set expected [::convex::object [list type [::convex::quote subscription] subscriptionId [::convex::quote same] error [::adapter::error_raw $expectedMessage ProtocolError null]]]
    assert {[lindex $::adapterLines $before] eq $expected} "malformed Live ProtocolError envelope changed: actual=[lindex $::adapterLines $before] expected=$expected"
    wait_for {[::livefixture::connections] == $expectedConnections} "malformed Live transition did not reconnect"
    wait_for {[llength [modification_records $connectionIndex Add]] == 1} "malformed Live reconnect did not resend Add"
    wait_for {[dict get [::convex::state $::adapter::client] remote] eq [::livefixture::active_remote]} "malformed Live reconnect did not hydrate"
    set before [llength $::adapterLines]
    ::livefixture::update $recoveryValue
    wait_for {[llength $::adapterLines] > $before} "malformed Live transition stranded the subscription"
    assert {[dict get [dict get [::convex::decode [lindex $::adapterLines $before]] value] count] == $recoveryValue} "malformed Live recovery value was wrong"
}

# Two real subscriptions prove nextQueryId survives the state write and that
# fragmentation across a UTF-8 code point with an interleaved Ping preserves
# both callbacks and produces a Pong.
set port [::livefixture::start]
array set directEvents {first {} second {}}
set directClient [::convex::new "http://127.0.0.1:$port"]
set firstQuery [::convex::subscribe $directClient demo:first {{}} [list direct_callback first]]
set secondQuery [::convex::subscribe $directClient demo:second {{}} [list direct_callback second]]
assert {$firstQuery == 0 && $secondQuery == 1} "concurrent subscriptions reused a query ID"
if {[catch {wait_for {[llength [modification_records 0 Add]] == 2} "initial connection did not receive both Add operations"} problem]} {
    error "$problem; connects=[::livefixture::connects]; modifications=[::livefixture::modifications]; state=[::convex::state $directClient]"
}
wait_for {[llength $::directEvents(first)] == 1 && [llength $::directEvents(second)] == 1} "both subscriptions did not hydrate"
set initialConnect [lindex [::livefixture::connects] 0]
assert {[dict get $initialConnect connectionCount] == 0} "initial connectionCount was not zero"
assert {[dict get $initialConnect lastCloseReason] eq "InitialConnect"} "initial close reason changed"
assert {![dict exists $initialConnect maxObservedTimestamp]} "initial Connect invented maxObservedTimestamp"
::livefixture::fragmented_update "fragmented 🟨🟩🟦"
wait_for {[llength $::directEvents(first)] == 2 && [llength $::directEvents(second)] == 2} "fragmented UTF-8 value was not delivered"
wait_for {$::livefixture::pongCount == 1} "interleaved WebSocket Ping did not receive Pong"
set fragmented [::convex::decode [::convex::field [lindex [lindex $::directEvents(first) 1] 1] text]]
assert {$fragmented eq "fragmented 🟨🟩🟦"} "fragmented UTF-8 value was corrupted"
::convex::unsubscribe $directClient $firstQuery
::convex::unsubscribe $directClient $secondQuery
wait_for {[llength [modification_records 0 Remove]] == 2} "real unsubscribe did not send both Remove operations"
::convex::close $directClient
quiet_for 20
::livefixture::stop

# Source the exact adapter and capture its real NDJSON output through a channel.
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
    ::livefixture::signal
}
fileevent $adapterRead readable adapter_readable

proc adapter_command {raw} {
    set before [llength $::adapterLines]
    ::adapter::handle $raw
    wait_for {[llength $::adapterLines] > $before} "adapter command emitted no envelope"
    return [lindex $::adapterLines $before]
}

proc assert_error_without_id {raw expectedMessage} {
    set decoded [::convex::decode $raw]
    assert {[dict get $decoded type] eq "error"} "malformed command did not emit error"
    assert {![dict exists $decoded id]} "malformed command invented an id"
    assert {[dict get [::convex::decode [::convex::field $raw error]] name] eq "ProtocolError"} "malformed command lost ProtocolError"
    if {$expectedMessage ne ""} {
        set expected [::convex::object [list type [::convex::quote error] error [::adapter::error_raw $expectedMessage ProtocolError null]]]
        assert {$raw eq $expected} "malformed command error serialization changed: actual=$raw expected=$expected"
    }
}

# Parse failures and absent, empty, or non-string IDs must omit id completely.
set malformed [adapter_command \{]
assert_error_without_id $malformed ""
set missingId [adapter_command {{"protocolVersion":1,"op":"hello"}}]
assert_error_without_id $missingId "command omitted valid id"
set emptyId [adapter_command {{"protocolVersion":1,"id":"","op":"hello"}}]
assert_error_without_id $emptyId "command omitted valid id"
set numericId [adapter_command {{"protocolVersion":1,"id":7,"op":"hello"}}]
assert_error_without_id $numericId "command omitted valid id"

set ready [adapter_command {{"protocolVersion":1,"id":"hello","op":"hello"}}]
assert {$ready eq {{"protocolVersion":1,"id":"hello","type":"ready","language":"tcl","implementation":"native-tcl-8.6.13","runtime":"tcl-8.6.13"}}} "ready envelope serialization changed"
set badOperation [adapter_command {{"id":"bad-op","op":"nope"}}]
assert {$badOperation eq {{"type":"error","id":"bad-op","error":{"name":"ProtocolError","message":"unknown adapter operation nope","data":null}}}} "valid-id error envelope serialization changed"

# A real loopback HTTP server covers success, FunctionError, malformed response,
# and connection refusal through the adapter's exact envelope classifier.
namespace eval ::httpfixture {
    variable server ""
    variable responses {}
    variable buffers {}
    variable lastRequestBody ""
}
proc ::httpfixture::start {items} {
    variable server
    variable responses
    variable lastRequestBody
    set responses $items
    set lastRequestBody ""
    set server [socket -server ::httpfixture::accept -myaddr 127.0.0.1 0]
    return [lindex [fconfigure $server -sockname] end]
}
proc ::httpfixture::accept {channel host port} {
    variable buffers
    fconfigure $channel -blocking 0 -buffering none -translation binary -encoding binary
    dict set buffers $channel ""
    fileevent $channel readable [list ::httpfixture::readable $channel]
}
proc ::httpfixture::readable {channel} {
    variable buffers
    variable responses
    variable lastRequestBody
    append request [read $channel]
    dict append buffers $channel $request
    set requestBytes [dict get $buffers $channel]
    set headerEnd [string first "\r\n\r\n" $requestBytes]
    if {$headerEnd < 0} { return }
    set contentLength 0
    regexp -nocase {\r\nContent-Length:[ \t]*([0-9]+)} [string range $requestBytes 0 $headerEnd] -> contentLength
    set bodyStart [expr {$headerEnd + 4}]
    if {[string bytelength $requestBytes] - $bodyStart < $contentLength} { return }
    set wireBody [string range $requestBytes $bodyStart [expr {$bodyStart + $contentLength - 1}]]
    if {[catch {set lastRequestBody [encoding convertfrom utf-8 $wireBody]} problem]} {
        error "HTTP fixture received invalid UTF-8 request body: $problem"
    }
    set body [lindex $responses 0]
    set responses [lrange $responses 1 end]
    # Send the exact UTF-8 bytes advertised by Content-Length. This catches
    # response parsers that only work for ASCII or discard nested/log subtrees.
    set wire [encoding convertto utf-8 $body]
    set response "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: [string bytelength $wire]\r\nConnection: close\r\n\r\n$wire"
    puts -nonewline $channel $response
    flush $channel
    fileevent $channel readable {}
    close $channel
    dict unset buffers $channel
    ::livefixture::signal
}
proc ::httpfixture::stop {} {
    variable server
    catch {close $server}
    set server ""
}
set httpSystemEncoding [encoding system]
encoding system iso8859-1
set httpPort [::httpfixture::start [list \
    {{"status":"success","value":{"ok":true},"logLines":[]}} \
    {{"status":"success","value":{"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],"number":42.5,"nil":null}},"logLines":["[LOG] 'demo:echo received a JSON-safe value'"]}} \
    {{"status":"success","value":["Καλημέρα","مرحبا","kia ora","🟨🟩🟦"],"logLines":["utf8 response log 世界 👋"]}} \
    {{"status":"error","errorMessage":"fixture HTTP failure","errorData":{"code":"HTTP_FIXTURE"},"logLines":["fixture HTTP log"]}} \
    "\{malformed"]]
set ::env(CONVEX_URL) "http://127.0.0.1:$httpPort"
set ::adapter::client ""
set httpSuccess [adapter_command {{"id":"http-success","op":"query","path":"demo:state","args":{}}}]
assert {$httpSuccess eq {{"id":"http-success","type":"result","value":{"ok":true}}}} "HTTP success envelope serialization changed"
set httpNested [adapter_command {{"id":"http-nested","op":"query","path":"demo:echo","args":{"value":{"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],"number":42.5,"nil":null}}}}}]
assert {$httpNested eq {{"id":"http-nested","type":"result","value":{"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],"number":42.5,"nil":null}},"logs":["[LOG] 'demo:echo received a JSON-safe value'"]}}} "nested HTTP value or logLines were not preserved"
set nestedRequest [::convex::decode [::convex::field $::httpfixture::lastRequestBody args]]
assert {[dict get [dict get $nestedRequest value] unicode] eq "Hello, 世界 👋"} "UTF-8 nested HTTP request was not preserved"
set httpUtf8 [adapter_command {{"id":"http-utf8","op":"query","path":"demo:echo","args":{"value":["Καλημέρα","مرحبا","kia ora","🟨🟩🟦"]}}}]
assert {$httpUtf8 eq {{"id":"http-utf8","type":"result","value":["Καλημέρα","مرحبا","kia ora","🟨🟩🟦"],"logs":["utf8 response log 世界 👋"]}}} "UTF-8 HTTP value or logs were not preserved"
set utf8Request [::convex::decode [::convex::field $::httpfixture::lastRequestBody args]]
assert {[lindex [dict get $utf8Request value] 3] eq "🟨🟩🟦"} "UTF-8 array HTTP request was not preserved"
set httpFunction [adapter_command {{"id":"http-function","op":"query","path":"demo:state","args":{}}}]
assert {$httpFunction eq {{"type":"error","id":"http-function","error":{"name":"FunctionError","message":"fixture HTTP failure","data":{"code":"HTTP_FIXTURE"}},"logs":["fixture HTTP log"]}}} "HTTP FunctionError envelope serialization changed"
set httpProtocol [adapter_command {{"id":"http-protocol","op":"query","path":"demo:state","args":{}}}]
set httpProtocolObject [::convex::decode $httpProtocol]
assert {[dict get [dict get $httpProtocolObject error] name] eq "ProtocolError"} "malformed HTTP response was not ProtocolError"
::httpfixture::stop
encoding system $httpSystemEncoding
::convex::close $::adapter::client
set ::adapter::client ""
set httpTransport [adapter_command {{"id":"http-transport","op":"query","path":"demo:state","args":{}}}]
set httpTransportObject [::convex::decode $httpTransport]
assert {[dict get [dict get $httpTransportObject error] name] eq "TransportError"} "HTTP connection refusal was not TransportError"
::convex::close $::adapter::client
set ::adapter::client ""

# The adapter command is acknowledged first, then the real WebSocket hydrates
# the subscription. Every later assertion inspects complete adapter envelopes.
set port [::livefixture::start]
set ::env(CONVEX_URL) "http://127.0.0.1:$port"
set beforeSubscribe [llength $::adapterLines]
set subscribeAck [adapter_command {{"id":"subscribe","op":"subscribe","subscriptionId":"same","path":"demo:state","args":{}}}]
assert {$subscribeAck eq {{"id":"subscribe","type":"ack"}}} "subscribe acknowledgement serialization changed"
wait_for {[llength [modification_records 0 Add]] == 1} "adapter subscription did not send Add"
wait_for {[llength $::adapterLines] >= $beforeSubscribe + 2} "initial adapter subscription value was not emitted"
set initialValue [lindex $::adapterLines [expr {$beforeSubscribe + 1}]]
assert {$initialValue eq {{"type":"subscription","subscriptionId":"same","value":{"count":0}}}} "initial subscription envelope serialization changed"
# Unchanged reconnect hydration deliberately emits no subscription event. A
# trace on the real client state lets waits observe owner transitions without
# adding a timer-based polling loop or changing production callbacks.
trace add variable ::convex::clients($::adapter::client) write client_state_changed

set expectedValue 0
for {set attempt 1} {$attempt <= 5} {incr attempt} {
    set previousTimestamp [dict get [::convex::state $::adapter::client] maxTimestamp]
    set before [llength $::adapterLines]
    ::adapter::handle [format {{"id":"debug-%d","op":"debugDisconnect"}} $attempt]
    set retired [::convex::state $::adapter::client]
    assert {[dict get $retired socket] eq ""} "debugDisconnect $attempt acknowledged before socket retirement"
    assert {[dict get $retired reconnectTimer] ne ""} "debugDisconnect $attempt acknowledged before reconnect scheduling"
    wait_for {[llength $::adapterLines] > $before} "debugDisconnect $attempt acknowledgement was not emitted"
    assert {[lindex $::adapterLines $before] eq [format {{"id":"debug-%d","type":"ack"}} $attempt]} "debugDisconnect acknowledgement serialization changed"
    wait_for {[::livefixture::connections] == $attempt + 1} "debugDisconnect $attempt did not open a new socket"
    wait_for {[llength [::livefixture::connects]] == $attempt + 1} "debugDisconnect $attempt omitted Connect"
    wait_for {[llength [modification_records $attempt Add]] == 1} "debugDisconnect $attempt did not resend Add"
    wait_for {[dict get [::convex::state $::adapter::client] remote] eq [::livefixture::active_remote]} "debugDisconnect $attempt did not finish rehydration"
    set reconnected [lindex [::livefixture::connects] $attempt]
    assert {[dict get $reconnected connectionCount] == $attempt} "debugDisconnect lost connectionCount"
    assert {[dict get $reconnected lastCloseReason] eq "DebugDisconnect"} "debugDisconnect lost lastCloseReason"
    assert {[dict get $reconnected maxObservedTimestamp] eq $previousTimestamp} "debugDisconnect lost maxObservedTimestamp"
    assert {[dict get [::convex::state $::adapter::client] reconnectDelay] == 100} "healthy reconnect did not reset backoff"
    set afterHydration [llength $::adapterLines]
    quiet_for 40
    assert {[llength $::adapterLines] == $afterHydration} "unchanged reconnect hydration crossed debug acknowledgement"
    set updateVersion [::livefixture::update $attempt]
    wait_for {[llength $::adapterLines] > $afterHydration} "external update after reconnect $attempt was not delivered"
    set valueEnvelope [::convex::decode [lindex $::adapterLines $afterHydration]]
    assert {[dict get $valueEnvelope type] eq "subscription" && [dict get $valueEnvelope subscriptionId] eq "same" && [dict get [dict get $valueEnvelope value] count] == $attempt} "reconnect delivered the wrong subscription value"
    set expectedValue $attempt
}

# QueryFailed is a structured FunctionError and the same subscription recovers.
set before [llength $::adapterLines]
::livefixture::query_failed "fixture function failure"
wait_for {[llength $::adapterLines] > $before} "real QueryFailed emitted no adapter envelope"
set functionError [lindex $::adapterLines $before]
assert {$functionError eq {{"type":"subscription","subscriptionId":"same","error":{"name":"FunctionError","message":"fixture function failure","data":{"code":"FIXTURE"}},"logs":["fixture failure log"]}}} "FunctionError subscription envelope serialization changed"
set before [llength $::adapterLines]
::livefixture::update 6
wait_for {[llength $::adapterLines] > $before} "subscription did not recover after QueryFailed"
assert {[dict get [dict get [::convex::decode [lindex $::adapterLines $before]] value] count] == 6} "QueryFailed recovery value was wrong"

# Missing errorData stays omitted rather than becoming data:null, while the
# valid FunctionError still leaves the same subscription live.
set before [llength $::adapterLines]
::livefixture::query_failed_without_data "fixture without data"
wait_for {[llength $::adapterLines] > $before} "QueryFailed without data emitted no adapter envelope"
assert {[lindex $::adapterLines $before] eq {{"type":"subscription","subscriptionId":"same","error":{"name":"FunctionError","message":"fixture without data"}}}} "QueryFailed without data changed its exact envelope"
set before [llength $::adapterLines]
::livefixture::update 7
wait_for {[llength $::adapterLines] > $before} "subscription did not recover after omitted errorData"
assert {[dict get [dict get [::convex::decode [lindex $::adapterLines $before]] value] count] == 7} "omitted errorData recovery value was wrong"

# Each malformed wire field is a structured ProtocolError, never a value or
# FunctionError. Reconnect must replay Add and deliver a later valid value.
assert_malformed_live_recovery ::livefixture::malformed_version \
    "state version querySet must be a JSON uint32 integer" 7 6 8
assert_malformed_live_recovery ::livefixture::malformed_query_id \
    "Live queryId must be a JSON uint32 integer" 8 7 9
assert_malformed_live_recovery ::livefixture::malformed_query_failed \
    "QueryFailed.errorMessage must be a JSON string" 9 8 10

# A malformed real server frame must cross the adapter as ProtocolError, then
# reconnect and publish a later value on the same subscription.
set before [llength $::adapterLines]
::livefixture::protocol_error
wait_for {[llength $::adapterLines] > $before} "real socket ProtocolError emitted no adapter envelope"
set protocolEnvelope [::convex::decode [lindex $::adapterLines $before]]
assert {[dict get $protocolEnvelope type] eq "subscription" && [dict get $protocolEnvelope subscriptionId] eq "same"} "ProtocolError lost subscription identity"
assert {[dict get [dict get $protocolEnvelope error] name] eq "ProtocolError"} "real socket error was not ProtocolError"
wait_for {[::livefixture::connections] == 10} "ProtocolError did not reconnect"
wait_for {[llength [modification_records 9 Add]] == 1} "ProtocolError reconnect did not resend Add"
wait_for {[dict get [::convex::state $::adapter::client] remote] eq [::livefixture::active_remote]} "ProtocolError reconnect did not hydrate"
set before [llength $::adapterLines]
::livefixture::update 11
wait_for {[llength $::adapterLines] > $before} "ProtocolError recovery value was not emitted"
assert {[dict get [dict get [::convex::decode [lindex $::adapterLines $before]] value] count] == 11} "ProtocolError stranded the subscription"

# Closing the actual peer must produce TransportError, reconnect, and recover.
set before [llength $::adapterLines]
::livefixture::transport_error
wait_for {[llength $::adapterLines] > $before} "real socket TransportError emitted no adapter envelope"
set transportEnvelope [::convex::decode [lindex $::adapterLines $before]]
assert {[dict get [dict get $transportEnvelope error] name] eq "TransportError"} "peer close was not TransportError"
wait_for {[::livefixture::connections] == 11} "TransportError did not reconnect"
wait_for {[llength [modification_records 10 Add]] == 1} "TransportError reconnect did not resend Add"
wait_for {[dict get [::convex::state $::adapter::client] remote] eq [::livefixture::active_remote]} "TransportError reconnect did not hydrate"
set before [llength $::adapterLines]
::livefixture::update 12
wait_for {[llength $::adapterLines] > $before} "TransportError recovery value was not emitted"
assert {[dict get [dict get [::convex::decode [lindex $::adapterLines $before]] value] count] == 12} "TransportError stranded the subscription"
set finalState [::convex::state $::adapter::client]
assert {[dict get $finalState connectionCount] == 10} "real reconnect count did not include protocol and transport retirements"
assert {[dict get $finalState lastCloseReason] eq "TransportError: peer closed"} "final close reason was not retained"
assert {[dict get $finalState reconnectDelay] == 100} "healthy transport recovery kept stale backoff"

# A peer that sends only a frame prefix must be abandoned on a deterministic
# deadline. The retained subscription reconnects, resends Add, suppresses its
# unchanged hydration, and publishes the next valid value.
set savedPartialTimeout $::convex::partialFrameTimeoutMs
set ::convex::partialFrameTimeoutMs 300
set before [llength $::adapterLines]
set timeoutStarted [clock milliseconds]
::livefixture::stall_partial_frame
wait_for {[dict get [::convex::state $::adapter::client] wsFrameTimer] ne ""} "partial frame did not arm its deadline"
wait_for {[llength $::adapterLines] > $before} "partial-frame timeout emitted no adapter envelope" 1500
set timeoutElapsed [expr {[clock milliseconds] - $timeoutStarted}]
assert {$timeoutElapsed >= 250 && $timeoutElapsed < 1200} "partial-frame deadline fired at ${timeoutElapsed}ms"
set timeoutEnvelope [::convex::decode [lindex $::adapterLines $before]]
assert {[dict get [dict get $timeoutEnvelope error] name] eq "TransportError"} "partial-frame timeout was not TransportError"
wait_for {[::livefixture::connections] == 12} "partial-frame timeout did not reconnect"
wait_for {[llength [modification_records 11 Add]] == 1} "partial-frame reconnect did not resend Add"
wait_for {[dict get [::convex::state $::adapter::client] remote] eq [::livefixture::active_remote]} "partial-frame reconnect did not hydrate"
set before [llength $::adapterLines]
::livefixture::update 13
wait_for {[llength $::adapterLines] > $before} "partial-frame recovery value was not emitted"
assert {[dict get [dict get [::convex::decode [lindex $::adapterLines $before]] value] count] == 13} "partial-frame timeout stranded the subscription"

# Unsubscribe and close are controller operations, so neither may wait for a
# half-frame owned by the reader. The timer is still armed when both return.
::livefixture::stall_partial_frame
wait_for {[dict get [::convex::state $::adapter::client] wsFrameTimer] ne ""} "bounded-operation frame did not arm its deadline"
set before [llength $::adapterLines]
set unsubscribeStarted [clock milliseconds]
::adapter::handle {{"id":"unsubscribe-partial","op":"unsubscribe","subscriptionId":"same"}}
wait_for {[llength $::adapterLines] > $before} "unsubscribe behind partial frame emitted no acknowledgement"
set unsubscribeElapsed [expr {[clock milliseconds] - $unsubscribeStarted}]
assert {$unsubscribeElapsed < 200} "unsubscribe waited ${unsubscribeElapsed}ms for a partial frame"
assert {[lindex $::adapterLines $before] eq {{"id":"unsubscribe-partial","type":"ack"}}} "partial-frame unsubscribe acknowledgement changed"
wait_for {[llength [modification_records 11 Remove]] == 1} "partial-frame unsubscribe did not send Remove"
set ::convex::partialFrameTimeoutMs $savedPartialTimeout

proc adapter_test_exit {status} { set ::adapterExitStatus $status; ::livefixture::signal }
set ::adapter::exitHook adapter_test_exit
set ::adapterExitStatus ""
set before [llength $::adapterLines]
set closeStarted [clock milliseconds]
::adapter::handle {{"id":"close","op":"close"}}
wait_for {[llength $::adapterLines] > $before && $::adapterExitStatus ne ""} "close envelope did not drain"
set closeElapsed [expr {[clock milliseconds] - $closeStarted}]
assert {$closeElapsed < 200} "close waited ${closeElapsed}ms for a partial frame"
assert {[lindex $::adapterLines $before] eq {{"id":"close","type":"closed"}}} "close envelope serialization changed"
assert {$::adapterExitStatus == 0} "cooperative close did not exit successfully"
assert {[dict get [::convex::state $::adapter::client] wsFrameTimer] eq ""} "close retained the partial-frame timer"
fileevent $adapterRead readable {}
close $adapterRead
close $adapterWrite
::livefixture::stop
unset ::env(CONVEX_URL)
puts "Tcl real WebSocket and adapter envelope tests passed"
