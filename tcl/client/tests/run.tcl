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
puts "Tcl client unit tests passed"
