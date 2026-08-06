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
    variable controlReserveEvents 4
    variable maxBytes [expr {6 * 1024 * 1024}]
    # Leave room for a terminal acknowledgement even when a reader stops after
    # accepting a burst of subscription values. The per-event allowance covers
    # Tcl's queue record, channel bookkeeping, and a conservative runtime cost.
    variable controlReserve [expr {64 * 1024}]
    variable entryOverhead 512
    variable channelOverhead 4096
    variable closeDeadline 0
    variable closeTimeoutMs 2000
    variable flushTimer ""
    variable exitHook ""
    # Test-only pending override. It gives the unit test a deterministic
    # stopped-reader channel without depending on an OS socket buffer size.
    variable pendingOutputHook ""
    # Tests observe these counters while using real nonblocking channels. They
    # never alter channel readiness or queue ownership.
    variable acceptedWriteCount 0
    variable acceptedBackpressureCount 0
    variable observeBackpressure 0
    variable lastBackpressuredRaw ""
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
    set fields [list name [::convex::quote $name] message [::convex::quote $message]]
    if {$data ne ""} { lappend fields data $data }
    return [::convex::object $fields]
}

proc ::adapter::logs_present {logs} {
    # A bare [] inside an expr is command substitution, not the JSON empty
    # array literal. Compare it as a Tcl string so empty log arrays stay
    # omitted from exact adapter envelopes.
    return [expr {$logs ne "" && ![string equal $logs "\[\]"]}]
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
    variable controlReserveEvents
    variable maxBytes
    variable controlReserve
    set cost [entry_cost $raw]
    set limit [expr {$droppable ? $maxBytes - $controlReserve : $maxBytes}]
    set eventLimit [expr {$droppable ? $maxEvents - $controlReserveEvents : $maxEvents}]
    if {$cost > $limit} {
        if {$droppable} { return }
        error "adapter event exceeds the encoded output budget"
    }
    while {[llength $queue] >= $eventLimit || $queueBytes + $cost > $limit} {
        if {![drop_oldest_delivery]} {
            if {$droppable} { return }
            error "adapter output remained backpressured for a control event"
        }
    }
    lappend queue [list "$raw\n" $droppable $tag queued $cost]
    incr queueBytes $cost
    flush
}

proc ::adapter::schedule_flush {} {
    variable flushTimer
    if {$flushTimer eq ""} { set flushTimer [after 25 ::adapter::scheduled_flush] }
}

proc ::adapter::scheduled_flush {} {
    variable flushTimer
    set flushTimer ""
    flush
}

proc ::adapter::flush {} {
    variable output
    variable queue
    variable queueBytes
    variable flushTimer
    if {$flushTimer ne ""} {
        after cancel $flushTimer
        set flushTimer ""
    }
    # Tcl owns every accepted record until the channel reports no pending output.
    # Do not append another record behind that prefix, even a control response.
    # Controls remain admitted to the reserved queue and are written in order as
    # soon as the accepted bytes drain.
    set accepted 0
    foreach item $queue {
        if {[lindex $item 3] eq "accepted"} { set accepted 1; break }
    }
    if {$accepted} {
        if {[catch {set pending [output_pending]} error]} { exit 1 }
        if {$pending > 0} {
            fileevent $output writable {}
            schedule_flush
            return
        }
        release_accepted
    }
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
            if {$state eq "accepted"} { incr position; continue }
        }
        if {$droppable && ![delivery_current $tag]} {
            discard_at $position
            continue
        }
        # A valid delivery must not grow Tcl's channel buffer behind an
        # accepted prefix. A control event is allowed through the reserved
        # budget, so close/ack can be accepted in-order by a slow reader.
        if {$droppable && $position > 0} { break }
        if {[catch {puts -nonewline $output $raw}]} { exit 1 }
        # puts accepted the complete record into Tcl's channel layer. Mark that
        # ownership before flush. A nonblocking flush can return with bytes in
        # Tcl's channel buffer, and retrying the source record would duplicate
        # the already accepted NDJSON event.
        lset queue $position 3 accepted
        variable acceptedWriteCount
        variable acceptedBackpressureCount
        variable observeBackpressure
        variable lastBackpressuredRaw
        incr acceptedWriteCount
        if {[catch {::flush $output}]} { exit 1 }
        if {[catch {set pending [output_pending]} error]} { exit 1 }
        if {$pending > 0} {
            # Tcl already owns this record. A writable fileevent can fire
            # continuously while channel bytes remain pending and starve
            # controller and WebSocket reads, so recheck with one bounded
            # timer instead.
            incr acceptedBackpressureCount
            if {$observeBackpressure} { set lastBackpressuredRaw $raw }
            fileevent $output writable {}
            schedule_flush
            return
        }
        release_accepted
        set position 0
    }
    if {![llength $queue]} { fileevent $output writable {}; return }
    if {[catch {set pending [output_pending]} error]} { exit 1 }
    if {$pending > 0} {
        fileevent $output writable {}
        schedule_flush
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

proc ::adapter::respond_error {message {name Error} {data null} {logs "\[\]"} {id ""} {includeId 0}} {
    set fields [list type [::convex::quote error]]
    if {$includeId} { lappend fields id [::convex::quote $id] }
    lappend fields error [error_raw $message $name $data]
    if {[logs_present $logs]} { lappend fields logs $logs }
    emit [::convex::object $fields]
}

proc ::adapter::required_string {line command fieldName {maximumLength 128}} {
    set raw [::convex::field $line $fieldName 0]
    if {$raw eq "" || [string index $raw 0] ne "\""} { ::convex::throw ProtocolError "command omitted valid $fieldName" }
    if {[catch {set value [::convex::decode $raw]}]} { ::convex::throw ProtocolError "command omitted valid $fieldName" }
    set length [string length $value]
    if {$length < 1 || $length > $maximumLength} { ::convex::throw ProtocolError "command omitted valid $fieldName" }
    return $value
}

# Arguments are a named JSON object on the wire and stay exactly that. Decoding
# is only a syntax check here: the original subtree is what reaches Convex.
proc ::adapter::required_object {line fieldName} {
    set raw [::convex::field $line $fieldName 0]
    if {$raw eq "" || ![regexp {^[ \t\r\n]*\{} $raw]} { ::convex::throw ProtocolError "command omitted valid $fieldName" }
    if {[catch {set decoded [::convex::decode $raw]}] || [llength $decoded] % 2} {
        ::convex::throw ProtocolError "command omitted valid $fieldName"
    }
    return $raw
}

proc ::adapter::error_details {message options} {
    set name Error
    set data null
    set logs "\[\]"
    set code [dict get $options -errorcode]
    if {[lindex $code 0] eq "CONVEX"} {
        set name [lindex $code 1]
        set data [lindex $code 2]
        set logs [lindex $code 3]
    } elseif {[regexp {^(ProtocolError|TransportError|FunctionError):[ ]*(.*)$} $message -> classified detail]} {
        set name $classified
        set message $detail
    }
    if {[string match "$name:*" $message]} { set message [string trim [string range $message [expr {[string length $name] + 1}] end]] }
    return [list $message $name $data $logs]
}

proc ::adapter::subscription_error {subscriptionId generation name message {data null} {logs "\[\]"}} {
    if {![delivery_current [list $subscriptionId $generation]]} { return }
    set fields [list type [::convex::quote subscription] subscriptionId [::convex::quote $subscriptionId] error [error_raw $message $name $data]]
    if {[logs_present $logs]} { lappend fields logs $logs }
    emit [::convex::object $fields] 1 [list $subscriptionId $generation]
}

proc ::adapter::subscription_event {subscriptionId generation kind payload logs} {
    variable generations
    variable subscriptions
    if {![dict exists $generations $subscriptionId] || [dict get $generations $subscriptionId] != $generation || ![dict exists $subscriptions $subscriptionId]} { return }
    if {$kind eq "value"} {
        set fields [list type [::convex::quote subscription] subscriptionId [::convex::quote $subscriptionId] value $payload]
        if {[logs_present $logs]} { lappend fields logs $logs }
        emit [::convex::object $fields] 1 [list $subscriptionId $generation]
    } else {
        set text [::convex::decode [::convex::field $payload message]]
        set data [::convex::field $payload data 0]
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
        respond_error "decode command: $parseError" ProtocolError
        return
    }
    if {[catch {set id [required_string $line $command id]} idError idOptions]} {
        lassign [error_details $idError $idOptions] message name data logs
        respond_error $message $name $data $logs
        return
    }
    if {[catch {set op [required_string $line $command op]} opError opOptions]} {
        lassign [error_details $opError $opOptions] message name data logs
        respond_error $message $name $data $logs $id 1
        return
    }
    if {[catch {
        switch -- $op {
            hello {
                if {![dict exists $command protocolVersion] || [dict get $command protocolVersion] != 1} { ::convex::throw ProtocolError "unsupported adapter protocol version" }
                emit [::convex::object [list protocolVersion 1 id [::convex::quote $id] type [::convex::quote ready] language [::convex::quote tcl] implementation [::convex::quote native-tcl-8.6.13] runtime [::convex::quote tcl-8.6.13]]]
            }
            query - mutation - action {
                # Validate the whole command before a client is created, so a
                # malformed command fails the same way with or without a
                # deployment URL in the environment.
                set functionPath [required_string $line $command path 512]
                set callArgs [required_object $line args]
                set result [::convex::$op [ensure_client] $functionPath $callArgs]
                set fields [list id [::convex::quote $id] type [::convex::quote result] value [dict get $result value]]
                if {[logs_present [dict get $result logs]]} { lappend fields logs [dict get $result logs] }
                emit [::convex::object $fields]
            }
            setAuth {
                # An absent, null, or empty token clears authentication. That is
                # the second half of the controller's bearer-token lifecycle, not
                # a malformed command.
                set tokenRaw [::convex::field $line token 0]
                set token ""
                if {$tokenRaw ne "" && $tokenRaw ne "null"} {
                    if {[string index $tokenRaw 0] ne "\"" || [catch {set token [::convex::decode $tokenRaw]}]} {
                        ::convex::throw ProtocolError "command omitted valid token"
                    }
                }
                ::convex::set_auth [ensure_client] $token
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            subscribe {
                set subscriptionId [required_string $line $command subscriptionId]
                set functionPath [required_string $line $command path 512]
                set subscribeArgs [required_object $line args]
                if {[dict exists $subscriptions $subscriptionId]} {
                    # Invalidate before replacement can expose its ack. A
                    # queued old relay is discarded; accepted bytes stay ahead
                    # of the new acknowledgement on the single output stream.
                    ::convex::unsubscribe [ensure_client] [dict get $subscriptions $subscriptionId]
                    invalidate_subscription $subscriptionId
                }
                if {![dict exists $generations $subscriptionId]} { dict set generations $subscriptionId 1 }
                set generation [dict get $generations $subscriptionId]
                set queryId [::convex::subscribe [ensure_client] $functionPath $subscribeArgs [list ::adapter::subscription_event $subscriptionId $generation]]
                dict set subscriptions $subscriptionId $queryId
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            unsubscribe {
                set subscriptionId [required_string $line $command subscriptionId]
                if {[dict exists $subscriptions $subscriptionId]} {
                    ::convex::unsubscribe [ensure_client] [dict get $subscriptions $subscriptionId]
                    invalidate_subscription $subscriptionId
                }
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            debugDisconnect {
                ::convex::debug_disconnect [ensure_client]
                set liveState [::convex::state $client]
                if {[dict get $liveState socket] ne "" || [dict get $liveState reconnectTimer] eq ""} {
                    error "debugDisconnect acknowledgement barrier was not reached"
                }
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
            default { ::convex::throw ProtocolError "unknown adapter operation $op" }
        }
    } error options]} {
        lassign [error_details $error $options] message name data logs
        respond_error $message $name $data $logs $id 1
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
