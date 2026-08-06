#!/usr/local/bin/tclsh
# Test-only NDJSON adapter. Its public-facing client is client/convex.tcl;
# debugDisconnect and the output queue exist solely for the shared harness.
set clientSource /opt/convex/client/convex.tcl
if {![file exists $clientSource]} {
    set clientSource [file normalize [file join [file dirname [info script]] .. .. convex.tcl]]
}
if {![llength [info commands ::convex::new]]} { source $clientSource }

namespace eval ::adapter {
    variable client ""
    variable input ""
    variable output ""
    variable subscriptions {}
    variable generations {}
    variable queue {}
    variable queueBytes 0
    variable closing 0
    variable terminated 0
    variable maxEvents 16
    variable maxBytes [expr {6 * 1024 * 1024}]
    # Leave room for a terminal acknowledgement even when a reader stops after
    # accepting a burst of subscription values. The per-event allowance covers
    # Tcl's queue record, channel bookkeeping, and a conservative runtime cost.
    variable controlReserve [expr {64 * 1024}]
    variable entryOverhead 512
    variable channelOverhead 4096
    variable closeDeadline 0
    variable closeTimeoutMs 2000
    variable exitHook ""
    # Test-only pending override. It gives the unit test a deterministic
    # stopped-reader channel without depending on an OS socket buffer size.
    variable pendingOutputHook ""
    # Test-only deterministic barrier. A test invalidates a relay after it has
    # been dequeued but before Tcl accepts it into the output channel.
    variable pauseAfterDequeue ""
}

proc ::adapter::terminate {status} {
    variable exitHook
    if {$exitHook ne ""} {
        uplevel #0 [list {*}$exitHook $status]
        return
    }
    exit $status
}

proc ::adapter::error_raw {message {name Error} {data null}} {
    return [::convex::object [list name [::convex::quote $name] message [::convex::quote $message] data $data]]
}

proc ::adapter::entry_cost {raw} {
    variable entryOverhead
    variable channelOverhead
    # Account for the newline sent over NDJSON as well as conservative Tcl and
    # channel state. queueBytes is therefore a real upper bound, not merely
    # the size of the JSON values in a Tcl list.
    return [expr {[string bytelength "$raw\n"] + $entryOverhead + $channelOverhead}]
}

proc ::adapter::delivery_current {tag} {
    variable subscriptions
    variable generations
    if {$tag eq ""} { return 1 }
    lassign $tag subscriptionId generation
    return [expr {
        [dict exists $subscriptions $subscriptionId]
        && [dict exists $generations $subscriptionId]
        && [dict get $generations $subscriptionId] == $generation
    }]
}

proc ::adapter::discard_at {position} {
    variable queue
    variable queueBytes
    lassign [lindex $queue $position] raw droppable tag state cost
    if {$cost eq ""} { error "adapter queue entry omitted its byte cost: [lindex $queue $position]" }
    set queue [lreplace $queue $position $position]
    incr queueBytes [expr {-$cost}]
}

proc ::adapter::output_pending {} {
    variable output
    variable pendingOutputHook
    if {$pendingOutputHook ne ""} { return [uplevel #0 $pendingOutputHook] }
    return [chan pending output $output]
}

proc ::adapter::release_accepted {} {
    variable queue
    variable queueBytes
    set retained {}
    foreach item $queue {
        lassign $item raw droppable tag state cost
        if {$state eq "accepted"} {
            incr queueBytes [expr {-$cost}]
        } else {
            lappend retained $item
        }
    }
    set queue $retained
}

proc ::adapter::drop_oldest_delivery {} {
    variable queue
    set position 0
    foreach item $queue {
        lassign $item raw droppable tag state cost
        # Bytes accepted into a nonblocking Tcl channel are still in flight.
        # They cannot be dropped from the bounded accounting until drained.
        if {$droppable && $state eq "queued"} {
            discard_at $position
            return 1
        }
        incr position
    }
    return 0
}

proc ::adapter::emit {raw {droppable 0} {tag ""}} {
    variable queue
    variable queueBytes
    variable maxEvents
    variable maxBytes
    variable controlReserve
    set cost [entry_cost $raw]
    set limit [expr {$droppable ? $maxBytes - $controlReserve : $maxBytes}]
    if {$cost > $limit} {
        if {$droppable} { return }
        error "adapter event exceeds the encoded output budget"
    }
    while {[llength $queue] >= $maxEvents || $queueBytes + $cost > $limit} {
        if {![drop_oldest_delivery]} {
            if {$droppable} { return }
            error "adapter output remained backpressured for a control event"
        }
    }
    lappend queue [list "$raw\n" $droppable $tag queued $cost]
    incr queueBytes $cost
    flush
}

proc ::adapter::flush {} {
    variable output
    variable queue
    variable queueBytes
    set position 0
    while {$position < [llength $queue]} {
        lassign [lindex $queue $position] raw droppable tag state cost
        if {$state eq "accepted"} { incr position; continue }
        # Recheck ownership immediately before writing. This is the adapter's
        # acknowledgement barrier: a paused, dequeued relay cannot publish a
        # stale value after unsubscribe or same-ID replacement invalidates it.
        variable pauseAfterDequeue
        if {$pauseAfterDequeue ne ""} {
            set hook $pauseAfterDequeue
            set pauseAfterDequeue ""
            uplevel #0 $hook
            # The hook may invalidate and remove this queued delivery.
            if {$position >= [llength $queue]} { break }
            lassign [lindex $queue $position] raw droppable tag state cost
        }
        if {$droppable && ![delivery_current $tag]} {
            discard_at $position
            continue
        }
        # A valid delivery must not grow Tcl's channel buffer behind an
        # accepted prefix. A control event is allowed through the reserved
        # budget, so close/ack can be accepted in-order by a slow reader.
        if {$droppable && $position > 0} { break }
        if {[catch {puts -nonewline $output $raw; ::flush $output} error]} {
            if {[string match {*would block*} [string tolower $error]]} {
                fileevent $output writable ::adapter::flush
                return
            }
            exit 1
        }
        # Retain the record until Tcl reports that the channel has drained it.
        lset queue $position 3 accepted
        incr position
    }
    if {![llength $queue]} { fileevent $output writable {}; return }
    if {[catch {set pending [output_pending]} error]} { exit 1 }
    if {$pending > 0} {
        fileevent $output writable ::adapter::flush
        return
    }
    # The accepted prefix has drained. Keep any queued delivery behind it: it
    # was intentionally held back while Tcl still owned earlier bytes.
    release_accepted
    fileevent $output writable {}
    if {[llength $queue]} { flush }
}

proc ::adapter::remove_queued_subscription {subscriptionId} {
    variable queue
    variable queueBytes
    set retained {}
    foreach item $queue {
        lassign $item raw droppable tag state cost
        if {$tag ne "" && [lindex $tag 0] eq $subscriptionId && $state eq "queued"} {
            incr queueBytes [expr {-$cost}]
        } else {
            lappend retained $item
        }
    }
    set queue $retained
}

proc ::adapter::invalidate_subscription {subscriptionId} {
    variable subscriptions
    variable generations
    if {[dict exists $generations $subscriptionId]} {
        dict incr generations $subscriptionId
    } else {
        dict set generations $subscriptionId 1
    }
    if {[dict exists $subscriptions $subscriptionId]} { dict unset subscriptions $subscriptionId }
    # Queued stale relays disappear now. Accepted bytes remain budgeted and
    # precede the acknowledgement on the one output channel.
    remove_queued_subscription $subscriptionId
}

proc ::adapter::ensure_client {} {
    variable client
    if {$client ne ""} { return $client }
    if {![info exists ::env(CONVEX_URL)] || $::env(CONVEX_URL) eq ""} { error "CONVEX_URL is required" }
    set token [expr {[info exists ::env(CONVEX_AUTH_TOKEN)] ? $::env(CONVEX_AUTH_TOKEN) : ""}]
    set client [::convex::new $::env(CONVEX_URL) tcl-0.1.0 $token]
    return $client
}

proc ::adapter::respond_error {id message {name Error} {data null} {subscriptionId ""} {logs "[]"}} {
    set fields [list type [::convex::quote [expr {$subscriptionId eq "" ? "error" : "subscription"}]]]
    if {$subscriptionId eq ""} { lappend fields id [::convex::quote $id] } else { lappend fields subscriptionId [::convex::quote $subscriptionId] }
    lappend fields error [error_raw $message $name $data]
    if {$logs ne "[]"} { lappend fields logs $logs }
    emit [::convex::object $fields]
}

proc ::adapter::subscription_error {subscriptionId generation name message {data null} {logs "[]"}} {
    if {![delivery_current [list $subscriptionId $generation]]} { return }
    set fields [list type [::convex::quote subscription] subscriptionId [::convex::quote $subscriptionId] error [error_raw $message $name $data]]
    if {$logs ne "[]" && $logs ne ""} { lappend fields logs $logs }
    emit [::convex::object $fields] 1 [list $subscriptionId $generation]
}

proc ::adapter::subscription_event {subscriptionId generation kind payload logs} {
    variable generations
    variable subscriptions
    if {![dict exists $generations $subscriptionId] || [dict get $generations $subscriptionId] != $generation || ![dict exists $subscriptions $subscriptionId]} { return }
    if {$kind eq "value"} {
        set fields [list type [::convex::quote subscription] subscriptionId [::convex::quote $subscriptionId] value $payload]
        if {$logs ne "[]" && $logs ne ""} { lappend fields logs $logs }
        emit [::convex::object $fields] 1 [list $subscriptionId $generation]
    } else {
        set text [::convex::decode [::convex::field $payload message]]
        set data [::convex::field $payload data]
        set name [::convex::decode [::convex::field $payload name]]
        subscription_error $subscriptionId $generation $name $text $data $logs
    }
}

proc ::adapter::handle {line} {
    variable client
    variable subscriptions
    variable generations
    variable closing
    if {[catch {set command [::convex::decode $line]} parseError]} {
        respond_error "" "decode command: $parseError" ProtocolError
        return
    }
    set id [expr {[dict exists $command id] ? [dict get $command id] : ""}]
    if {![dict exists $command op]} { respond_error $id "command omitted op" ProtocolError; return }
    set op [dict get $command op]
    if {[catch {
        switch -- $op {
            hello {
                if {![dict exists $command protocolVersion] || [dict get $command protocolVersion] != 1} { error "unsupported adapter protocol version" }
                emit [::convex::object [list protocolVersion 1 id [::convex::quote $id] type [::convex::quote ready] language [::convex::quote tcl] implementation [::convex::quote native-tcl-8.6.13] runtime [::convex::quote tcl-8.6.13]]]
            }
            query - mutation - action {
                set result [::convex::$op [ensure_client] [dict get $command path] [::convex::field $line args]]
                set fields [list id [::convex::quote $id] type [::convex::quote result] value [dict get $result value]]
                if {[dict get $result logs] ne "[]"} { lappend fields logs [dict get $result logs] }
                emit [::convex::object $fields]
            }
            setAuth {
                ::convex::set_auth [ensure_client] [dict get $command token]
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            subscribe {
                set subscriptionId [dict get $command subscriptionId]
                if {[dict exists $subscriptions $subscriptionId]} {
                    # Invalidate before replacement can expose its ack. A
                    # queued old relay is discarded; accepted bytes stay ahead
                    # of the new acknowledgement on the single output stream.
                    ::convex::unsubscribe [ensure_client] [dict get $subscriptions $subscriptionId]
                    invalidate_subscription $subscriptionId
                }
                if {![dict exists $generations $subscriptionId]} { dict set generations $subscriptionId 1 }
                set generation [dict get $generations $subscriptionId]
                set queryId [::convex::subscribe [ensure_client] [dict get $command path] [::convex::field $line args] [list ::adapter::subscription_event $subscriptionId $generation]]
                dict set subscriptions $subscriptionId $queryId
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            unsubscribe {
                set subscriptionId [dict get $command subscriptionId]
                if {[dict exists $subscriptions $subscriptionId]} {
                    ::convex::unsubscribe [ensure_client] [dict get $subscriptions $subscriptionId]
                    invalidate_subscription $subscriptionId
                }
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            debugDisconnect {
                ::convex::debug_disconnect [ensure_client]
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            close {
                dict for {subscriptionId queryId} $subscriptions { ::convex::unsubscribe [ensure_client] $queryId }
                dict for {subscriptionId queryId} $subscriptions { invalidate_subscription $subscriptionId }
                set subscriptions {}
                if {$client ne ""} { ::convex::close $client }
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote closed]]]
                set closing 1
                variable closeDeadline
                variable closeTimeoutMs
                set closeDeadline [expr {[clock milliseconds] + $closeTimeoutMs}]
                # Keep the event loop alive until the closed event reaches the
                # output channel, or fail boundedly instead of silently exiting
                # after merely scheduling a writable callback.
                after 0 ::adapter::finish_close
            }
            default { error "unknown adapter operation $op" }
        }
    } error options]} {
        set name Error
        set data null
        set logs "[]"
        set code [dict get $options -errorcode]
        if {[lindex $code 0] eq "CONVEX"} { set name [lindex $code 1]; set data [lindex $code 2]; set logs [lindex $code 3] }
        respond_error $id $error $name $data "" $logs
    }
}

proc ::adapter::readable {} {
    variable input
    variable closing
    while {!$closing && [gets $input line] >= 0} { handle $line }
    if {[eof $input] && !$closing} { finish }
}

proc ::adapter::finish {} {
    variable queue
    flush
    if {[llength $queue]} { after 10 ::adapter::finish; return }
    exit 0
}

proc ::adapter::finish_close {} {
    variable queue
    variable closeDeadline
    flush
    if {![llength $queue]} { terminate 0; return }
    if {[clock milliseconds] >= $closeDeadline} {
        puts stderr "adapter close response could not drain before deadline"
        terminate 1
        return
    }
    after 10 ::adapter::finish_close
}

proc ::adapter::attach {in out} {
    variable input
    variable output
    set input $in
    set output $out
    fconfigure $input -blocking 0 -buffering line -encoding utf-8 -translation lf
    fconfigure $output -blocking 0 -buffering none -encoding utf-8 -translation lf
    fileevent $input readable ::adapter::readable
}

proc ::adapter::accept {channel host port} {
    variable server
    close $server
    attach $channel $channel
}

if {![info exists ::env(ADAPTER_TEST_ONLY)]} {
    if {[info exists ::env(ADAPTER_LISTEN)] && $::env(ADAPTER_LISTEN) ne ""} {
        if {![regexp {^([^:]+):([0-9]+)$} $::env(ADAPTER_LISTEN) -> host port]} { error "ADAPTER_LISTEN must use host:port" }
        set ::adapter::server [socket -server ::adapter::accept -myaddr $host $port]
        vwait ::adapter::terminated
    } else {
        ::adapter::attach stdin stdout
        vwait ::adapter::terminated
    }
}
