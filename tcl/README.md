<p align="center"><img src="logo.png" alt="Tcl/Tk core logo" width="120"></p>
<!-- Logo source: https://www.tcl-lang.org/images/tcllogo.gif -->

# Tcl

Tcl, short for Tool Command Language, began with John Ousterhout's work on an
embeddable command language at Berkeley in the late 1980s, as told in
[Tcl's official history](https://www.tcl-lang.org/about/history.html). It later
gained the Tk GUI toolkit and found a durable niche in test automation,
embedded control, electronic design tools, networking, and cross-platform
desktop software. The [official Tcl/Tk site](https://www.tcl-lang.org/) covers
the language, current releases, and community.

This repository uses Tcl's small command-oriented language and event loop to
talk to Convex over HTTP and a Tcl-owned WebSocket connection. It is an
educational, unofficial experiment, not a production SDK, an officially
sanctioned Convex client, or a package intended for publication.

## Getting Started

Start with [`examples/basics/main.tcl`](examples/basics/main.tcl). It queries a
fresh counter, opens a Live subscription before mutating it, and proves the
same `0 -> 1` journey through both paths.

From the repository root, Docker builds the pinned Tcl environment and runs
that exact example against an approved test deployment:

```sh
./run verify-example tcl
```

## Interesting Parts

### A reply becomes a dict, not a type

Convex sends JSON back over the wire. A TypeScript client leans on generated
types to know that `state.count` exists; Tcl has no compiler to ask, so this
client decodes the reply into a plain [`dict`](https://www.tcl-lang.org/man/tcl8.6/TclCmd/dict.htm)
and every field is looked up by name at runtime.

```tcl
set args [::convex::object [list room [::convex::quote $room]]]
set response [::convex::query $client demo:state $args]
set state [::convex::decode [dict get $response value]]

puts [dict get $state count] ;# TypeScript: state.count, caught by the compiler instead
```

Get the key wrong and Tcl fails when the line runs, not before.

### Square brackets splice a command straight into a string

Ousterhout built Tcl around one substitution rule: anything inside `[...]`
runs as a command and its result is pasted into place, even mid-string. There
are no template literals or string-builder calls — every value, including the
JSON this client sends Convex, gets assembled the same way.

```tcl
set room "tcl-live-[clock microseconds]" ;# the bracketed command runs first
set mutationArgs [::convex::object [list \
    room [::convex::quote $room] \
    language [::convex::quote tcl] \
    runId [::convex::quote [format %x [clock microseconds]]]]]
set result [::convex::mutation $client demo:increment $mutationArgs]
puts [dict get [::convex::decode [dict get $result value]] applied]
```

### `vwait` turns Convex's push into a wait

There's no `useQuery` here to own a subscription's lifecycle. Instead the
client hands Live updates to a plain callback, and the caller blocks on
[`vwait`](https://www.tcl-lang.org/man/tcl8.6/TclCmd/vwait.htm) — Tcl's event
loop keeps servicing the WebSocket until that callback writes the variable
being watched.

```tcl
proc receive_state {kind payload logs} {
    set ::liveState [::convex::decode $payload]
    set ::liveReady 1 ;# writing this releases the vwait below
}

set subscription [::convex::subscribe $client demo:state $args [list receive_state]]
vwait ::liveReady ;# TypeScript: this is what useQuery's rerender hides from you
puts [dict get $::liveState count]
::convex::unsubscribe $client $subscription
```

The blocking look is this example's choice, not a limit of Tcl — the same
event loop is what let the socket keep running underneath `vwait` at all.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified | Shared local and hosted conformance passed from a clean exact-head build. Query, mutation, action, bearer-token lifecycle, logs, and structured errors are covered. |
| Live | Verified | Shared local and hosted conformance passed from a clean exact-head build. Subscriptions, unsubscribe, five real reconnects, reactive errors, and clean close are covered. |

The shared evaluator awarded both badges with 31/31 checks passing on the local
and hosted profiles. This README-only update does not claim a fresh conformance
run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.tcl -->
```tcl
#!/usr/local/bin/tclsh
# The canonical teaching example intentionally uses the same Tcl client source
# as the conformance adapter, so readers run precisely what the README shows.
set clientSource /opt/convex/client/convex.tcl
if {![file exists $clientSource]} {
    set clientSource [file normalize [file join [file dirname [info script]] .. .. client convex.tcl]]
}
source $clientSource

proc whole_count {raw operation} {
    if {[catch {set count [::convex::field $raw count]}]} { error "$operation omitted count" }
    # Convex JSON can spell a whole number as 0.0. Accept that mathematical
    # integer, but reject fractions, strings, non-finite values, and overflow.
    if {![regexp {^-?(?:0|[1-9][0-9]*)(?:\.0+)?$} $count]} {
        error "$operation count was not a finite whole number"
    }
    regsub {\.0+$} $count "" normalized
    if {[catch {set whole [expr {wide($normalized)}]}]} { error "$operation count overflowed Tcl's integer range" }
    return $whole
}

proc example_update {kind payload logs} {
    global initialRaw updatedRaw waiting complete liveFailure
    if {$kind eq "error"} {
        set message [::convex::decode [::convex::field $payload message]]
        set liveFailure "Live query failed: $message"
        # Never throw from the socket callback. Wake whichever vwait owns the
        # example so the outer try reports the real failure and still cleans up.
        set waiting failed
        set complete -1
        return
    }
    if {$waiting eq "initial"} {
        set initialRaw $payload
        set waiting mutation
    } elseif {$waiting eq "updated"} {
        set updatedRaw $payload
        set complete 1
    }
}

# Tests source this canonical file to exercise the same decoder. A sourced
# example must define its helpers without contacting a deployment or printing.
if {[file normalize [info script]] ne [file normalize $::argv0]} { return }

set deployment [expr {[info exists ::env(CONVEX_URL)] ? $::env(CONVEX_URL) : ""}]
if {$deployment eq ""} { error "CONVEX_URL is required" }
set room [expr {$argc ? [lindex $argv 0] : "tcl-example"}]
set client [::convex::new $deployment]
set complete 0
set liveFailure ""

try {
    # Ask Convex once over HTTP before opening Live, to establish the fresh room.
    set current [::convex::query $client demo:state [::convex::object [list room [::convex::quote $room]]]]
    set currentCount [whole_count [dict get $current value] "current query"]
    if {$currentCount != 0} { error "current count was $currentCount, expected 0" }
    puts "current count: $currentCount"

    # Start Live first. Its initial value proves no mutation can slip between
    # subscription setup and the later idempotent write.
    set waiting initial
    set subscription [::convex::subscribe $client demo:state [::convex::object [list room [::convex::quote $room]]] [list example_update]]
    vwait waiting
    if {$liveFailure ne ""} { error $liveFailure }
    set initialCount [whole_count $initialRaw "initial Live value"]
    if {$initialCount != $currentCount} { error "initial Live count disagreed with HTTP" }
    puts "live initial count: $initialCount"

    # A unique runId is the mutation's idempotency key, so retrying this logical
    # request would not double-increment the room.
    # Arm the Live callback before the synchronous mutation returns. Otherwise
    # a fast server can deliver the update in the tiny gap below and leave the
    # example waiting for an event it already ignored.
    set waiting updated
    set mutation [::convex::mutation $client demo:increment [::convex::object [list room [::convex::quote $room] language [::convex::quote tcl] runId [::convex::quote [format %x [clock microseconds]]]]]]
    set mutationValue [::convex::decode [dict get $mutation value]]
    if {![dict get $mutationValue applied]} { error "mutation was not applied" }
    puts "mutation applied: true"
    set mutationCount [whole_count [::convex::field [dict get $mutation value] state] mutation]
    if {$mutationCount != 1} { error "mutation count was $mutationCount, expected 1" }
    puts "mutation count: $mutationCount"

    # Wait for the changed value from Live rather than issuing another query.
    if {$complete == 0} { vwait complete }
    if {$liveFailure ne ""} { error $liveFailure }
    set updatedCount [whole_count $updatedRaw "updated Live value"]
    if {$updatedCount != 1} { error "updated Live count was $updatedCount, expected 1" }
    puts "live updated count: $updatedCount"
    puts "verified count: 0 -> 1"
} finally {
    if {[info exists subscription]} { ::convex::unsubscribe $client $subscription }
    ::convex::close $client
}
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The public client is native Tcl 8.6.13. Tcllib supplies HTTP and JSON support,
TclTLS 1.7.22 supplies TLS, and the client implements Convex envelopes, error
classification, hostname checks, transport deadlines, WebSocket framing, and
Live state in Tcl. HTTP query, mutation, and action calls are synchronous. Live
uses nonblocking channels and Tcl's event loop to deliver `value` or `error`
callbacks.

Tcl values do not retain every distinction present in JSON. The client keeps
Convex values as raw JSON at important boundaries and validates exact tokens
before decoding them to Tcl values. That is why callers use helpers such as
`::convex::quote`, `::convex::object`, `::convex::field`, and
`::convex::decode` rather than handing arbitrary Tcl lists to the transport.

The Live implementation pins `convex-rs-0.10.4-unversioned-sync` at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It owns RFC 6455 parsing instead
of delegating to another Convex client, preserves partial frames across reads,
and reconnects active subscriptions. The final runtime contains Tcl, Tcllib,
TclTLS, CA certificates, OpenSSL's required runtime modules, and basic POSIX
tools, but no compiler or package manager.

Language-local Docker tests cover real loopback HTTP, TLS, and WebSocket peers,
strict errors, five reconnects, fragmented UTF-8, deadlines, response and frame
limits, stale-callback barriers, and stopped-reader memory bounds. The
test-only adapter speaks the repository's protocol and calls this same client;
it is not part of the educational API.

## Known Issues

1. Live authentication and `TransitionChunk` assembly are not implemented. A
   chunk is treated as recoverable protocol drift.
2. Values are limited to the JSON-safe subset. Tagged Convex Int64, bytes,
   special floats, and negative zero are deferred.
3. Mutations and actions use HTTP. Optimistic updates, journals, mutation
   replay, and WebSocket writes are not part of this client.
4. TclTLS verifies the certificate chain but not the host name, so this client
   performs its own peer-name check in the TLS callback.
5. Tcllib reports chunked HTTP progress one complete chunk at a time, so the
   2 MiB response limit can overshoot by the size of the current chunk.
