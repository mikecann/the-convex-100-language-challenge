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
proc live_test_callback {kind payload logs} { lappend ::liveTestEvents $kind }
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
assert {$liveTestEvents eq {value error value}} "QueryFailed did not recover on the same Live subscription"
::convex::retire $liveClient deterministic-test 1
assert {[dict get [::convex::state $liveClient] reconnectTimer] ne ""} "transport retirement did not schedule reconnect"
::convex::close $liveClient
assert {[dict get [::convex::state $liveClient] reconnectTimer] eq ""} "close did not clear the cancelled reconnect timer"
puts "Tcl client unit tests passed"
