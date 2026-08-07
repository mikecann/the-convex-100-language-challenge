#!/usr/local/bin/tclsh
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]

proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }

# TLS chain and hostname verification live in tls.test.tcl, which exercises the
# same policy against real handshakes instead of captured arguments.
set nested {"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],"number":42.5,"nil":null}}
set raw "\{$nested\}"
assert {[::convex::field $raw unicode] eq {"Hello, 世界 👋"}} "raw string field was not retained"
set nestedRaw [::convex::field $raw nested]
assert {[dict get [::convex::decode $nestedRaw] number] == 42.5} "nested field was not retained"
assert {[llength [::convex::elements {[1,{"x":true},null]}]] == 3} "array splitter lost an element"
assert {[::convex::timestamp_key AAAAAAAAAAA=] eq 0000000000000000} "little-endian zero timestamp failed"
assert {[::convex::timestamp_key AQAAAAAAAAA=] eq 0000000000000001} "little-endian timestamp ordering failed"
assert {[string compare [::convex::timestamp_key /wAAAAAAAAA=] [::convex::timestamp_key AAEAAAAAAAA=]] < 0} "numeric timestamp ordering failed at 255 -> 256"
set frame [::convex::ws_frame 1 [encoding convertto utf-8 {Hello, 世界 👋}]]
assert {[string bytelength $frame] > 10} "masked WebSocket frame was not built"

# Exercise the Live state machine's failure recovery without a network fixture.
# The same transition decoder is fed the exact wire-shaped envelopes used by
# the socket reader, proving that QueryFailed does not strand the subscription.
proc live_test_callback {kind payload logs} { lappend ::liveTestEvents [list $kind $payload] }
set liveTestEvents {}
set liveClient [::convex::new http://127.0.0.1]
::convex::put $liveClient subscriptions [dict create 0 [dict create path demo:state args {} callback live_test_callback active 1 last {}]]
set version0 {"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="}
set version1 {"querySet":0,"identity":0,"ts":"AQAAAAAAAAA="}
set version2 {"querySet":0,"identity":0,"ts":"AgAAAAAAAAA="}
set update0 [format {{"type":"Transition","startVersion":{%s},"endVersion":{%s},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":0.0}}]}} $version0 $version1]
set failure [format {{"type":"Transition","startVersion":{%s},"endVersion":{%s},"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":"fixture failure"}]}} $version1 $version2]
::convex::handle_live_message $liveClient $update0
::convex::handle_live_message $liveClient $failure
set version3 {"querySet":0,"identity":0,"ts":"AwAAAAAAAAA="}
set update1 [format {{"type":"Transition","startVersion":{%s},"endVersion":{%s},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":1.0}}]}} $version2 $version3]
::convex::handle_live_message $liveClient $update1
assert {[lmap event $liveTestEvents {lindex $event 0}] eq {value error value}} "QueryFailed did not recover on the same Live subscription"
# Transport and parser failures are structured subscription errors. The client
# retains the subscription and can still publish the next valid transition.
::convex::retire $liveClient "ProtocolError: fixture parser" 0
set protocolError [lindex $liveTestEvents end]
assert {[lindex $protocolError 0] eq "error"} "ProtocolError was not delivered to the subscription"
assert {[dict get [::convex::decode [lindex $protocolError 1]] name] eq "ProtocolError"} "ProtocolError was not structured"
set version4 {"querySet":0,"identity":0,"ts":"BAAAAAAAAAA="}
set update2 [format {{"type":"Transition","startVersion":{%s},"endVersion":{%s},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":2.0}}]}} $version3 $version4]
::convex::handle_live_message $liveClient $update2
::convex::retire $liveClient "TransportError: fixture peer closed" 0
set transportError [lindex $liveTestEvents end]
assert {[lindex $transportError 0] eq "error"} "TransportError was not delivered to the subscription"
assert {[dict get [::convex::decode [lindex $transportError 1]] name] eq "TransportError"} "TransportError was not structured"
set version5 {"querySet":0,"identity":0,"ts":"BQAAAAAAAAA="}
set update3 [format {{"type":"Transition","startVersion":{%s},"endVersion":{%s},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":3.0}}]}} $version4 $version5]
::convex::handle_live_message $liveClient $update3
assert {[lmap event $liveTestEvents {lindex $event 0}] eq {value error value error value error value}} "Live error recovery did not retain the subscription"
::convex::retire $liveClient deterministic-test 1
assert {[dict get [::convex::state $liveClient] reconnectTimer] ne ""} "transport retirement did not schedule reconnect"
::convex::close $liveClient
assert {[dict get [::convex::state $liveClient] reconnectTimer] eq ""} "close did not clear the cancelled reconnect timer"

# Live protocol counters are JSON uint32 integers, not merely Tcl values that
# happen to compare numerically. Exercise both boundaries and every token shape
# that json2dict would otherwise blur together.
set maximumVersion {{"querySet":4294967295,"identity":4294967295,"ts":"AAAAAAAAAAA="}}
assert {[::convex::normalize_version $maximumVersion] eq $maximumVersion} "uint32 maximum state version was not retained"
set zeroVersion {{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="}}
assert {[::convex::normalize_version $zeroVersion] eq $zeroVersion} "uint32 zero state version was not retained"
set invalidCounters [list {"0"} true false null 1.5 -1 4294967296]
foreach fieldName {querySet identity} {
    foreach token $invalidCounters {
        set querySet 0
        set identity 0
        if {$fieldName eq "querySet"} { set querySet $token } else { set identity $token }
        set raw [format {{"querySet":%s,"identity":%s,"ts":"AAAAAAAAAAA="}} $querySet $identity]
        set failed [catch {::convex::normalize_version $raw} problem]
        assert {$failed && $problem eq "state version $fieldName must be a JSON uint32 integer"} \
            "state version accepted invalid $fieldName token $token: $problem"
    }
}

proc validation_callback {kind payload logs} {
    lappend ::validationEvents [list $kind $payload $logs]
}

proc assert_live_rollback {client raw expected} {
    set before [::convex::state $client]
    set eventCount [llength $::validationEvents]
    set failed [catch {::convex::handle_live_message $client $raw} problem]
    assert {$failed} "malformed Live transition was accepted"
    assert {$problem eq $expected} "malformed Live transition changed its error: actual=$problem expected=$expected"
    set after [::convex::state $client]
    assert {[dict get $after remote] eq [dict get $before remote]} "malformed Live transition committed its version"
    assert {[dict get $after maxTimestamp] eq [dict get $before maxTimestamp]} "malformed Live transition committed its timestamp"
    assert {[dict get $after subscriptions] eq [dict get $before subscriptions]} "malformed Live transition committed a query update"
    assert {[llength $::validationEvents] == $eventCount} "malformed Live transition published a callback"
}

set validationClient [::convex::new http://127.0.0.1]
::convex::put $validationClient subscriptions [dict create 0 [dict create path demo:state args {} callback validation_callback active 1 last {}]]
set validationEvents {}
set validationStart {{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="}}
set validationEnd1 {{"querySet":0,"identity":0,"ts":"AQAAAAAAAAA="}}

# Invalid version fields roll back the entire transition, including otherwise
# valid query updates.
set invalidVersionEnd {{"querySet":"0","identity":0,"ts":"AQAAAAAAAAA="}}
set invalidVersionTransition [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":10}}]}} $validationStart $invalidVersionEnd]
assert_live_rollback $validationClient $invalidVersionTransition "state version querySet must be a JSON uint32 integer"
set invalidIdentityEnd {{"querySet":0,"identity":4294967296,"ts":"AQAAAAAAAAA="}}
set invalidIdentityTransition [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":10}}]}} $validationStart $invalidIdentityEnd]
assert_live_rollback $validationClient $invalidIdentityTransition "state version identity must be a JSON uint32 integer"

# Every malformed queryId form is rejected before subscription lookup, version
# commit, or value publication. Zero and uint32 max remain valid boundaries.
foreach token $invalidCounters {
    set transition [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryUpdated","queryId":%s,"value":{"count":11}}]}} $validationStart $validationEnd1 $token]
    assert_live_rollback $validationClient $transition "Live queryId must be a JSON uint32 integer"
}
set missingQueryId [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryUpdated","value":{"count":11}}]}} $validationStart $validationEnd1]
assert_live_rollback $validationClient $missingQueryId "Live queryId must be a JSON uint32 integer"
set maxQueryTransition [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryUpdated","queryId":4294967295,"value":{"count":12}}]}} $validationStart $validationEnd1]
::convex::handle_live_message $validationClient $maxQueryTransition
assert {[dict get [::convex::state $validationClient] remote] eq $validationEnd1} "uint32 maximum queryId was rejected"
assert {[llength $validationEvents] == 0} "unknown maximum queryId published a callback"

# Reset the isolated state, then reject every non-string QueryFailed message
# atomically. A valid nested errorData subtree is preserved byte-for-byte, an
# absent one stays absent, and a later value still reaches the subscription.
::convex::put $validationClient remote $validationStart
::convex::put $validationClient maxTimestamp ""
foreach messageToken [list 7 true false null 1.5 {{"nested":true}} {["array"]}] {
    set transition [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":%s}]}} $validationStart $validationEnd1 $messageToken]
    assert_live_rollback $validationClient $transition "QueryFailed.errorMessage must be a JSON string"
}
set missingMessage [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryFailed","queryId":0}]}} $validationStart $validationEnd1]
assert_live_rollback $validationClient $missingMessage "QueryFailed.errorMessage must be a JSON string"
set unknownMalformedMessage [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryFailed","queryId":4294967295,"errorMessage":7}]}} $validationStart $validationEnd1]
assert_live_rollback $validationClient $unknownMalformedMessage "QueryFailed.errorMessage must be a JSON string"
set nestedData {{"code":"NESTED","details":[1,{"ok":true}],"nullable":null}}
set nestedFailure [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":"nested failure","errorData":%s}]}} $validationStart $validationEnd1 $nestedData]
::convex::handle_live_message $validationClient $nestedFailure
set nestedError [lindex $validationEvents 0]
assert {[lindex $nestedError 0] eq "error"} "valid QueryFailed did not publish FunctionError"
assert {[::convex::field [lindex $nestedError 1] data] eq $nestedData} "QueryFailed errorData shape changed"
set validationEnd2 {{"querySet":0,"identity":0,"ts":"AgAAAAAAAAA="}}
set omittedFailure [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryFailed","queryId":0,"errorMessage":"without data"}]}} $validationEnd1 $validationEnd2]
::convex::handle_live_message $validationClient $omittedFailure
assert {[::convex::field [lindex [lindex $validationEvents 1] 1] data 0] eq ""} "absent QueryFailed errorData became data:null"
set validationEnd3 {{"querySet":0,"identity":0,"ts":"AwAAAAAAAAA="}}
set recoveredUpdate [format {{"type":"Transition","startVersion":%s,"endVersion":%s,"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":13}}]}} $validationEnd2 $validationEnd3]
::convex::handle_live_message $validationClient $recoveredUpdate
assert {[lmap event $validationEvents {lindex $event 0}] eq {error error value}} "valid QueryFailed sequence did not recover"
::convex::close $validationClient

# Import the test-only adapter without running its stdin/TCP event loop. This
# lets the ordering and budget tests exercise the exact queue implementation.
set ::env(ADAPTER_TEST_ONLY) 1
source [file normalize [file join [file dirname [info script]] conformance adapter.tcl]]
unset ::env(ADAPTER_TEST_ONLY)
lassign [chan pipe] adapterRead adapterWrite
fconfigure $adapterRead -blocking 0 -buffering none -translation binary -encoding binary
fconfigure $adapterWrite -blocking 0 -buffering none -translation binary -encoding binary
set ::adapter::output $adapterWrite
set ::adapter::queue {}
set ::adapter::queueBytes 0
set ::adapter::subscriptions [dict create same 7]
set ::adapter::generations [dict create same 1]

# Pause after dequeue, invalidate the generation, then publish the operation
# acknowledgement. The old delivery must not cross that acknowledgement. This
# is the exact barrier used by unsubscribe and same-ID replacement.
proc adapter_invalidate_then_ack {} {
    ::adapter::invalidate_subscription same
    ::adapter::emit {{"id":"replace","type":"ack"}}
}
set ::adapter::pauseAfterDequeue adapter_invalidate_then_ack
::adapter::emit {{"type":"subscription","subscriptionId":"same","value":{"count":99}}} 1 [list same 1]
assert {[llength $::adapter::queue] == 0} "paused stale delivery stayed queued"
set barrierTranscript [::read $adapterRead]
assert {[string first {{"id":"replace","type":"ack"}} $barrierTranscript] == 0} "replacement acknowledgement was not delivered"
assert {[string first {"count":99} $barrierTranscript] < 0} "stale delivery crossed replacement acknowledgement"

set ::adapter::subscriptions [dict create same 8]
set ::adapter::generations [dict create same 2]
::adapter::emit {{"type":"subscription","subscriptionId":"same","value":{"count":98}}} 1 [list same 1]
assert {[::read $adapterRead] eq ""} "same-ID replacement admitted an old generation"

# A delivery cannot consume the reserved control headroom. The cost includes
# the newline plus conservative Tcl/channel bookkeeping, not just JSON bytes.
set ::adapter::maxBytes 8192
set ::adapter::controlReserve 2048
set ::adapter::entryOverhead 512
set ::adapter::channelOverhead 1024
set oversized [string repeat x 5000]
::adapter::emit $oversized 1 [list same 2]
assert {$::adapter::queueBytes == 0} "oversized delivery consumed control reserve"
assert {[::adapter::entry_cost x] == 1538} "adapter byte cost omitted newline or overhead"
::adapter::subscription_error same 2 ProtocolError "fixture protocol" null
set adapterError [::read $adapterRead]
assert {[string first {"name":"ProtocolError"} $adapterError] >= 0} "adapter did not serialize structured subscription ProtocolError"

# Accepted deliveries can consume neither the count slots nor bytes reserved
# for controller responses. The real stopped-reader process test below the unit
# layer exercises the same limits against an OS channel and measures RSS.
set ::adapter::maxEvents 8
set ::adapter::controlReserveEvents 3
set ::adapter::maxBytes [expr {1024 * 1024}]
set ::adapter::pendingOutputHook {expr {1}}
set ::adapter::queue {}
set ::adapter::queueBytes 0
for {set index 0} {$index < 6} {incr index} {
    ::adapter::emit [format {{"type":"subscription","subscriptionId":"same","value":{"count":%d}}} $index] 1 [list same 2]
}
assert {[llength $::adapter::queue] == 5} "delivery events consumed reserved count slots"
foreach id {unsubscribe replace close} {
    ::adapter::emit [format {{"id":"%s","type":"ack"}} $id]
}
assert {[llength $::adapter::queue] == 8} "accepted deliveries prevented reserved control events"
foreach id {unsubscribe replace close} {
    assert {[string first [format {"id":"%s"} $id] $::adapter::queue] >= 0} "reserved control event $id was lost"
}
set ::adapter::pendingOutputHook ""
set ::adapter::queue {}
set ::adapter::queueBytes 0
::read $adapterRead

# A value already accepted by Tcl's channel cannot be unsent, so it stays ahead
# of the terminal response. finish_close writes and observes the closed event
# before termination rather than merely registering a future writable callback.
proc adapter_close_exit {status} { set ::adapterCloseStatus $status }
set acceptedRaw "{\"type\":\"subscription\",\"subscriptionId\":\"same\",\"value\":{\"count\":7}}\n"
puts -nonewline $adapterWrite $acceptedRaw
::flush $adapterWrite
set closedRaw {{"id":"close","type":"closed"}}
set acceptedCost [::adapter::entry_cost [string trimright $acceptedRaw "\n"]]
set closedCost [::adapter::entry_cost $closedRaw]
set ::adapter::queue [list [list $acceptedRaw 1 [list same 2] accepted $acceptedCost] [list "$closedRaw\n" 0 "" queued $closedCost]]
set ::adapter::queueBytes [expr {$acceptedCost + $closedCost}]
set ::adapter::closeDeadline [expr {[clock milliseconds] + 1000}]
set ::adapter::exitHook adapter_close_exit
set ::adapterCloseStatus ""
::adapter::finish_close
set closeTranscript [::read $adapterRead]
assert {$::adapterCloseStatus == 0} "close did not complete after writing its response"
assert {[string first $acceptedRaw $closeTranscript] == 0} "accepted stale value was not ordered before close"
assert {[string first "$closedRaw\n" $closeTranscript] > 0} "close response was not written before termination"

# A reader may stop after Tcl accepted the close response. The adapter records
# that acceptance, then fails within its deadline instead of hanging forever.
set ::adapter::queue [list [list "$closedRaw\n" 0 "" queued $closedCost]]
set ::adapter::queueBytes $closedCost
set ::adapter::pendingOutputHook {expr {1}}
set ::adapter::closeDeadline [expr {[clock milliseconds] + 1000}]
set ::adapterCloseStatus ""
::adapter::flush
assert {[lindex [lindex $::adapter::queue 0] 3] eq "accepted"} "close response was not accepted before backpressure"
set ::adapter::closeDeadline [expr {[clock milliseconds] - 1}]
::adapter::finish_close
assert {$::adapterCloseStatus == 1} "stalled close did not fail within its deadline"
set ::adapter::pendingOutputHook ""
set ::adapter::exitHook ""
close $adapterRead
close $adapterWrite
puts "Tcl client unit tests passed"
