#!/usr/local/bin/tclsh
# Test-only NDJSON adapter. Its public-facing client is client/convex.tcl;
# debugDisconnect and the output queue exist solely for the shared harness.
set clientSource /opt/convex/client/convex.tcl
if {![file exists $clientSource]} {
    set clientSource [file normalize [file join [file dirname [info script]] .. .. convex.tcl]]
}
source $clientSource

namespace eval ::adapter {
    variable client ""
    variable input ""
    variable output ""
    variable subscriptions {}
    variable generations {}
    variable queue {}
    variable queueBytes 0
    variable writing 0
    variable closing 0
    variable maxEvents 16
    variable maxBytes [expr {6 * 1024 * 1024}]
}

proc ::adapter::error_raw {message {name Error} {data null}} {
    return [::convex::object [list name [::convex::quote $name] message [::convex::quote $message] data $data]]
}

proc ::adapter::drop_oldest_delivery {} {
    variable queue
    variable queueBytes
    set position 0
    foreach item $queue {
        lassign $item raw droppable tag written
        # Bytes accepted into a nonblocking Tcl channel are still in flight.
        # They cannot be dropped from the bounded accounting until drained.
        if {$droppable && !$written} {
            set queue [lreplace $queue $position $position]
            incr queueBytes -[string bytelength $raw]
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
    set bytes [string bytelength $raw]
    if {$bytes > $maxBytes} { error "adapter event exceeds the encoded output budget" }
    while {[llength $queue] >= $maxEvents || $queueBytes + $bytes > $maxBytes} {
        if {![drop_oldest_delivery]} {
            if {$droppable} { return }
            error "adapter output remained backpressured for a control event"
        }
    }
    lappend queue [list "$raw\n" $droppable $tag 0]
    incr queueBytes [string bytelength "$raw\n"]
    flush
}

proc ::adapter::flush {} {
    variable output
    variable queue
    variable queueBytes
    while {[llength $queue]} {
        lassign [lindex $queue 0] raw droppable tag written
        if {$written} {
            if {[catch {set pending [chan pending output $output]} error]} { exit 1 }
            if {$pending > 0} {
                fileevent $output writable ::adapter::flush
                return
            }
            set queue [lrange $queue 1 end]
            incr queueBytes -[string bytelength $raw]
            continue
        }
        if {[catch {puts -nonewline $output $raw; ::flush $output} error]} {
            if {[string match {*would block*} [string tolower $error]]} {
                fileevent $output writable ::adapter::flush
                return
            }
            exit 1
        }
        # Retain the record until Tcl reports that the channel has drained it.
        lset queue 0 3 1
        if {[catch {set pending [chan pending output $output]} error]} { exit 1 }
        if {$pending == 0} {
            set queue [lrange $queue 1 end]
            incr queueBytes -[string bytelength $raw]
        } else {
            fileevent $output writable ::adapter::flush
            return
        }
    }
    fileevent $output writable {}
}

proc ::adapter::remove_queued_subscription {subscriptionId} {
    variable queue
    variable queueBytes
    set retained {}
    foreach item $queue {
        lassign $item raw droppable tag written
        if {$tag eq $subscriptionId && !$written} {
            incr queueBytes -[string bytelength $raw]
        } else {
            lappend retained $item
        }
    }
    set queue $retained
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
    emit [::convex::object $fields] [expr {$subscriptionId ne ""}] $subscriptionId
}

proc ::adapter::subscription_event {subscriptionId generation kind payload logs} {
    variable generations
    variable subscriptions
    if {![dict exists $generations $subscriptionId] || [dict get $generations $subscriptionId] != $generation || ![dict exists $subscriptions $subscriptionId]} { return }
    if {$kind eq "value"} {
        set fields [list type [::convex::quote subscription] subscriptionId [::convex::quote $subscriptionId] value $payload]
        if {$logs ne "[]" && $logs ne ""} { lappend fields logs $logs }
        emit [::convex::object $fields] 1 $subscriptionId
    } else {
        set text [::convex::decode [::convex::field $payload message]]
        set data [::convex::field $payload data]
        respond_error "" $text FunctionError $data $subscriptionId $logs
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
                    # Invalidate before the acknowledgement barrier and erase a
                    # delivery already queued by the old same-ID relay.
                    ::convex::unsubscribe [ensure_client] [dict get $subscriptions $subscriptionId]
                    dict unset subscriptions $subscriptionId
                    remove_queued_subscription $subscriptionId
                }
                set generation [expr {[dict exists $generations $subscriptionId] ? [dict get $generations $subscriptionId] + 1 : 1}]
                dict set generations $subscriptionId $generation
                set queryId [::convex::subscribe [ensure_client] [dict get $command path] [::convex::field $line args] [list ::adapter::subscription_event $subscriptionId $generation]]
                dict set subscriptions $subscriptionId $queryId
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            unsubscribe {
                set subscriptionId [dict get $command subscriptionId]
                if {[dict exists $subscriptions $subscriptionId]} {
                    dict set generations $subscriptionId [expr {[dict get $generations $subscriptionId] + 1}]
                    ::convex::unsubscribe [ensure_client] [dict get $subscriptions $subscriptionId]
                    dict unset subscriptions $subscriptionId
                    remove_queued_subscription $subscriptionId
                }
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            debugDisconnect {
                ::convex::debug_disconnect [ensure_client]
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote ack]]]
            }
            close {
                dict for {subscriptionId queryId} $subscriptions { ::convex::unsubscribe [ensure_client] $queryId }
                set subscriptions {}
                if {$client ne ""} { ::convex::close $client }
                emit [::convex::object [list id [::convex::quote $id] type [::convex::quote closed]]]
                set closing 1
                # The close response is a control event, so flush it before
                # terminating rather than leaving an event-loop callback alive.
                flush
                exit 0
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

if {[info exists ::env(ADAPTER_LISTEN)] && $::env(ADAPTER_LISTEN) ne ""} {
    if {![regexp {^([^:]+):([0-9]+)$} $::env(ADAPTER_LISTEN) -> host port]} { error "ADAPTER_LISTEN must use host:port" }
    set ::adapter::server [socket -server ::adapter::accept -myaddr $host $port]
    vwait ::adapter::closing
} else {
    ::adapter::attach stdin stdout
    vwait ::adapter::closing
}
