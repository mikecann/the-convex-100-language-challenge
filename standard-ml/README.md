# Standard ML

[Standard ML](https://www.smlnj.org/sml.html) is a strict functional language
with type inference, pattern matching, algebraic data types, and a powerful
module system. It was proposed in 1983, designed from 1984 to 1988, and revised
as [Standard ML '97](https://www.smlnj.org/sml97.html). The language is formally
defined rather than owned by one implementation.

This client uses [Poly/ML](https://www.polyml.org/), an implementation whose
modern niche includes large theorem-proving systems such as Isabelle and HOL4.
It is an educational, unofficial Convex client, not a production SDK or a
package intended for publication.

## Getting Started

The canonical [`examples/basics/main.sml`](examples/basics/main.sml) program
queries a fresh counter, starts a Live subscription, applies one idempotent
mutation, and checks that every view agrees on `0 -> 1`.

From the repository root, Docker builds the pinned Poly/ML environment and runs
that exact example against a unique room:

```sh
./run verify-example standard-ml
```

## Interesting Parts

### JSON becomes a value you must narrow

Generated Convex bindings make the query result statically known in React. This
Standard ML client deliberately exposes the wire-neutral `Json.value` algebraic
data type instead, so pattern matching makes every accepted shape explicit.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function Counter() {
  const [room] = useState(() => `readme-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

**Standard ML**

```sml
val deployment =
  case OS.Process.getEnv "CONVEX_URL" of
      SOME url => if url = "" then raise Fail "CONVEX_URL is required" else url
    | NONE => raise Fail "CONVEX_URL is required"
val room = "readme-" ^ Rand.hex 16
val client = Convex.client deployment

(* The HTTP call returns generic JSON, so the program checks the object field
   and accepts only a mathematically integral Convex number. *)
val {value = state, ...} =
  Convex.query
    (client, "demo:state", Json.Object [("room", Json.String room)])
val count =
  case Json.asInt (Json.getOr (state, "count", Json.Null)) of
      SOME value => value
    | NONE => raise Fail "demo:state returned a non-integral count"
val _ = Convex.close client
```

The React hook is reactive and owns a subscription. `Convex.query` above is a
one-off HTTP request, so the comparison is about result typing, not lifecycle.
Standard ML knows that `count` is an `IntInf.int` after the match, but the JSON
field name and shape are checked at runtime because this demo has no generated
bindings.

### Live has an explicit lifetime

React ties a query subscription to a component. This command-line API makes the
same resource visible: subscribe before mutating, wait for updates, then always
unsubscribe and close the client.

**TypeScript with React**

```tsx
import { useState } from "react";
import { useMutation, useQuery } from "convex/react";
import { api } from "../convex/_generated/api";

export function IncrementButton() {
  const [room] = useState(() => `readme-${crypto.randomUUID()}`);
  const state = useQuery(api.demo.state, { room }); // React owns Live cleanup.
  const increment = useMutation(api.demo.increment);

  async function addOne() {
    const result = await increment({
      room,
      language: "typescript",
      runId: crypto.randomUUID(), // A fresh id makes this attempt idempotent.
    });
    console.log(result.state.count); // The mutation result is type-safe.
  }

  return <button onClick={addOne}>Count: {state?.count ?? 0}</button>;
}
```

**Standard ML**

```sml
val deployment =
  case OS.Process.getEnv "CONVEX_URL" of
      SOME url => if url = "" then raise Fail "CONVEX_URL is required" else url
    | NONE => raise Fail "CONVEX_URL is required"
val room = "readme-" ^ Rand.hex 16
val client = Convex.client deployment
val live =
  Convex.subscribe
    (client, "demo:state", Json.Object [("room", Json.String room)])

fun nextValue () =
  case Convex.next (live, 10.0) of
      NONE => raise Fail "Live update timed out"
    | SOME update =>
        (case Convex.updateError update of
             SOME failure => raise ConvexError.Error failure
           | NONE => Convex.updateValue update)

fun run () =
  let
    val initial = nextValue () (* The subscription hydrates before mutation. *)
    val {value = result, ...} =
      Convex.mutation
        (client, "demo:increment",
         Json.Object
           [("room", Json.String room),
            ("language", Json.String "standard-ml"),
            ("runId", Json.String (Rand.hex 16))])
    val updated = nextValue () (* This is the reactive result, not a new query. *)
  in
    (initial, result, updated)
  end

(* Both resources are explicit, so every exit path releases both. *)
fun cleanup () =
  ((Convex.unsubscribe live handle _ => ());
   Convex.close client handle _ => ())
val result =
  run ()
  handle error => (cleanup (); raise error)
val _ = cleanup ()
```

Blocking `Convex.next` is this client's small command-line API choice, not a
limitation of Standard ML. Poly/ML provides threads, and the implementation has
one owner thread handling WebSocket I/O and reconnects while callers consume a
bounded update queue.

## Status

Both intended capabilities are awarded from the repository's existing clean,
exact-head evidence. Local and hosted shared conformance each passed 31 of 31
checks.

| Capability | Status | Evidence |
| --- | --- | --- |
| HTTP | Awarded | Queries, mutations, actions, auth, structured errors, strict framing, TLS, and deadlines passed |
| Live | Awarded | Initial values, updates, errors, unsubscribe barriers, bounded delivery, and five reconnects passed |
| Implementation | Native | Convex HTTP and Live behaviour is implemented in Standard ML; OpenSSL supplies TLS only |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sml -->
```sml
(* The canonical Convex-from-Standard-ML example.

   It proves one shared counter goes from 0 to 1 and that three independent
   views of that change agree: the HTTP query, the mutation's own result, and
   the reactive Live update. *)

structure Example =
struct
  (* Generic JSON arrives as a Json.value. Narrow it to the non-negative
     integer this program's output contract needs, and say which step failed if
     it is anything else. *)
  fun exampleCount (value, step) =
    case Json.asInt (Json.getOr (value, "count", Json.Null)) of
        SOME count =>
          if count >= 0 andalso count <= 9223372036854775807 then count
          else raise Fail (step ^ " returned an out-of-range count")
      | NONE => raise Fail (step ^ " returned a non-integral count")

  (* runId is the mutation's idempotency key, so it has to be fresh and
     unpredictable. Reading the kernel's random pool keeps that inside the
     client rather than delegating to a CLI or a second runtime. *)
  fun freshRunId () = Rand.hex 16

  (* Live delivers either a value or a structured failure. Raise the failure
     rather than letting the example continue on a value it never received. *)
  fun nextLiveValue (subscription, step) =
    case Convex.next (subscription, 10.0) of
        NONE => raise Fail (step ^ " timed out")
      | SOME update =>
          (case Convex.updateError update of
               SOME failure => raise ConvexError.Error failure
             | NONE => Convex.updateValue update)

  fun room () =
    case CommandLine.arguments () of
        first :: _ => first
      | [] =>
          (* The verifier passes a unique room as the first argument; this
             default only exists for someone running the image by hand. *)
          (case OS.Process.getEnv "EXAMPLE_ROOM" of
               SOME name => name
             | NONE => "standard-ml-example")

  fun run () =
    let
      (* Configuration comes from the runtime container, never from a file
         baked into the image. *)
      val deployment =
        case OS.Process.getEnv "CONVEX_URL" of
            SOME url => if url = "" then raise Fail "CONVEX_URL is required" else url
          | NONE => raise Fail "CONVEX_URL is required"
      val space = room ()
      (* One client serves both the HTTP calls and the Live subscription. *)
      val client = Convex.client deployment
      val subscription = ref NONE
      fun cleanup () =
        ((case !subscription of
              SOME item => (Convex.unsubscribe item handle _ => ())
            | NONE => ());
         Convex.close client handle _ => ())
      fun body () =
        let
          (* Read the current state through Convex's documented HTTP endpoint. *)
          val {value = queried, ...} =
            Convex.query (client, "demo:state", Json.Object [("room", Json.String space)])
          val current = exampleCount (queried, "current query")
          val _ = print ("current count: " ^ IntInf.toString current ^ "\n")

          (* Subscribe before mutating. Starting Live first is what guarantees
             the reactive update cannot be missed. *)
          val live =
            Convex.subscribe (client, "demo:state", Json.Object [("room", Json.String space)])
          val _ = subscription := SOME live

          (* The first Live value hydrates the same state the query just read. *)
          val initial =
            exampleCount (nextLiveValue (live, "initial Live value"), "initial Live value")
          val _ =
            if initial = current then ()
            else raise Fail "initial Live count disagreed with the HTTP query"
          val _ = print ("live initial count: " ^ IntInf.toString initial ^ "\n")

          (* Apply exactly one increment. Reusing a runId returns the earlier
             result instead of incrementing twice. *)
          val {value = mutated, ...} =
            Convex.mutation
              (client, "demo:increment",
               Json.Object
                 [("room", Json.String space),
                  ("language", Json.String "standard-ml"),
                  ("runId", Json.String (freshRunId ()))])
          val applied = Json.asBool (Json.getOr (mutated, "applied", Json.Null))
          val mutationCount =
            exampleCount (Json.getOr (mutated, "state", Json.Null), "mutation")
          val expected = current + 1
          val _ = if applied = SOME true then () else raise Fail "mutation was not applied"
          val _ =
            if mutationCount = expected then ()
            else raise Fail "mutation returned an unexpected count"
          val _ = print "mutation applied: true\n"
          val _ = print ("mutation count: " ^ IntInf.toString mutationCount ^ "\n")

          (* Receive the same change reactively, without polling HTTP again. *)
          val updated =
            exampleCount (nextLiveValue (live, "updated Live value"), "updated Live value")
          val _ =
            if updated = expected then ()
            else raise Fail "updated Live count disagreed with the mutation"
          val _ = print ("live updated count: " ^ IntInf.toString updated ^ "\n")
        in
          (* Printed only after all three views have agreed. *)
          print ("verified count: " ^ IntInf.toString current ^ " -> "
                 ^ IntInf.toString updated ^ "\n")
        end
    in
      (body () handle exn => (cleanup (); raise exn));
      cleanup ()
    end

  fun main () =
    (run ();
     TextIO.flushOut TextIO.stdOut;
     OS.Process.exit OS.Process.success)
    handle exn =>
      (* Diagnostics belong on stderr: stdout is the verified transcript. *)
      (TextIO.output
         (TextIO.stdErr, "Standard ML example failed: " ^ ConvexError.describe exn ^ "\n");
       TextIO.flushOut TextIO.stdErr;
       TextIO.flushOut TextIO.stdOut;
       OS.Process.exit OS.Process.failure)
end
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

This is a native client. JSON parsing and printing, HTTP/1.1, SHA-1, base64,
WebSocket framing, and Convex-specific HTTP and Live behaviour are Standard ML
code built on the Basis Library's sockets and Poly/ML's thread extension. It
does not call another Convex SDK, the Convex CLI, `curl`, Node.js, or Python.

The Basis Library does not provide TLS, so Poly/ML's documented
[`Foreign`](https://www.polyml.org/Doc.html) interface binds OpenSSL 3. OpenSSL
handles cryptography and certificate checks through memory BIOs, while Standard
ML retains ownership of socket I/O and deadlines. The client checks both DNS
names and literal IP addresses against certificates.

Live uses one owner thread for opening, reading, writing, and reconnecting the
WebSocket. Public calls send commands to that owner. Updates are coalesced and
bounded by both count and encoded-size budgets, and each carries a connection
generation so an old update cannot leak across unsubscribe, replacement, or
reconnect. The adapter-only `debugDisconnect` hook exists solely for shared
conformance and is not part of the API shown to learners.

Poly/ML compiles the example and adapter into native `linux/amd64` executables.
Their minimal images keep the Poly/ML runtime, OpenSSL, certificate roots, and
the small POSIX surface required by verification, but no compiler, package
manager, or delegated language runtime. Poly/ML has no standard formatter, so
the Docker test image runs a repository-local deterministic style and lint gate
over every Standard ML source file.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   journals, and `TransitionChunk` assembly are not implemented.
2. HTTP deliberately uses one bounded connection-close request and rejects
   transfer coding, conflicting framing headers, and non-decimal lengths.
3. Networking resolves IPv4 only. Convex tagged values remain generic JSON
   rather than becoming richer Standard ML values.
4. `linux/amd64` builds under arm64 emulation can occasionally fault inside
   `polyc`'s C toolchain or the BusyBox prune step. The targeted compiler retry
   does not hide genuine Standard ML errors.
5. Resource limits are intentional: JSON, active subscriptions, Live delivery,
   and adapter output all have fixed count or byte budgets.
