# Convex from Tcl

This demonstration uses Tcl to call Convex's documented JSON HTTP endpoints and
to keep a reactive query current through a native Tcl WebSocket connection.

It is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.tcl`](examples/basics/main.tcl) is the canonical example.
It reads a new counter room over HTTP, starts Live before changing it, applies
an idempotent mutation, and proves the same `0 -> 1` journey arrived through
the subscription. The block below is generated from that exact runnable file.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Awaiting shared verification | Native Tcl HTTP query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented. |
| Live | Awaiting shared verification | Native Tcl RFC 6455 subscriptions, unsubscribe, reconnect, reactive errors, and clean close target the pinned sync profile. |

No capability badge is earned until root-owned local and hosted black-box
conformance passes. A Docker build or a language-local test does not earn one.

## The basic example

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

# Tests source this canonical file to exercise the same decoder. A sourced
# example must define its helpers without contacting a deployment or printing.
if {[file normalize [info script]] ne [file normalize $::argv0]} { return }

set deployment [expr {[info exists ::env(CONVEX_URL)] ? $::env(CONVEX_URL) : ""}]
if {$deployment eq ""} { error "CONVEX_URL is required" }
set room [expr {$argc ? [lindex $argv 0] : "tcl-example"}]
set client [::convex::new $deployment]
set complete 0

proc example_update {kind payload logs} {
    global initialRaw updatedRaw waiting complete
    if {$kind eq "error"} { error "Live query failed: $payload" }
    if {$waiting eq "initial"} {
        set initialRaw $payload
        set waiting mutation
    } elseif {$waiting eq "updated"} {
        set updatedRaw $payload
        set complete 1
    }
}

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
    set initialCount [whole_count $initialRaw "initial Live value"]
    if {$initialCount != $currentCount} { error "initial Live count disagreed with HTTP" }
    puts "live initial count: $initialCount"

    # A unique runId is the mutation's idempotency key, so retrying this logical
    # request would not double-increment the room.
    set mutation [::convex::mutation $client demo:increment [::convex::object [list room [::convex::quote $room] language [::convex::quote tcl] runId [::convex::quote [format %x [clock microseconds]]]]]]
    set mutationValue [::convex::decode [dict get $mutation value]]
    if {![dict get $mutationValue applied]} { error "mutation was not applied" }
    puts "mutation applied: true"
    set mutationCount [whole_count [::convex::field [dict get $mutation value] state] mutation]
    if {$mutationCount != 1} { error "mutation count was $mutationCount, expected 1" }
    puts "mutation count: $mutationCount"

    # Wait for the changed value from Live rather than issuing another query.
    set waiting updated
    vwait complete
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

## Verify it in Docker

```sh
./run test tcl
./run verify-example tcl
./run verify tcl
./run verify-hosted tcl
./run verify-all tcl
```

`test` runs Tcl parsing and focused language-local checks inside Docker.
`verify-example` executes the canonical source above and compares its stdout
with the universal transcript. The remaining commands are root-owned shared
gates for the approved local and hosted deployments.

## Conformance and protocol notes

The test-only adapter under `client/tests/conformance/` speaks NDJSON protocol
v1 on stdin/stdout and TCP. It calls the real Tcl client for every operation.
Its adapter-only `debugDisconnect` command lets the shared harness prove five
real reconnects.

HTTP uses Convex's documented `format: "json"` endpoints. Live pins
`convex-rs-0.10.4-unversioned-sync` at
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and `/api/sync`. That realtime
protocol is not documented as stable, so hosted verification remains required.

## Limitations

- Live authentication and `TransitionChunk` assembly are intentionally not yet
  implemented. A chunk is treated as recoverable protocol drift.
- Values are limited to this experiment's JSON-safe subset. Tagged Convex
  Int64, bytes, special floats, and negative zero are outside scope.
- Mutations and actions use HTTP. Optimistic updates, journals, mutation replay,
  and WebSocket writes are deferred.
- The current focused tests do not yet prove all required real-socket lifecycle
  and backpressure cases. In particular, bytes accepted into Tcl's channel
  buffer are not included in the adapter's queued-byte accounting.
