<img src="logo.png" alt="ATS logo" width="140">
<!-- Logo source: https://www.cs.bu.edu/~hwxi/atslangweb/MYDATA/theLogo.png -->

# ATS2

ATS2 is a statically typed language created by Hongwei Xi to bring formal
specification and implementation into the same program. Its functional core is
influenced by ML, its low-level side is comfortable around C, and its best-known
features are dependent and linear types. Postiats compiles ATS2 to C99, which is
why ATS still has a niche in systems work, refinement-based development, and
teaching type theory rather than mainstream application development. The
[official ATS site](https://www.ats-lang.org/) is the best starting point.

This repository uses those ideas to query, mutate, and observe a Convex counter.
It is an educational, unofficial demonstration, not a production SDK, an
officially sanctioned Convex client, or a package intended for publication.

## Getting Started

The [canonical example](examples/basics/main.dats) follows one room from `0` to
`1` through an HTTP query, a Live subscription, and an idempotent mutation. From
the repository root, Docker builds and runs that exact program against a unique
test room:

```sh
./run verify-example ats
```

## Interesting Parts

### Three matches stand between JSON and an int

ATS descends from Hongwei Xi's Dependent ML, and it shows in everyday code:
`case+` is pattern matching that treats a missing branch as a compile error,
not a warning. Convex responses arrive as a local `json` datatype, so reaching
the counter means winning three matches in a row.

```ats
(* TypeScript: state.count -- the generated api already guarantees the shape. *)
fun whole_count(operation: string, j: json): int =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("count", j) of
      | JOSome(cj) => (
          case+ json_integral_int(cj) of
          | IOSome(n) => n
          | IONone() => (fail_with(sc2(operation, " did not contain a whole count")); 0)
        )
      | JONone() => (fail_with(sc2(operation, " did not contain a whole count")); 0)
    )
  | _ => (fail_with(sc2(operation, " was not an object")); 0)
```

`json_integral_int` rejects fractional, non-finite, and out-of-range numbers
outright, so by the time you hold an `int`, there is nothing left to doubt.

### The C is pasted straight into the program

Postiats compiles ATS2 to C99, and the language leans into it: a `%{^ ... %}`
block is verbatim C dropped into the source file, and `mac#` binds it to an ATS
name. Look at `out_present` — the type `&int? >> int` says this by-reference
argument arrives *possibly uninitialized* and leaves definitely initialized.
The type system tracks that transition across the call.

```ats
%{^
#include <stdlib.h>
static char *c_getenv_impl(const char *name, int *out_present) {
    char *v = getenv(name);
    *out_present = (v != NULL);
    return v != NULL ? v : "";
}
%}
(* TypeScript: const url = process.env.CONVEX_URL *)
extern fun c_getenv(name: string, out_present: &int? >> int): string = "mac#c_getenv_impl"
```

The entire TLS, HTTP, and WebSocket transport crosses this same boundary in
[`convex_transport`](client/convex_transport.sats).

### The subscription is a value you hand forward

No hidden object mutates behind your back: `live_state` is an immutable value,
and every Live operation returns the next one. Watching the counter go `0 -> 1`
means handing `st0`, `st1`, `st2`... forward, one snapshot at a time.

```ats
case+ live_add(conn, st0, "demo:state", roomArgs) of
| AddErr(msg) => (live_close(conn); fail_with(sc2("could not subscribe: ", msg)))
| AddOk(queryId, st1) => let
    (* TypeScript: useQuery(api.demo.state, { room }) -- React threads all this for you. *)
    val (initialV, st2) = await_live(conn, st1, queryId, "initial Live value")
    (* ... the demo:increment mutation lands here ... *)
    val (updatedV, st3) = await_live(conn, st2, queryId, "updated Live value")
    val st4 = live_remove(conn, st3, queryId)
    val () = live_close(conn)
  in () end
```

Because the subscription starts before the mutation is sent, the update cannot
be missed — the same guarantee React gives you, spelled out in values.

### Mutation arguments are cons cells all the way down

ATS has no record-literal syntax for ad-hoc JSON, so this client builds objects
the classic ML way: a hand-rolled linked list of key/value pairs, constructed
inside-out with `JFLCons`.

```ats
(* TypeScript: increment({ room, language: "ats", runId: crypto.randomUUID() }) *)
val runId = random_hex(16)
val mutArgs = JObj(JFLCons("room", JStr(room),
  JFLCons("language", JStr("ats"), JFLCons("runId", JStr(runId), JFLNil()))))
```

`http_mutation(c, "demo:increment", mutArgs)` posts it; the fresh `runId` makes
the increment idempotent, and `jobj1` hides the cons cells for one-key objects.

## Status

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native query, mutation, and action over the documented JSON API, including bearer-token auth, logs, and structured function, protocol, and transport failures. |
| Live | Verified by shared local and hosted conformance | Native WebSocket subscriptions against the pinned `/api/sync` profile, including initial and external updates, unsubscribe, query-error recovery, and five real reconnects. |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.dats -->
```text
(*
** Convex from ATS: the canonical shared counter demonstration.
**
** Walks the same 0 -> 1 journey every language in this project
** demonstrates: an HTTP query for the current count, a Live subscription
** started before any write so the reactive path cannot miss it, an
** idempotent mutation, and the resulting Live update -- proving HTTP and
** Live agree about the same room.
*)
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"

%{^
#include <stdlib.h>
#include <string.h>
static char *c_getenv_impl(const char *name, int *out_present) {
    char *v = getenv(name);
    *out_present = (v != NULL);
    return v != NULL ? v : "";
}
%}
extern fun c_getenv(name: string, out_present: &int? >> int): string = "mac#c_getenv_impl"
extern fun c_concat(a: string, b: string): string = "mac#c_concat"
extern fun c_int_to_string(i: int): string = "mac#c_int_to_string"
fun sc2(a: string, b: string): string = c_concat(a, b)
fun sc3(a: string, b: string, c: string): string = sc2(sc2(a, b), c)

(* println! resolves its printable-argument overload polymorphically, which
   gets ambiguous with this file's own datatypes in scope; every line of
   this example's happy-path transcript is built as one plain string
   instead and printed with a single, unambiguous call. *)
%{^
#include <stdio.h>
static void c_println(const char *s) { puts(s); }
static void c_eprintln(const char *s) { fprintf(stderr, "%s\n", s); }
%}
extern fun c_println(s: string): void = "mac#c_println"
extern fun c_eprintln(s: string): void = "mac#c_eprintln"

fun fail_with(msg: string): void = let
  val () = c_eprintln(sc2("ats example failed: ", msg))
in
  exit(1)
end

fun whole_count(operation: string, j: json): int =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("count", j) of
      | JOSome(cj) => (
          case+ json_integral_int(cj) of
          | IOSome(n) => n
          | IONone() => (fail_with(sc2(operation, " did not contain a whole count")); 0)
        )
      | JONone() => (fail_with(sc2(operation, " did not contain a whole count")); 0)
    )
  | _ => (fail_with(sc2(operation, " was not an object")); 0)

fun mutation_applied(j: json): bool =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("applied", j) of
      | JOSome(JBool(b)) => b
      | _ => false
    )
  | _ => false

fun mutation_state(j: json): json =
  case+ j of
  | JObj(_) => (
      case+ json_lookup("state", j) of
      | JOSome(v) => v
      | JONone() => (fail_with("mutation response omitted state"); JNull())
    )
  | _ => (fail_with("mutation response omitted state"); JNull())

fun error_msg(e: convex_error): string =
  case+ e of
  | FunctionErr(msg, _, _) => msg
  | ProtocolErr(msg) => msg
  | TransportErr(msg) => msg

datatype live_wait_result = LWROk of (json, live_state) | LWRFailed
datatype change_result = CHNone | CHValue of json | CHError of convex_error

fun find_change(changes: changelist, queryId: int): change_result =
  case+ changes of
  | CLNil() => CHNone()
  | CLCons(LiveValue(qid, v, _), rest) => if qid = queryId then CHValue(v) else find_change(rest, queryId)
  | CLCons(LiveQueryError(qid, e, _), rest) => if qid = queryId then CHError(e) else find_change(rest, queryId)

fun await_live_loop(conn: live_conn, st: live_state, queryId: int, label: string, triesLeft: int): live_wait_result =
  if triesLeft <= 0 then (fail_with(sc2(label, " timed out")); LWRFailed())
  else let
    val pr = poll_control(~1, live_fd(conn), 100)
  in
    if pr = POLL_LIVE orelse pr = POLL_BOTH then (
      case+ live_poll(conn, st) of
      | LiveTransition(st1, changes) => (
          case+ find_change(changes, queryId) of
          | CHNone() => await_live_loop(conn, st1, queryId, label, triesLeft - 1)
          | CHValue(v) => LWROk(v, st1)
          | CHError(e) => (fail_with(sc2(label, sc2(" was an error: ", error_msg(e)))); LWRFailed())
        )
      | LivePing() => await_live_loop(conn, st, queryId, label, triesLeft - 1)
      | LiveIgnored() => await_live_loop(conn, st, queryId, label, triesLeft - 1)
      | LiveWouldBlock() => await_live_loop(conn, st, queryId, label, triesLeft - 1)
      | LiveProtocolError(msg) => (fail_with(sc2(label, sc2(": protocol error: ", msg))); LWRFailed())
      | LivePeerClosed() => (fail_with(sc2(label, ": connection closed")); LWRFailed())
    )
    else await_live_loop(conn, st, queryId, label, triesLeft - 1)
  end

fun await_live(conn: live_conn, st: live_state, queryId: int, label: string): (json, live_state) =
  case+ await_live_loop(conn, st, queryId, label, 100) of
  | LWROk(v, st1) => (v, st1)
  | LWRFailed() => (JNull(), st)  (* unreachable: await_live_loop already exited on failure *)

implement main0(argc, argv) = let
  var present: int
  val url = c_getenv("CONVEX_URL", present)
in
  if present = 0 then fail_with("CONVEX_URL is required")
  else (
    case+ new_client(url) of
    | CONone() => fail_with("CONVEX_URL is not a valid Convex deployment URL")
    | COSome(c) => let
        val room = if argc >= 2 then argv[1] else "ats-example"
        val roomArgs = jobj1("room", JStr(room))
      in
        case+ http_query(c, "demo:state", roomArgs) of
        | CallErr(e) => fail_with(sc2("current query failed: ", error_msg(e)))
        | CallOk(qv, _) => let
            val currentCount = whole_count("current query", qv)
            val () = c_println(sc2("current count: ", c_int_to_string(currentCount)))
          in
            case+ live_connect(c) of
            | LiveErr(e) => fail_with(sc2("Live connect failed: ", error_msg(e)))
            | LiveOkConn(conn, st0) => (
                case+ live_add(conn, st0, "demo:state", roomArgs) of
                | AddErr(msg) => (live_close(conn); fail_with(sc2("could not subscribe: ", msg)))
                | AddOk(queryId, st1) => let
                    val (initialV, st2) = await_live(conn, st1, queryId, "initial Live value")
                    val initialCount = whole_count("initial Live value", initialV)
                    val () = if initialCount <> currentCount
                      then fail_with("Live initial value disagreed with HTTP") else ()
                    val () = c_println(sc2("live initial count: ", c_int_to_string(initialCount)))
                    val runId = random_hex(16)
                    val mutArgs = JObj(JFLCons("room", JStr(room),
                      JFLCons("language", JStr("ats"), JFLCons("runId", JStr(runId), JFLNil()))))
                  in
                    case+ http_mutation(c, "demo:increment", mutArgs) of
                    | CallErr(e) => (live_close(conn); fail_with(sc2("mutation failed: ", error_msg(e))))
                    | CallOk(mv, _) => let
                        val applied = mutation_applied(mv)
                        val appliedWord: string = (if applied then "true" else "false")
                        val () = c_println(sc2("mutation applied: ", appliedWord))
                        val mutationCount = whole_count("mutation", mutation_state(mv))
                        val () = if mutationCount <> currentCount + 1
                          then fail_with("mutation count was unexpected") else ()
                        val () = c_println(sc2("mutation count: ", c_int_to_string(mutationCount)))
                        val (updatedV, st3) = await_live(conn, st2, queryId, "updated Live value")
                        val updatedCount = whole_count("updated Live value", updatedV)
                        val () = if updatedCount <> mutationCount
                          then fail_with("Live update was unexpected") else ()
                        val () = c_println(sc2("live updated count: ", c_int_to_string(updatedCount)))
                        val () = c_println(sc3(
                          sc2("verified count: ", c_int_to_string(currentCount)),
                          " -> ", c_int_to_string(updatedCount)))
                        val st4 = live_remove(conn, st3, queryId)
                        val () = live_close(conn)
                      in
                        ()
                      end
                  end
              )
          end
      end
  )
end
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native ATS2 implementation. cJSON parses incoming text, then
[`client/convex_json.dats`](client/convex_json.dats) walks that C tree once into
an ATS algebraic datatype. Convex-specific request envelopes, result decoding,
Live state, and update coalescing stay in
[`client/convex.dats`](client/convex.dats). OpenSSL and POSIX sockets provide
TLS, HTTP, WebSocket, and polling through ATS's C foreign-function interface.

That boundary matters. ATS2 supports dependent and linear types, but this client
does not claim that every network byte is tracked by such a proof. Its growable
HTTP and WebSocket buffers live in the C transport shim. The ATS side gains
ordinary algebraic types and exhaustive `case+` matching for JSON and client
results, while the test adapter uses one reactor loop as the sole owner of Live
socket reads, writes, and reconnects.

The Docker build uses ATS2/Postiats `0.4.2-1.1` on `linux/amd64`. It temporarily
flattens the source tree because `patsopt --dynamics` resolves `staload` paths
from its working directory. The final images contain the compiled program,
OpenSSL, cJSON, libc, CA data, and basic verifier tools, but no ATS compiler or
package manager. Live targets the unversioned `/api/sync` behavior pinned to
`convex-rs` 0.10.4 at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

## Known Issues

1. Reconnect retries immediately during sustained failure instead of using
   exponential backoff.
2. Incoming Live data has an 8 MiB per-frame limit, but no separate aggregate
   count and byte budget for a slow consumer.
3. Growable transport buffers are managed in C rather than covered by an ATS
   dependent-size proof.
4. The educational client supports JSON-safe Convex values only.
