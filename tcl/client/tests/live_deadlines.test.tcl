#!/usr/local/bin/tclsh
# Absolute transport deadlines and pre-allocation frame limits, against a real
# loopback peer and a real stalled channel. A peer that keeps trickling bytes is
# the interesting case: an idle timer would be reset by every byte and would
# never fire, so each deadline here starts when the incomplete work starts.
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]
source [file normalize [file join [file dirname [info script]] live_fixture.tcl]]

proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

proc wait_for {condition message {timeoutMs 5000}} {
    set ::testTimedOut 0
    set timer [after $timeoutMs { set ::testTimedOut 1; ::livefixture::signal }]
    while {![uplevel 1 [list expr $condition]] && !$::testTimedOut} {
        vwait ::livefixture::notice
    }
    after cancel $timer
    if {$::testTimedOut} { error "$message (timed out after $timeoutMs ms)" }
}

proc deadline_callback {kind payload logs} {
    lappend ::deadlineEvents [list $kind $payload]
    ::livefixture::signal
}

proc event_kind {index} { return [lindex [lindex $::deadlineEvents $index] 0] }
proc event_field {index name} {
    return [::convex::decode [::convex::field [lindex [lindex $::deadlineEvents $index] 1] $name]]
}

set savedConnectDeadline $::convex::connectDeadlineMs
set savedPartialTimeout $::convex::partialFrameTimeoutMs
set savedWriteDeadline $::convex::writeDeadlineMs

# A peer that accepts the connection and then answers the upgrade one byte at a
# time never completes a handshake and never stops making progress.
set ::convex::connectDeadlineMs 400
set port [::livefixture::start]
set ::livefixture::handshakeMode dribble
set ::deadlineEvents {}
set handshakeClient [::convex::new "http://127.0.0.1:$port"]
set handshakeStarted [clock milliseconds]
::convex::subscribe $handshakeClient demo:state {{}} [list deadline_callback]
wait_for {[llength $::deadlineEvents] > 0} "the dribbled upgrade was never abandoned"
set handshakeElapsed [expr {[clock milliseconds] - $handshakeStarted}]
assert {$handshakeElapsed >= 350 && $handshakeElapsed < 3000} "the connect deadline fired at ${handshakeElapsed}ms"
assert {$::livefixture::sentByteCount >= 5} "the fixture stopped dribbling before the connect deadline"
assert {[event_kind 0] eq "error"} "the dribbled upgrade did not reach the subscription"
assert {[event_field 0 name] eq "TransportError"} "the connect deadline was not a TransportError"
assert {[string match {*handshake deadline*} [event_field 0 message]]} "the connect deadline lost its reason"
::convex::close $handshakeClient
::livefixture::stop
set ::convex::connectDeadlineMs $savedConnectDeadline

# A frame whose payload arrives one byte at a time keeps the parser's state
# valid, so only an absolute deadline can end it.
set ::convex::partialFrameTimeoutMs 300
set port [::livefixture::start]
set ::deadlineEvents {}
set dribbleClient [::convex::new "http://127.0.0.1:$port"]
::convex::subscribe $dribbleClient demo:state {{}} [list deadline_callback]
wait_for {[llength $::deadlineEvents] == 1} "the dribble subscription did not hydrate"
assert {[event_kind 0] eq "value"} "the dribble subscription did not receive its initial value"
set ::livefixture::sentByteCount 0
set dribbleStarted [clock milliseconds]
::livefixture::dribble_frame 25
wait_for {[llength $::deadlineEvents] > 1} "the dribbled frame was never abandoned"
set dribbleElapsed [expr {[clock milliseconds] - $dribbleStarted}]
assert {$dribbleElapsed >= 250 && $dribbleElapsed < 2500} "the partial-frame deadline fired at ${dribbleElapsed}ms"
assert {$::livefixture::sentByteCount >= 6} "the fixture stopped dribbling before the partial-frame deadline"
assert {[event_field 1 name] eq "TransportError"} "the partial-frame deadline was not a TransportError"
assert {[string match {*partial WebSocket frame*} [event_field 1 message]]} "the partial-frame deadline lost its reason"
::convex::close $dribbleClient
::livefixture::stop
set ::convex::partialFrameTimeoutMs $savedPartialTimeout

# A 64-bit length header that announces 8 MiB, with no payload behind it. The
# limit is judged from the header, so the fixture never has to send the bytes.
set port [::livefixture::start]
set ::deadlineEvents {}
set oversizedClient [::convex::new "http://127.0.0.1:$port"]
::convex::subscribe $oversizedClient demo:state {{}} [list deadline_callback]
wait_for {[llength $::deadlineEvents] == 1} "the oversized-frame subscription did not hydrate"
set ::livefixture::sentByteCount 0
::livefixture::oversized_frame_header
wait_for {[llength $::deadlineEvents] > 1} "the oversized frame header was not rejected"
assert {$::livefixture::sentByteCount == 10} \
    "the client waited for payload bytes: the fixture sent $::livefixture::sentByteCount"
assert {[event_field 1 name] eq "ProtocolError"} "the oversized frame was not a ProtocolError"
assert {[string match {*frame exceeds*} [event_field 1 message]]} "the oversized frame lost its reason"
::convex::close $oversizedClient
::livefixture::stop

# A peer that stops reading leaves accepted bytes in Tcl's channel queue. A real
# pipe with no reader reproduces that exactly, with no fabricated channel error.
set ::convex::writeDeadlineMs 30000
lassign [chan pipe] blockedRead blockedWrite
fconfigure $blockedRead -blocking 0 -buffering none -translation binary -encoding binary
fconfigure $blockedWrite -blocking 0 -buffering none -translation binary -encoding binary
set ::deadlineEvents {}
set writeClient [::convex::new http://127.0.0.1:1]
::convex::put $writeClient subscriptions \
    [dict create 0 [dict create path demo:state args {{}} callback deadline_callback active 1 last ""]]
::convex::put $writeClient socket $blockedWrite
::convex::put $writeClient wsStage open
set blob [::convex::quote [string repeat x [expr {48 * 1024}]]]
for {set index 0} {$index < 8 && [chan pending output $blockedWrite] == 0} {incr index} {
    ::convex::send $writeClient [::convex::object [list type [::convex::quote Filler] blob $blob]]
}
assert {[chan pending output $blockedWrite] > 0} "the stopped reader left no bytes in Tcl's channel queue"
assert {[dict get [::convex::state $writeClient] wsWriteTimer] ne ""} "pending output did not arm the write deadline"
# Re-arm with a short deadline from a known instant. Filling the pipe takes an
# unpredictable amount of time, and the assertion below is about the deadline,
# not about how long the fill took.
after cancel [dict get [::convex::state $writeClient] wsWriteTimer]
::convex::put $writeClient wsWriteTimer ""
set ::convex::writeDeadlineMs 300
set writeStarted [clock milliseconds]
::convex::ws_sync_write_watch $writeClient $blockedWrite
assert {[dict get [::convex::state $writeClient] wsWriteTimer] ne ""} "the write deadline was not re-armed"
wait_for {[llength $::deadlineEvents] > 0} "the stalled write was never abandoned"
set writeElapsed [expr {[clock milliseconds] - $writeStarted}]
assert {$writeElapsed >= 250 && $writeElapsed < 2500} "the write deadline fired at ${writeElapsed}ms"
assert {[event_field 0 name] eq "TransportError"} "the write deadline was not a TransportError"
assert {[string match {*write deadline*} [event_field 0 message]]} "the write deadline lost its reason"
assert {[dict get [::convex::state $writeClient] socket] eq ""} "the stalled socket was not retired"
::convex::close $writeClient
catch {close $blockedWrite}
close $blockedRead
set ::convex::writeDeadlineMs $savedWriteDeadline
puts "Tcl absolute transport deadline and frame limit tests passed"
