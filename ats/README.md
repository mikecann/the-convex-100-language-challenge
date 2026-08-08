# Convex from ATS2

This demonstration queries a Convex room with ATS2, observes it over Live,
increments it, and checks the reactive value changes from `0` to `1`. ATS2
proves memory safety with dependent and linear types over a language that
compiles straight through C. That proof burden is spent deliberately here:
`convex_json.dats` walks a cJSON-parsed tree exactly once into a genuine ATS
algebraic datatype, and every predicate that actually interprets a Convex
value -- looking up a field, coalescing a sync-protocol Transition's
modifications, deciding whether a number is a whole count -- operates on
that ATS type through exhaustiveness-checked pattern matching, not on the C
tree.

It is educational and unofficial. It is not a production SDK, an officially
sanctioned Convex client, or a package intended for publication.

## Start here

[`examples/basics/main.dats`](examples/basics/main.dats) is the exact
program the Docker image runs and the website displays. Its comments
explain client setup, the initial HTTP query, starting Live before the
mutation, the idempotency key, and the final reactive assertion.

## What works

| Capability | Current state | What that means |
| --- | --- | --- |
| HTTP | Verified by shared local and hosted conformance | Native query, mutation, and action over the documented JSON API, including bearer token auth, logs, and typed `FunctionError`/`ProtocolError`/`TransportError` failures. |
| Live | Verified by shared local and hosted conformance | Native WebSocket subscriptions against the pinned `/api/sync` profile: initial value, external updates, unsubscribe, query-error recovery, and five real `debugDisconnect` reconnects with rehydration correctly suppressed. |

## Basic example

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

## Verify it in Docker

```sh
./run test ats
./run verify-example ats
./run verify ats
./run verify-hosted ats
./run verify-all ats
```

`test` builds every checked-in `.sats`/`.dats` source with `patscc`, which
performs ATS2's full dependent-type, linear-resource, and pattern-match
exhaustiveness check before running the language-local unit tests.
`verify-example` exercises the exact example above against a unique room.
The conformance commands are root-owned checks for the separate self-hosted
and dedicated hosted deployments.

## Conformance and protocol notes

HTTP calls use the documented `/api/query`, `/api/mutation`, and
`/api/action` JSON endpoints. Live uses the unversioned `/api/sync` profile
pinned to `convex-rs` 0.10.4 at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

ATS2 ships no HTTP, TLS, WebSocket, or JSON library. JSON parsing is
delegated to cJSON (Ubuntu's own `libcjson-dev`); `client/convex_json.dats`
walks its tree exactly once into a genuine ATS algebraic datatype at the FFI
boundary, and every accessor and the renderer both operate on that ATS type
afterward. `client/convex_transport.dats` reaches OpenSSL and POSIX sockets
through ATS's C foreign-language interface for the mechanical parts: TCP
connect, the TLS 1.2+ handshake with real certificate and hostname
verification against the system CA bundle, HTTP/1.1 response framing
(Content-Length and chunked), the RFC 6455 WebSocket opening handshake and
frame masking, base64, and `poll(2)`. Everything Convex-specific --
`/api/query`/`/api/mutation`/`/api/action` envelope decoding, the sync
protocol's `Connect`/`ModifyQuerySet`/`Transition` messages, version and
timestamp validation, and modification coalescing -- is written in ATS in
`client/convex.dats`.

The test-only adapter (`client/tests/conformance/adapter.dats`) accepts
NDJSON over stdin/stdout or one `ADAPTER_LISTEN` TCP connection. It is a
single reactor loop: one `poll(2)` call over the control channel and the
Live socket together, so exactly one piece of code ever reads, writes, or
reconnects the WebSocket. Pure command parsing and event-JSON shaping live
in `client/tests/conformance/adapter_logic.dats` so they can be unit tested
directly (`client/tests/conformance/adapter_test.dats`) without a live
process.

## Limitations

`patscc`/`patsopt` resolve `staload` paths relative to the invoking working
directory rather than the source file's own directory, and a `--dynamics`
build target cannot itself contain a directory component, so the Docker
build flattens the checked-in `client/` tree into one directory before
compiling; the checked-in source layout itself still follows AGENTS.md.

Live reconnect retries immediately rather than backing off exponentially
under sustained failure, and the inbound message queue is bounded only by
the shared 8 MiB per-frame limit, not by a dedicated slow-consumer count and
byte budget the way the Haskell and Prolog clients implement one. Growable
transport buffers (HTTP bodies, WebSocket frame payloads) are managed on
the C side of the FFI boundary rather than under a dependent size proof --
this client's dependent/linear-typing claim is in the JSON value tree and
the protocol-state handling, not in the raw byte transport. WebSocket
mutations/actions, `TransitionChunk` assembly, optimistic updates,
journals, replay, and Convex's non-JSON-safe value types are out of scope.
The runtime images contain the libraries the two final binaries link
against (libssl, libcrypto, libcjson, libc) plus OpenSSL's configuration
and provider modules, but no `patscc` compiler, package manager, or
delegated runtime. Realtime remains an internal protocol, so even passing
evidence would not make this an officially supported SDK.
