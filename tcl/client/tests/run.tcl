#!/usr/local/bin/tclsh
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]

proc assert {condition message} { if {![uplevel 1 [list expr $condition]]} { error $message } }

set nested {"unicode":"Hello, 世界 👋","nested":{"booleans":[true,false],"number":42.5,"nil":null}}
set raw "\{$nested\}"
assert {[::convex::field $raw unicode] eq {"Hello, 世界 👋"}} "raw string field was not retained"
set nestedRaw [::convex::field $raw nested]
assert {[dict get [::convex::decode $nestedRaw] number] == 42.5} "nested field was not retained"
assert {[llength [::convex::elements {[1,{"x":true},null]}]] == 3} "array splitter lost an element"
assert {[::convex::timestamp_key AAAAAAAAAAA=] eq 0000000000000000} "little-endian zero timestamp failed"
assert {[::convex::timestamp_key AQAAAAAAAAA=] eq 0000000000000001} "little-endian timestamp ordering failed"
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
    ::adapter::emit {"id":"replace","type":"ack"}
}
set ::adapter::pauseAfterDequeue adapter_invalidate_then_ack
::adapter::emit {"type":"subscription","subscriptionId":"same","value":{"count":99}} 1 [list same 1]
assert {[llength $::adapter::queue] == 0} "paused stale delivery stayed queued"
set barrierTranscript [::read $adapterRead]
assert {[string first {"id":"replace","type":"ack"} $barrierTranscript] == 0} "replacement acknowledgement was not delivered"
assert {[string first {"count":99} $barrierTranscript] < 0} "stale delivery crossed replacement acknowledgement"

set ::adapter::subscriptions [dict create same 8]
set ::adapter::generations [dict create same 2]
::adapter::emit {"type":"subscription","subscriptionId":"same","value":{"count":98}} 1 [list same 1]
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

# A value already accepted by Tcl's channel cannot be unsent, so it stays ahead
# of the terminal response. finish_close writes and observes the closed event
# before termination rather than merely registering a future writable callback.
proc adapter_close_exit {status} { set ::adapterCloseStatus $status }
set acceptedRaw "{\"type\":\"subscription\",\"subscriptionId\":\"same\",\"value\":{\"count\":7}}\n"
puts -nonewline $adapterWrite $acceptedRaw
::flush $adapterWrite
set closedRaw {"id":"close","type":"closed"}
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
