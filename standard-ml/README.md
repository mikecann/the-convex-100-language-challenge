# Convex from Standard ML

This is a small native Poly/ML client that calls Convex functions over HTTP and keeps a query current over Live WebSockets.

It is educational and unofficial. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.sml`](examples/basics/main.sml). It queries a fresh counter, subscribes to Live before changing anything, applies one idempotent mutation, and checks that the HTTP query, the mutation result, and the Live update all agree on `0 -> 1`.

## What works

Everything below is exercised by language-local Docker tests. None of it has been through shared conformance against a Convex deployment, so no capability has been earned.

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, and actions | Passing against local fixtures |
| Bearer authentication and structured function errors | Passing against local fixtures |
| Live initial values, updates, and query-error recovery | Passing against raw WebSocket fixtures |
| Remove, five reconnects, generation barriers, and bounded delivery | Passing against raw WebSocket fixtures |
| Real TLS, including host and address name checking | Passing against a local OpenSSL server |
| Minimal `linux/amd64` runtime and example images | Built, policy asserted, entrypoints executed |
| Shared local and hosted conformance | Not attempted |

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

## Docker verification

```sh
./run sync-examples
./run validate
./run test standard-ml
./run verify-example standard-ml
./run verify standard-ml
./run verify-hosted standard-ml
./run verify-all standard-ml
```

`test` builds the pinned Poly/ML toolchain, then runs encoding, real-TLS, real-HTTP, raw-WebSocket Live, adapter-protocol, adapter-driven-Live, and canonical-example tests, and saves the adapter and example as native `linux/amd64` executables. `verify-example` runs the example from its minimal image against a unique room. The remaining shared commands add local and hosted black-box conformance. Only the root result evaluator can award HTTP or Live badges, so this language branch does not claim them.

`./run test standard-ml` and `./run build standard-ml` have both been run and pass; a clean no-cache test build reports 243 checks across the seven suites. `verify-example`, `verify`, `verify-hosted`, and `verify-all` have not been run.

## Conformance and protocol notes

The client implements Convex's documented JSON HTTP endpoints and the repository's pinned unversioned `/api/sync` profile directly in Standard ML. JSON parsing and printing, SHA-1, base64, HTTP/1.1 request and response handling, and RFC 6455 framing are all Standard ML code over the Basis Library's `Socket` and Poly/ML's `Thread`. No request invokes another Convex client, the Convex CLI, `curl`, Node.js, or Python.

TLS is the one borrowed facility, because the Basis Library has none. OpenSSL is bound through Poly/ML's `Foreign` structure in a single file and is driven through a pair of memory BIOs: OpenSSL only ever transforms buffers, and Standard ML decides when to wait and for how long. That keeps every deadline enforceable and means no foreign call performs I/O or stalls the garbage collector. Certificates are verified against the trusted roots *and* against the name the caller asked for, using `SSL_set1_host` for names and `X509_VERIFY_PARAM_set1_ip_asc` for literal addresses.

One owner thread exclusively opens, reads, writes, retires, and reconnects the Live socket. Callers queue Add, Remove, reconnect, and close commands to that owner and wait for acknowledgements. Complete transitions are validated, coalesced per query, and committed atomically, so a transition whose second member is malformed publishes nothing at all. Unchanged reconnect hydration is suppressed with a fixed-size fingerprint rather than a retained copy of the value. Every delivered update carries its socket generation, which lets the adapter reject an update dequeued before a replacement, unsubscribe, or reconnect barrier.

Once any byte of a frame has been consumed, the frame deadline applies and a timeout abandons that connection rather than resuming the parser at a byte that is not a frame header. Reconnect backoff starts at 100 ms, caps at 15 seconds, and resets after a valid connection or transition. `connectionCount`, `lastCloseReason`, and `maxObservedTimestamp` are carried across reconnects.

The manager retains the newest 16 updates within a conservative 20 MiB budget that charges four times the exact encoded length plus a fixed record allowance. Active subscriptions have a separate 64-entry and 8 MiB budget. JSON decoding stops at 2 MiB, 128 levels, or 8,192 structural nodes before malformed or dense input can exhaust the runtime.

The adapter speaks bounded UTF-8 NDJSON protocol v1 over stdin and stdout or one `ADAPTER_LISTEN` TCP connection. Its independent output queue retains at most the newest 16 encoded events within 6 MiB, including a write already in flight. Subscription values may be coalesced under pressure, while acknowledgements and errors wait for bounded room or fail the connection. `debugDisconnect` is adapter-only: it lives in `Convex.Internal`, not in the client surface the example teaches.

The final images contain the native executable, the Poly/ML runtime library, OpenSSL 3, certificate roots, `/bin/sh`, and the individual POSIX tools the shared verifier requires. They contain no Poly/ML compiler or frontend, no C compiler, no package or network tools, no delegated runtimes, and no multicall binary, and run as `65532:65532` under the repository's read-only, capability-drop, no-new-privileges, 128 MiB policy. The completed no-cache Docker run exercised those policy checks and both exact entrypoints; shared local and hosted conformance still remain for the root integration pass.

## Limitations

No shared conformance has been run, so HTTP and Live remain unearned: the fixtures below prove the client's own behaviour, not agreement with a real Convex deployment.

Building `linux/amd64` under emulation on an arm64 host intermittently faults inside the C toolchain. `polyc` links the exported heap with `g++`, and `collect2` has died once with an internal segmentation fault; the build retries only that exact signature, up to four attempts, and a genuine Standard ML error still fails on the first. The `busybox` prune in `runtime-base` has also segfaulted once under emulation, which simply needs the image build repeating. Neither fault has reproduced on a native `linux/amd64` builder.

Live authentication, optimistic updates, mutation and action messages over the WebSocket, journals, and `TransitionChunk` assembly are deferred; a `TransitionChunk` is treated as recoverable protocol drift and retires the socket rather than publishing partial state. HTTP uses a bounded single-request connection-close exchange, and chunked framing is rejected explicitly rather than mis-parsed. Only IPv4 deployment addresses resolve. Values cover Convex's JSON-safe subset; tagged Convex value encodings are not converted into richer Standard ML types. Input beyond the documented line, JSON, subscription, delivery, or output bounds is rejected or coalesced instead of risking unbounded memory. The manifest deliberately leaves capability badges empty.
