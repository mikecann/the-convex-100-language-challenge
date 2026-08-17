# MUMPS

[MUMPS](https://yottadb.com/heritage-legacy-m-mumps-future-yottadb/), usually
called M today, began in the late 1960s as a compact language for data-intensive
medical systems. Its defining model is a hierarchical associative array that
can live either in process-local memory or in the database. That combination
still has a practical niche in electronic health records. This demonstration
uses [YottaDB](https://yottadb.com/product/), a current implementation of M
that largely conforms to ISO/IEC 11756:1999.

This is an educational, unofficial experiment. It is not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Getting Started

Start with [`examples/basics/main.m`](examples/basics/main.m). It reads a
counter over HTTP, subscribes before changing it, applies one idempotent
mutation, then waits for the same change to arrive over Live.

From the repository root, run the canonical program in its Docker image against
a unique room on the approved local test deployment:

```sh
./run verify-example mumps
```

You do not need YottaDB installed on the host. The repository's Docker build
provides the pinned compiler and runtime.

## Interesting Parts

### A JSON reply becomes numbered nodes in a bounded array, not an object

MUMPS's name comes from its 1960s origin — the Massachusetts General Hospital
Utility Multi-Programming System — and its whole storage model has always been
the sparse, subscripted array. This client's JSON parser leans on that
heritage: a Convex response doesn't become an object, it becomes a tree of
numbered nodes in a local array, walked one lookup at a time.

```mumps
 new mark set mark=$$jMark^convex() ; Bound this parse's node allocation.
 new root set root=$$jParse^convex(response("value"))
 new node set node=$$jFind^convex(root,"count") ; Object lookup by exact key.
 if node<0!($$jType^convex(node)'="number") zhalt 1
 write $$jText^convex(node),! ; TypeScript: state.count, already type-checked.
 do jRelease^convex(mark) ; Free every node parsed since mark.
```

Nothing here knows Convex's generated TypeScript types exist; each field is
checked the moment it's read, and `mark`/`jRelease` cap how many nodes one
parse is allowed to allocate.

### Success is the return value; the payload comes back by reference

An M function returns exactly one value from `$$name(...)`, so this client
spends that slot on a plain success flag and hands back everything else
through arguments written with a leading dot — call by reference, resolved by
variable name rather than copied in.

```mumps
 new args set args="{"_q_"room"_q_":"_q_room_q_"}" ; q holds a quote char; _ concatenates.
 new response ; Declared empty; the callee fills it in as a side effect.
 if '$$query^convex("demo:state",args,.response) zhalt 1
 write response("value"),! ; TypeScript: const { value } = await client.query(...)
```

`response` is just local scratch space until the call returns — there's no
result object to destructure, only a variable the callee was trusted to set.

### Reactivity here is a blocking wait, not a re-render

React's `useQuery` subscribes once and lets a re-render carry every future
value. This command-line client has no event loop to hand that off to, so
`waitUpdate` parks the single M process until Convex's Live protocol delivers
the next transition or the deadline passes.

```mumps
 if '$$subscribe^convex("counter","demo:state",args) zhalt 1 ; Register Live before mutating.
 new hasError,errName,errMsg,value
 if '$$waitUpdate^convex("counter",15000,.hasError,.errName,.errMsg,.value) zhalt 1
 if hasError zhalt 1 ; A reactive query failure is an out parameter, not an exception.
 write value,! ; TypeScript: useQuery just re-renders the component.
```

Run a mutation and call `waitUpdate` again: the same line receives the pushed
update, proof the change arrived over the wire rather than from asking again.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Badge earned | Query, mutation, action, bearer-token lifecycle, logs, and structured errors are implemented and pass shared local and hosted black-box conformance. |
| Live | Badge earned | Subscribe/unsubscribe, reconnect-on-drop with exponential backoff, unchanged-rehydration suppression, reactive error recovery, and clean close are implemented and pass shared local and hosted black-box conformance, including a debugDisconnect-triggered five-reconnect proof and a QueryFailed-then-recovery cycle. |

Historical shared evaluator evidence awarded both badges with 31 of 31 checks
against a local backend and 31 of 31 against the hosted deployment over real
TLS. A clean run from parent commit `305e9a4` passed the canonical local
example, then failed while connecting the hosted mutation under YottaDB on
Docker Desktop's amd64 Rosetta path. This version therefore still needs a
native x86_64 hosted rerun before it has fresh exact-head evidence.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m -->
```mumps
main ; Convex from MUMPS: the shared counter journey.
 ;
 ; The program reads a room's counter over Convex's documented HTTP API,
 ; starts a Live subscription, increments the counter once, and proves that
 ; the Live subscription reported the same change without polling.
 ;
 ; Run it with: CONVEX_URL=https://<deployment>.convex.cloud mumps -run main^main <room>
 ;
 do setup^convex
 new status set status=$$run()
 zhalt $select(status=0:0,1:1)
 ;
run()
 new url,room,args,current,initial,updated,expected
 new q set q=$char(34)
 ;
 ; Configuration: the deployment URL is required; the room comes from the
 ; verifier's first command-line argument, an environment variable for a
 ; convenient hand run, or a literal fallback so the example still does
 ; something when run with neither.
 set url=$ztrnlnm("CONVEX_URL")
 if url="" write "MUMPS example failed: CONVEX_URL is required",! quit 1
 set room=$piece($zcmdline," ",1)
 if room="" set room=$ztrnlnm("EXAMPLE_ROOM")
 if room="" set room="mumps-example"
 ;
 ; Client creation: one native MUMPS client for the deployment the container
 ; names. `open` resolves the URL and mints a fresh Live session id; nothing
 ; has touched the network yet.
 if '$$open^convex(url,"mumps-0.1.0") quit $$bail($$errorMessage^convex())
 set args="{"_q_"room"_q_":"_q_room_q_"}"
 ;
 ; Read the current value through Convex's documented HTTP query endpoint.
 new response
 if '$$query^convex("demo:state",args,.response) quit $$bail("query: "_$$errorMessage^convex())
 set current=$$count(response("value"),"current query")
 if current=-1 quit $$bail("")
 write "current count: ",current,!
 ;
 ; Start Live before mutating. Subscribing first is what makes the update
 ; below an observation rather than a race.
 if '$$subscribe^convex("counter","demo:state",args) quit $$bail("subscribe: "_$$errorMessage^convex())
 ;
 ; The first Live value hydrates the same state the HTTP query returned.
 set initial=$$next("initial Live value")
 if initial=-1 quit $$bail("")
 if initial'=current quit $$bail("the initial Live count disagreed with HTTP")
 write "live initial count: ",initial,!
 ;
 ; runId is the mutation's idempotency key. Convex records it, so a repeated
 ; run of the same key returns the previous result instead of incrementing
 ; twice. A fresh random key means this run really applies its increment.
 new mutation set mutation="{"_q_"room"_q_":"_q_room_q_","_q_"language"_q_":"_q_"mumps"_q_","_q_"runId"_q_":"_q_$$randomHex^convex(16)_q_"}"
 if '$$mutation^convex("demo:increment",mutation,.response) quit $$bail("mutation: "_$$errorMessage^convex())
 ;
 new mark,root,appliedNode,stateNode,applied,state
 set mark=$$jMark^convex()
 set root=$$jParse^convex(response("value"))
 set appliedNode=$select(root<0:-1,1:$$jFind^convex(root,"applied"))
 set stateNode=$select(root<0:-1,1:$$jFind^convex(root,"state"))
 set applied=$select(appliedNode>=0:$$jType^convex(appliedNode),1:"")
 set state=$select(stateNode>=0:$$jEncode^convex(stateNode),1:"")
 do jRelease^convex(mark)
 if applied'="true" quit $$bail("the mutation was not applied")
 ;
 set expected=current+1
 set state=$$count(state,"mutation")
 if state=-1 quit $$bail("")
 if state'=expected quit $$bail("the mutation returned an unexpected count")
 write "mutation applied: true",!
 write "mutation count: ",state,!
 ;
 ; Receive the same change over Live, without polling HTTP again.
 set updated=$$next("updated Live value")
 if updated=-1 quit $$bail("")
 if updated'=expected quit $$bail("the updated Live count disagreed with the mutation")
 write "live updated count: ",updated,!
 ;
 ; Every operation agreed before this proof line is printed.
 write "verified count: ",current," -> ",updated,!
 do closeLive^convex(2000)
 quit 0
 ;
 ; Wait for the next value this subscription publishes, and surface a
 ; reactive query failure as a failure rather than as a missing value.
next(operation)
 new hasError,errName,errMsg,value
 if '$$waitUpdate^convex("counter",15000,.hasError,.errName,.errMsg,.value) quit $$bail(operation_": "_$$errorMessage^convex())
 if hasError quit $$bail(operation_": "_errMsg)
 quit $$count(value,operation)
 ;
 ; Convex returns the room state as a JSON object. This narrows it to the
 ; non-negative integer the output contract needs, and refuses anything else.
count(value,operation)
 new mark,root,node,literal,result
 set mark=$$jMark^convex()
 set root=$$jParse^convex(value)
 if root<0!($$jType^convex(root)'="object") do  quit -1
 . do jRelease^convex(mark)
 . new discard set discard=$$bail(operation_" did not return a Convex object")
 set node=$$jFind^convex(root,"count")
 if node<0!($$jType^convex(node)'="number") do  quit -1
 . do jRelease^convex(mark)
 . new discard set discard=$$bail(operation_" returned no count")
 set literal=$$jText^convex(node)
 do jRelease^convex(mark)
 ; Convex JSON may encode an integral number as 0 or as 0.0. Both are
 ; accepted; fractional, non-finite, and out-of-range values are not.
 if '$$integral^convex(literal)!(literal<0) quit $$bail(operation_" returned a non-integral or negative count")
 quit literal+0
 ;
 ; One failure channel. Diagnostics belong on stderr so that stdout stays the
 ; exact shared transcript.
bail(message)
 do closeLive^convex(2000)
 ; `/dev/stderr` is a Unix path, not automatically an M device. The final
 ; image deliberately has no `/tmp`; a hosted transport failure used to reach
 ; this branch and then fatal with IONOTOPEN before it could print its real
 ; diagnostic. Open the already-mounted stderr stream first, just as the
 ; adapter does, so error handling remains safe in that stripped image.
 if message'="" open "/dev/stderr":append:5 use "/dev/stderr" write "MUMPS example failed: ",message,! use $principal
 quit -1
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The implementation is native M. It uses YottaDB's own
`OPEN`/`USE`/`READ`/`WRITE` device commands for TCP sockets, and `WRITE /TLS`
for encryption. Those commands are documented in YottaDB's official
[I/O guide](https://docs.yottadb.com/ProgrammersGuide/ioproc.html). JSON,
HTTP/1.1, WebSocket framing, SHA-1, base64, and the Convex-specific behavior are
implemented in [`client/convex.m`](client/convex.m), not delegated to another
Convex client.

YottaDB r2.06 is installed and compiled entirely inside Docker. The language
test target compiles every checked-in M routine, runs JSON and cryptographic
unit tests offline, then exercises HTTP and Live through real loopback sockets:

```sh
./run test mumps
./run verify-example mumps
./run verify mumps
./run verify-hosted mumps
./run verify-all mumps
```

These commands prove different layers. `test` covers compilation and
language-local behavior. `verify-example` runs the exact example above.
`verify` adds local black-box conformance, `verify-hosted` checks the hosted
drift target over TLS, and `verify-all` runs both deployment profiles from one
build. The existing badge evidence described in Status comes from the shared
evaluator, not from this README edit.

The client speaks the repository's pinned `convex-rs@6f1df8a8` sync profile at
`/api/sync`. Its Live loop is single-threaded and keeps only the newest value
for each subscription. The conformance adapter adds a bounded queue of eight
entries and 4 MiB, dropping old subscription updates before control responses.
Reconnect delay starts at 250 ms, doubles up to 30 seconds, and resets after a
successful handshake. Active subscriptions are resent after reconnect, while
an unchanged first value is suppressed.

One small C transport shim remains: [`client/sni_shim.c`](client/sni_shim.c)
adds TLS Server Name Indication before YottaDB's OpenSSL plugin connects. It
contains no Convex, HTTP, JSON, or WebSocket behavior. YottaDB still attaches a
database region when each process starts, although this client uses only local
variables and never references a persistent `^global`; the image therefore
contains an unused region created at build time.

## Known Issues

1. Live authentication, mutations and actions sent over WebSocket, journals,
   and `TransitionChunk` assembly are deferred. Receiving a `TransitionChunk`
   is treated as protocol drift and triggers a reconnect.
2. The client retains only the latest unread Live value per subscription. A
   slow consumer sees the newest state rather than every intermediate update.
3. The runtime deliberately uses byte-oriented M mode (`ydb_chset=M`) rather
   than YottaDB's UTF-8 engine. JSON bytes pass through unchanged, and the
   client parser validates string escapes, but the runtime does not provide
   general Unicode-aware M string operations.
4. Hosted TLS depends on the narrow SNI shim described above because YottaDB's
   TLS plugin does not set the hostname itself.
5. On Docker Desktop's amd64 Rosetta path, YottaDB intermittently fails
   hostname connections even though direct connections to either resolved IP
   work and hosted Live has passed separately. The clean parent-commit run
   described in Status reproduced this during the hosted mutation, so the
   remaining verification belongs on a native x86_64 host rather than in a
   weakened client or harness workaround.
