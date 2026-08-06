#!/usr/local/bin/tclsh
source [file normalize [file join [file dirname [info script]] .. convex.tcl]]
source [file normalize [file join [file dirname [info script]] live_fixture.tcl]]

proc assert {condition message} {
    if {![uplevel 1 [list expr $condition]]} { error $message }
}

proc wait_for {condition message {timeoutMs 5000}} {
    set ::pressureTimedOut 0
    set timer [after $timeoutMs { set ::pressureTimedOut 1; ::livefixture::signal }]
    while {![uplevel 1 [list expr $condition]] && !$::pressureTimedOut} {
        vwait ::livefixture::notice
    }
    after cancel $timer
    if {$::pressureTimedOut} { error "$message (timed out after $timeoutMs ms)" }
}

proc wait_interval {milliseconds} {
    set ::pressureIntervalDone 0
    after $milliseconds { set ::pressureIntervalDone 1; ::livefixture::signal }
    wait_for {$::pressureIntervalDone} "pressure interval did not finish" [expr {$milliseconds + 1000}]
}

proc pressure_output {} {
    append ::pressureBuffer [read $::pressureController]
    while {[set newline [string first "\n" $::pressureBuffer]] >= 0} {
        lappend ::pressureLines [string range $::pressureBuffer 0 [expr {$newline - 1}]]
        set ::pressureBuffer [string range $::pressureBuffer [expr {$newline + 1}] end]
    }
    ::livefixture::signal
}

proc resident_kib {pid} {
    set stream [open "/proc/$pid/status" r]
    try {
        set status [read $stream]
    } finally {
        close $stream
    }
    if {![regexp -line {^VmRSS:[ \t]+([0-9]+)[ \t]+kB$} $status -> amount]} {
        error "adapter process status omitted VmRSS"
    }
    return $amount
}

proc schedule_exit_check {pid} {
    if {![file exists "/proc/$pid/status"]} {
        set ::pressureExited 1
        ::livefixture::signal
        return
    }
    # The parent intentionally keeps the unread pipe open. Linux therefore
    # retains the exited child as a zombie until Tcl's close reaps it, so
    # disappearance from /proc alone cannot be the completion signal.
    set stream [open "/proc/$pid/status" r]
    try {
        set status [read $stream]
    } finally {
        close $stream
    }
    if {[regexp -line {^State:[ \t]+Z[ \t]} $status]} {
        set ::pressureExited 1
        ::livefixture::signal
        return
    }
    after 25 [list schedule_exit_check $pid]
}

proc connect_pressure_controller {deadline} {
    if {![catch {set channel [socket 127.0.0.1 19091]}]} {
        set ::pressureController $channel
        ::livefixture::signal
        return
    }
    if {[clock milliseconds] >= $deadline} {
        set ::pressureConnectFailed 1
        ::livefixture::signal
        return
    }
    # Process startup under amd64 emulation is asynchronous. A bounded timer
    # retry yields fully to the event loop and never spins on readiness.
    after 50 [list connect_pressure_controller $deadline]
}

set port [::livefixture::start]
set adapter [file normalize [file join [file dirname [info script]] conformance adapter.tcl]]
if {[info exists ::env(PRESSURE_ADAPTER_PATH)] && $::env(PRESSURE_ADAPTER_PATH) ne ""} {
    set adapter $::env(PRESSURE_ADAPTER_PATH)
}
set tclsh [auto_execok tclsh]
set savedUrl [expr {[info exists ::env(CONVEX_URL)] ? $::env(CONVEX_URL) : ""}]
set hadUrl [info exists ::env(CONVEX_URL)]
set hadListen [info exists ::env(ADAPTER_LISTEN)]
set savedListen [expr {$hadListen ? $::env(ADAPTER_LISTEN) : ""}]
set ::env(CONVEX_URL) "http://127.0.0.1:$port"
set ::env(ADAPTER_LISTEN) 127.0.0.1:19091
set ::pressureProcess [open [list | $tclsh $adapter] r]
if {$hadUrl} { set ::env(CONVEX_URL) $savedUrl } else { unset ::env(CONVEX_URL) }
if {$hadListen} { set ::env(ADAPTER_LISTEN) $savedListen } else { unset ::env(ADAPTER_LISTEN) }
fconfigure $::pressureProcess -blocking 0 -buffering none -translation binary -encoding utf-8
set pressurePid [lindex [pid $::pressureProcess] 0]
# Use the adapter's real TCP controller mode. This keeps controller writes
# independent when its read side is deliberately stopped.
set ::pressureController ""
set ::pressureConnectFailed 0
connect_pressure_controller [expr {[clock milliseconds] + 2000}]
wait_for {$::pressureController ne "" || $::pressureConnectFailed} "adapter listen did not settle" 2500
assert {!$::pressureConnectFailed} "adapter TCP listener did not become ready"
fconfigure $::pressureController -blocking 0 -buffering none -translation binary -encoding utf-8
set ::pressureBuffer ""
set ::pressureLines {}
fileevent $::pressureController readable pressure_output

puts $::pressureController {{"id":"subscribe","op":"subscribe","subscriptionId":"same","path":"demo:state","args":{}}}
flush $::pressureController
wait_for {[llength $::pressureLines] >= 2} "pressure adapter did not publish ack and initial value"
assert {[lindex $::pressureLines 0] eq {{"id":"subscribe","type":"ack"}}} "pressure subscribe acknowledgement changed"
assert {[lindex $::pressureLines 1] eq {{"type":"subscription","subscriptionId":"same","value":{"count":0}}}} "pressure initial value changed"

# Stop reading the real child pipe, then send values close to the client's 2 MiB
# frame limit. This fills the OS pipe and Tcl channel while the adapter remains
# responsible for bounded queue memory and control admission.
fileevent $::pressureController readable {}
set nearMaximum [string repeat x [expr {1536 * 1024}]]
# Four encoded events exceed the delivery byte allowance even though each is
# valid on its own, so this deterministically saturates the real byte budget
# without turning the gate into a JSON-parser throughput benchmark.
for {set index 0} {$index < 4} {incr index} {
    ::livefixture::update $nearMaximum blob
}
# Ping follows the data frames on the same socket. Its Pong proves the single
# Live owner parsed and queued every large update before control commands begin.
::livefixture::ping pressure-drained
wait_for {$::livefixture::pongCount == 1} "adapter did not process the pressure frames through their Ping barrier" 30000
wait_interval 200
set rss [resident_kib $pressurePid]
assert {$rss < 96 * 1024} "stopped-reader adapter RSS reached $rss KiB"
::livefixture::set_next_payload {{"count":0}}

# Replacement, unsubscribe, and close all arrive while delivery bytes remain
# accepted or pending. Their reserved control slots must let close reach its
# real deadline instead of rejecting an acknowledgement or hanging forever.
puts $::pressureController {{"id":"replace","op":"subscribe","subscriptionId":"same","path":"demo:state","args":{}}}
flush $::pressureController
wait_for {[llength [lsearch -all -inline -index 1 [::livefixture::modifications] Add]] >= 2 && [llength [lsearch -all -inline -index 1 [::livefixture::modifications] Remove]] >= 1} "same-ID replacement did not reach the real Live peer"
puts $::pressureController {{"id":"unsubscribe","op":"unsubscribe","subscriptionId":"same"}}
flush $::pressureController
wait_for {[llength [lsearch -all -inline -index 1 [::livefixture::modifications] Remove]] >= 2} "unsubscribe did not reach the real Live peer"
set closeStarted [clock milliseconds]
puts $::pressureController {{"id":"close","op":"close"}}
flush $::pressureController
set ::pressureExited 0
schedule_exit_check $pressurePid
if {[catch {wait_for {$::pressureExited} "stopped-reader adapter did not honor close deadline" 4500} problem]} {
    set status missing
    if {[file exists "/proc/$pressurePid/status"]} {
        set stream [open "/proc/$pressurePid/status" r]
        try { set status [read $stream] } finally { close $stream }
    }
    error "$problem; controllerPending=[chan pending output $::pressureController]; modifications=[::livefixture::modifications]; processStatus=$status"
}
set elapsed [expr {[clock milliseconds] - $closeStarted}]
assert {$elapsed < 3500} "stopped-reader close exceeded its bounded deadline at ${elapsed}ms"
assert {[llength [::livefixture::connects]] == 1} "pressure test unexpectedly reconnected"
assert {[llength [lsearch -all -inline -index 1 [::livefixture::modifications] Add]] >= 2} "same-ID replacement did not send a real Add"
assert {[llength [lsearch -all -inline -index 1 [::livefixture::modifications] Remove]] >= 2} "replacement and unsubscribe did not send real Remove operations"
fconfigure $::pressureController -blocking 1
append ::pressureBuffer [read $::pressureController]
foreach line [split [string trimright $::pressureBuffer "\n"] "\n"] {
    if {$line ne ""} { lappend ::pressureLines $line }
}
set replacePosition [lsearch -exact $::pressureLines {{"id":"replace","type":"ack"}}]
set unsubscribePosition [lsearch -exact $::pressureLines {{"id":"unsubscribe","type":"ack"}}]
set closedPosition [lsearch -exact $::pressureLines {{"id":"close","type":"closed"}}]
catch {close $::pressureController}
set closeFailed [catch {close $::pressureProcess} closeProblem]
if {$closeFailed} {
    assert {$elapsed >= 1500} "stopped-reader adapter failed before its delivery deadline at ${elapsed}ms"
} else {
    assert {$replacePosition >= 0 && $unsubscribePosition > $replacePosition && $closedPosition > $unsubscribePosition} "reserved control envelopes were not delivered in order"
    foreach line [lrange $::pressureLines [expr {$unsubscribePosition + 1}] end] {
        set envelope [::convex::decode $line]
        assert {![dict exists $envelope subscriptionId]} "stale subscription delivery crossed unsubscribe acknowledgement"
    }
}
::livefixture::stop
puts "Tcl real stopped-reader test passed: RSS ${rss} KiB, close ${elapsed} ms, deliveryFailure=$closeFailed"

# Exercise the adapter queue in this process against a genuine nonblocking OS
# pipe. Tcl accepts a complete puts into its channel layer and reports stopped
# reader pressure as pending output after flush. This is the real ownership
# boundary used by the production adapter, with no fabricated channel error.
set ::env(ADAPTER_TEST_ONLY) 1
source $adapter
unset ::env(ADAPTER_TEST_ONLY)
lassign [chan pipe] pendingRead pendingWrite
fconfigure $pendingRead -blocking 0 -buffering none -translation binary -encoding utf-8
fconfigure $pendingWrite -blocking 0 -buffering none -translation binary -encoding utf-8
set ::adapter::output $pendingWrite
set ::adapter::queue {}
set ::adapter::queueBytes 0
set ::adapter::subscriptions [dict create same 1]
set ::adapter::generations [dict create same 1]
set ::adapter::acceptedWriteCount 0
set ::adapter::acceptedBackpressureCount 0
set ::adapter::observeBackpressure 1
set ::adapter::lastBackpressuredRaw ""
set pendingBlob [string repeat z [expr {64 * 1024}]]
for {set index 0} {$index < 12 && $::adapter::acceptedBackpressureCount == 0} {incr index} {
    set raw [::convex::object [list type [::convex::quote subscription] subscriptionId [::convex::quote same] value [::convex::object [list sequence $index blob [::convex::quote $pendingBlob]]]]]
    ::adapter::emit $raw 1 [list same 1]
}
assert {$::adapter::acceptedWriteCount > 0} "real pipe accepted no adapter record"
assert {$::adapter::acceptedBackpressureCount > 0} "real pipe did not expose accepted output backpressure"
set pendingBytes [chan pending output $pendingWrite]
assert {$pendingBytes > 0} "real stopped reader left no bytes in Tcl's channel buffer"
set acceptedLine [string trimright $::adapter::lastBackpressuredRaw "\n"]
set acceptedCost [::adapter::entry_cost $acceptedLine]
assert {[llength $::adapter::queue] == 1 && [lindex [lindex $::adapter::queue 0] 3] eq "accepted"} "accepted output ownership was not retained"
assert {$::adapter::queueBytes == $acceptedCost} "accepted output byte accounting was not exact"
assert {$pendingBytes <= [string bytelength $::adapter::lastBackpressuredRaw]} "pending channel bytes exceeded the accepted record"
assert {$::adapter::queueBytes <= $::adapter::maxBytes - $::adapter::controlReserve} "accepted delivery exceeded its reserved data budget"
set markerLine {{"id":"accepted-marker","type":"ack"}}
set tailLine {{"type":"subscription","subscriptionId":"same","value":{"tail":true}}}
::adapter::emit $markerLine
::adapter::emit $tailLine 1 [list same 1]
set queuedCost [expr {$acceptedCost + [::adapter::entry_cost $markerLine] + [::adapter::entry_cost $tailLine]}]
assert {$::adapter::queueBytes == $queuedCost} "accepted and queued records were not fully byte-accounted"
assert {$::adapter::queueBytes <= $::adapter::maxBytes} "reserved control output exceeded the global byte budget"

set ::pendingBuffer ""
set ::pendingLines {}
proc pending_readable {} {
    append ::pendingBuffer [read $::pendingRead]
    while {[set newline [string first "\n" $::pendingBuffer]] >= 0} {
        lappend ::pendingLines [string range $::pendingBuffer 0 [expr {$newline - 1}]]
        set ::pendingBuffer [string range $::pendingBuffer [expr {$newline + 1}] end]
    }
    ::livefixture::signal
}
fileevent $pendingRead readable pending_readable
wait_for {[llength $::adapter::queue] == 0 && [lsearch -exact $::pendingLines $markerLine] >= 0 && [lsearch -exact $::pendingLines $tailLine] >= 0} "accepted output did not drain without starvation" 5000
assert {$::adapter::queueBytes == 0} "drained adapter queue retained byte accounting"
set acceptedPositions [lsearch -all -exact $::pendingLines $acceptedLine]
set markerPositions [lsearch -all -exact $::pendingLines $markerLine]
set tailPositions [lsearch -all -exact $::pendingLines $tailLine]
assert {[llength $acceptedPositions] == 1} "accepted NDJSON record was duplicated"
assert {[llength $markerPositions] == 1 && [llength $tailPositions] == 1} "queued records were duplicated or lost"
assert {[lindex $acceptedPositions 0] < [lindex $markerPositions 0] && [lindex $markerPositions 0] < [lindex $tailPositions 0]} "accepted and queued records drained out of order"

# Fill the same real pipe again, keep its reader stopped, and prove terminal
# output fails on the adapter deadline instead of hanging behind accepted bytes.
fileevent $pendingRead readable {}
append ::pendingBuffer [read $pendingRead]
set ::adapter::queue {}
set ::adapter::queueBytes 0
set ::adapter::acceptedBackpressureCount 0
set ::adapter::lastBackpressuredRaw ""
for {set index 0} {$index < 12 && $::adapter::acceptedBackpressureCount == 0} {incr index} {
    set raw [::convex::object [list type [::convex::quote subscription] subscriptionId [::convex::quote same] value [::convex::object [list closeSequence $index blob [::convex::quote $pendingBlob]]]]]
    ::adapter::emit $raw 1 [list same 1]
}
assert {$::adapter::acceptedBackpressureCount > 0} "real close pipe did not become backpressured"
assert {[chan pending output $pendingWrite] > 0} "real close pipe had no pending output"
set closeAcceptedLine [string trimright $::adapter::lastBackpressuredRaw "\n"]
set closeAcceptedCost [::adapter::entry_cost $closeAcceptedLine]
assert {$::adapter::queueBytes == $closeAcceptedCost} "close-path accepted bytes were not exactly accounted"
set closedLine {{"id":"real-close","type":"closed"}}
::adapter::emit $closedLine
assert {$::adapter::queueBytes == $closeAcceptedCost + [::adapter::entry_cost $closedLine]} "terminal control bytes were not retained behind accepted output"
assert {$::adapter::queueBytes <= $::adapter::maxBytes} "terminal output exceeded the global byte budget"
proc pending_exit {code} { set ::pendingExit $code; ::livefixture::signal }
set ::adapter::exitHook pending_exit
set ::pendingExit ""
set realCloseStarted [clock milliseconds]
set ::adapter::closeDeadline [expr {$realCloseStarted + 350}]
::adapter::finish_close
wait_for {$::pendingExit ne ""} "real backpressured close ignored its deadline" 1200
set realCloseElapsed [expr {[clock milliseconds] - $realCloseStarted}]
assert {$::pendingExit == 1} "real backpressured close did not fail"
assert {$realCloseElapsed >= 300 && $realCloseElapsed < 1000} "real backpressured close finished at ${realCloseElapsed}ms"
if {$::adapter::flushTimer ne ""} { after cancel $::adapter::flushTimer; set ::adapter::flushTimer "" }
fileevent $pendingWrite writable {}
close $pendingRead
close $pendingWrite
set ::adapter::exitHook ""
set ::adapter::observeBackpressure 0
puts "Tcl genuine accepted-byte pending-output test passed: close ${realCloseElapsed} ms"
