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

### A JSON value has to earn its shape

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function CounterRead() {
  const state = useQuery(api.demo.state, { room: "ats-json-read" });
  if (state === undefined) return <span>Loading...</span>;

  return <span>{state.count}</span>; // state.count is type-safe here.
}
```

**ATS2**

```ats
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"

(* The caller passes its validated CONVEX_URL rather than baking in a deployment. *)
fun read_count(deploymentUrl: string): int =
  case+ new_client(deploymentUrl) of
  | CONone() => (exit(1); 0)
  | COSome(client) => (
      case+ http_query(client, "demo:state", jobj1("room", JStr("ats-json-read"))) of
      | CallErr(_) => (exit(1); 0)
      | CallOk(value, _) => (
          case+ json_lookup("count", value) of
          | JONone() => (exit(1); 0)
          | JOSome(countJson) => (
              case+ json_integral_int(countJson) of
              | IONone() => (exit(1); 0)
              | IOSome(count) => count
              (* count is an ATS int only after every shape check succeeds. *)
            )
        )
    )
```

React gets the return type from Convex's generated API. This ATS client instead
receives its one-off HTTP result as the local `json` datatype, then uses
exhaustive pattern matching and a checked whole-number conversion. ATS does not
know the `demo:state` schema ahead of time in this implementation.

### React owns Live for you; this program owns it directly

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function LiveCounter() {
  const room = "ats-live-room";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  const bump = () =>
    increment({ room, language: "typescript", runId: crypto.randomUUID() });

  // React starts, updates, and disposes the subscription with the component.
  return <button onClick={bump}>{state?.count ?? "Loading..."}</button>;
}
```

**ATS2**

```ats
#include "share/atspre_staload.hats"
staload "./convex_json.sats"
staload "./convex_transport.sats"
staload "./convex.sats"

(* This is the signature of await_live from examples/basics/main.dats. *)
extern fun await_live(conn: live_conn, state: live_state, queryId: int,
  label: string): (json, live_state)

(* The caller passes its validated CONVEX_URL rather than baking in a deployment. *)
fun increment_with_live(deploymentUrl: string): void =
  case+ new_client(deploymentUrl) of
  | CONone() => exit(1)
  | COSome(client) => (
      case+ live_connect(client) of
      | LiveErr(_) => exit(1)
      | LiveOkConn(conn, state0) => (
          case+ live_add(conn, state0, "demo:state",
              jobj1("room", JStr("ats-live-room"))) of
          | AddErr(_) => (live_close(conn); exit(1))
          | AddOk(queryId, state1) => let
              (* The canonical await_live helper polls until this queryId changes. *)
              val (_, state2) = await_live(conn, state1, queryId, "initial value")
              val runId = random_hex(16) (* A fresh id makes this increment idempotent. *)
              val mutationArgs = JObj(JFLCons("room", JStr("ats-live-room"),
                JFLCons("language", JStr("ats"), JFLCons("runId", JStr(runId), JFLNil()))))
            in
              case+ http_mutation(client, "demo:increment", mutationArgs) of
              | CallErr(_) => (live_close(conn); exit(1))
              | CallOk(_, _) => let
                  (* Live was started first, so this observes the mutation. *)
                  val (_, state3) = await_live(conn, state2, queryId, "updated value")
                  val state4 = live_remove(conn, state3, queryId)
                  val () = live_close(conn) (* This program owns cleanup explicitly. *)
                in
                  ()
                end
            end
        )
    )
```

The ATS language can support other concurrency styles. The blocking
`await_live` helper and explicit state threading are choices made by this small
client. Unlike `useQuery`, it has no component lifecycle to perform cleanup.
The [full example](examples/basics/main.dats) includes every result check omitted
from this focused comparison.

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
