# Modula-3

Modula-3 is a compact, strongly typed descendant of Pascal and Modula-2,
designed at DEC's Systems Research Center in the late 1980s. It combined
interfaces, objects, garbage collection, exceptions, generics, threads, and a
deliberate boundary around unsafe systems code. It was used for systems and
research software such as SPIN and now occupies a small, enthusiast-maintained
niche through [Critical Mass Modula-3](https://github.com/modula3/cm3). The
[Modula-3 resource site](https://www.modula3.org/about_m3/) has the language's
history and design overview.

This repository uses those systems-programming features to build a native
Convex client. It is an educational demonstration, not an official Convex SDK
and not a package intended for production use.

## Getting Started

The [canonical example](examples/basics/main.m3) reads a room's counter,
subscribes to it, increments it, and observes the reactive update. From the
repository root, run it in its Docker image against the approved local test
deployment:

```sh
./run verify-example modula-3
```

Docker supplies the pinned CM3 toolchain and runtime, so you do not need to
install Modula-3 on the host.

## Interesting Parts

### Interfaces reveal only what callers need

Modula-3 splits every module into an `INTERFACE` (the public contract) and a
`MODULE` (the hidden body) — a discipline inherited from Modula-2, sharpened
here with object types that can be only *partially* revealed. `ConvexJson.T`
is declared opaque: the interface exposes a `Public` shape with nothing but a
`kind` tag, and every array/object storage detail stays sealed inside
`ConvexJson.m3` where no caller, including this client's own `ConvexHttp` and
`ConvexLive`, can reach in and touch it.

```modula3
(* ConvexJson.i3 -- only "kind" is revealed to callers *)
TYPE
  Kind = {Null, False, True, Number, Str, Arr, Obj};
  Public = OBJECT kind: Kind END;
  T <: Public;                (* the rest of T lives in ConvexJson.m3 *)

PROCEDURE ObjectGet(o: T; key: TEXT): T;
(* TypeScript: JSON.parse hands back the whole shape at once *)
```

Every caller in this repo can branch on `value.kind`; none of them can see how
an object's fields are actually stored.

### A procedure declares its own exceptions

Modula-3 requires a procedure to name every exception that can escape it, via
a `RAISES` clause on the signature — checked exceptions years before Java
made them famous. `ConvexJson.NumOf` promises `RAISES {Error}`, so the
compiler holds every caller to either handling `ConvexJson.Error` or
re-declaring the same promise onward.

```modula3
PROCEDURE NumOf(v: T): LONGREAL RAISES {Error};

TRY
  raw := ConvexJson.NumOf(countField);
EXCEPT
| ConvexJson.Error =>
    Fail(context & ": \"count\" was not a JSON number");
END;
(* TypeScript: try/catch compiles fine even if you never write it *)
```

Decoding an untyped Convex reply into a real `LONGREAL` is exactly where that
compiler-checked list earns its keep.

### A result can also be a record you interrogate

Modula-3 has no built-in sum types, so where an exception would be the wrong
shape, this client hand-rolls one instead: `ConvexHttp.Call` never throws for
a Convex function error or a dropped connection, it returns a `CallResult`
whose `kind` field says which of four things happened.

```modula3
TYPE
  ResultKind = {Result, FunctionError, TransportError, ProtocolError};

queryResult := ConvexHttp.Call("query", "demo:state", queryArgs, deploymentUrl, "");
IF queryResult.kind # ConvexHttp.ResultKind.Result THEN
  Fail("query: " & queryResult.errMessage);
END;
(* TypeScript: await client.query(...) throws instead of returning a tag *)
```

Two error-reporting styles, exceptions and tagged records, living side by side
in one client — the language leaves that choice to the API designer.

### Live doesn't push — you poll for it

The Status table's Live row below is earned: this client really does open the
`/api/sync` WebSocket and prove a reactive update round-trips through it. But
there is no callback, promise, or `async` generator. `ConvexLive.Poll` blocks
the caller for at most a bounded number of milliseconds and hands back
whatever arrived, even nothing, leaving the loop-and-match entirely up to you.

```modula3
live := ConvexLive.New(deploymentUrl);
ConvexLive.Add(live, "counter", "demo:state", queryArgs);

VAR batch := ConvexLive.Poll(live, 200); (* blocks up to 200ms, then returns *)
BEGIN
  FOR i := 0 TO batch.count - 1 DO
    IF Text.Equal(batch.events[i].subscriptionId, "counter")
       AND batch.events[i].kind = ConvexLive.EventKind.Update THEN
      liveUpdatedCount := DecodeCount(batch.events[i].value, "live");
      (* TypeScript: useQuery just rerenders you; here you poll a queue *)
    END;
  END;
END;
```

## Status

| Capability | Recorded result |
| --- | --- |
| HTTP query, mutation, and action | Earned |
| Live subscriptions | Earned |
| Implementation provenance | Native CM3 client |

The checked-in local and hosted conformance evidence awards both `http` and
`live`. Those runs exercised the canonical example, function errors, real Live
updates, five reconnects, backoff reset, and query-error recovery. This README
edit does not claim a fresh verification run.

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.m3 -->
```modula3
(* Convex from Modula-3: the shared counter journey.

   Reads a room's counter over Convex's documented HTTP API, starts a
   Live subscription, increments the counter once, and proves that the
   Live subscription reported the same change without polling. This is
   an educational demonstration of a hand-written, from-scratch Convex
   client (see ../../README.md), not an official Convex SDK.

   Run it with:
     CONVEX_URL=https://<deployment>.convex.cloud ./main <room> *)
MODULE main EXPORTS Main;

IMPORT IO, Text, Fmt, Env, Params, Process, Stdio,
       ConvexJson, ConvexHttp, ConvexLive, ConvexRandom;

PROCEDURE Fail(msg: TEXT) =
  BEGIN
    IO.Put("Modula-3 example failed: " & msg & "\n", Stdio.stderr);
    Process.Exit(1);
  END Fail;

(* Decodes the demo counter's "count" field into an idiomatic INTEGER.
   Convex JSON numbers may arrive in an integral decimal form such as
   "0" or "0.0"; both are accepted, but a fractional, non-finite, or
   out-of-range value fails loudly instead of being silently truncated
   -- exactly the regression AGENTS.md calls out, since a mocked
   integer-only fixture would never exercise this path. *)
PROCEDURE DecodeCount(value: ConvexJson.T; context: TEXT): INTEGER =
  VAR countField: ConvexJson.T; raw: LONGREAL;
  BEGIN
    IF value = NIL OR value.kind # ConvexJson.Kind.Obj THEN
      Fail(context & ": expected a JSON object");
    END;
    countField := ConvexJson.ObjectGet(value, "count");
    IF countField = NIL THEN Fail(context & ": missing \"count\""); END;
    TRY
      raw := ConvexJson.NumOf(countField);
    EXCEPT
    | ConvexJson.Error => Fail(context & ": \"count\" was not a JSON number"); raw := 0.0d0;
    END;
    (* Reject non-finite, fractional, and out-of-range values: a
       mathematically integral value comfortably within INTEGER's range
       is the only shape this example accepts. *)
    IF raw # raw THEN Fail(context & ": \"count\" was NaN"); END; (* NaN never equals itself *)
    IF ABS(raw) > 1.0d15 THEN Fail(context & ": \"count\" was out of range"); END;
    IF raw # FLOAT(ROUND(raw), LONGREAL) THEN Fail(context & ": \"count\" was not a whole number"); END;
    RETURN ROUND(raw);
  END DecodeCount;

VAR
  (* -- configuration: the deployment URL is required. The room comes
     from the verifier's first command-line argument (so repeated runs
     never collide), an EXAMPLE_ROOM environment variable for a
     convenient hand run, or a literal fallback so this still does
     something either way. -- *)
  deploymentUrl := Env.Get("CONVEX_URL");
  room: TEXT;
  queryArgs, mutationArgs: ConvexJson.T;
  queryResult: ConvexHttp.CallResult;
  currentCount, liveInitialCount, mutationCount, liveUpdatedCount: INTEGER;
  live: ConvexLive.T;
  runId: TEXT;
  gotInitial, gotUpdated: BOOLEAN;
BEGIN
  IF deploymentUrl = NIL OR Text.Equal(deploymentUrl, "") THEN
    Fail("CONVEX_URL is required");
  END;

  room := NIL;
  IF Params.Count >= 2 THEN room := Params.Get(1); END;
  IF room = NIL OR Text.Equal(room, "") THEN room := Env.Get("EXAMPLE_ROOM"); END;
  IF room = NIL OR Text.Equal(room, "") THEN room := "modula-3-example"; END;

  queryArgs := ConvexJson.NewObject();
  ConvexJson.ObjectSet(queryArgs, "room", ConvexJson.NewString(room));

  (* -- the HTTP query: reads the room's current counter through
     Convex's documented POST /api/query envelope, before anything
     reactive is involved, so the Live subscription below has a known
     value to agree with. -- *)
  queryResult := ConvexHttp.Call("query", "demo:state", queryArgs, deploymentUrl, "");
  IF queryResult.kind # ConvexHttp.ResultKind.Result THEN
    Fail("query: " & queryResult.errMessage);
  END;
  currentCount := DecodeCount(queryResult.value, "current query");
  IO.Put("current count: " & Fmt.Int(currentCount) & "\n");

  (* -- client creation: opens the WebSocket handshake to /api/sync and
     sends the Connect message. No query has been added yet. -- *)
  live := ConvexLive.New(deploymentUrl);

  (* -- starting Live before the mutation: subscribing first is what
     makes the update received below an observation of a real change,
     rather than a race against one that already happened. -- *)
  ConvexLive.Add(live, "counter", "demo:state", queryArgs);
  IF NOT ConvexLive.IsConnected(live) THEN
    Fail("sync connect: " & ConvexLive.LastCloseReason(live));
  END;

  (* -- the initial Live value: the same state the HTTP query above
     already read, delivered this time as the subscription's first
     Transition. -- *)
  gotInitial := FALSE;
  FOR attempt := 1 TO 100 DO
    IF gotInitial THEN EXIT; END;
    VAR batch := ConvexLive.Poll(live, 200);
    BEGIN
      FOR i := 0 TO batch.count - 1 DO
        IF Text.Equal(batch.events[i].subscriptionId, "counter") THEN
          IF batch.events[i].kind = ConvexLive.EventKind.Error THEN
            Fail("initial Live value: " & batch.events[i].errMessage);
          END;
          liveInitialCount := DecodeCount(batch.events[i].value, "initial Live value");
          gotInitial := TRUE;
        END;
      END;
    END;
  END;
  IF NOT gotInitial THEN Fail("initial Live value: timed out waiting for a Transition"); END;
  IF liveInitialCount # currentCount THEN
    Fail("the initial Live count disagreed with HTTP");
  END;
  IO.Put("live initial count: " & Fmt.Int(liveInitialCount) & "\n");

  (* -- the mutation and its idempotency key: runId lets Convex
     recognize a retried request and return the previous result
     instead of incrementing twice. A fresh random key means this run
     really applies its increment rather than replaying an old one. -- *)
  TRY
    runId := ConvexRandom.HexBytes(16);
  EXCEPT
  | ConvexRandom.Error => Fail("could not generate an idempotency key"); runId := "";
  END;
  mutationArgs := ConvexJson.NewObject();
  ConvexJson.ObjectSet(mutationArgs, "room", ConvexJson.NewString(room));
  ConvexJson.ObjectSet(mutationArgs, "language", ConvexJson.NewString("modula-3"));
  ConvexJson.ObjectSet(mutationArgs, "runId", ConvexJson.NewString(runId));

  VAR mutationResult := ConvexHttp.Call("mutation", "demo:increment", mutationArgs, deploymentUrl, "");
  BEGIN
    IF mutationResult.kind # ConvexHttp.ResultKind.Result THEN
      Fail("mutation: " & mutationResult.errMessage);
    END;
    VAR appliedField := ConvexJson.ObjectGet(mutationResult.value, "applied");
        applied := FALSE;
    BEGIN
      IF appliedField # NIL THEN
        TRY applied := ConvexJson.BoolOf(appliedField); EXCEPT | ConvexJson.Error => applied := FALSE; END;
      END;
      IF NOT applied THEN Fail("the mutation was not applied"); END;
    END;
    mutationCount := DecodeCount(ConvexJson.ObjectGet(mutationResult.value, "state"), "mutation");
  END;
  IF mutationCount # currentCount + 1 THEN
    Fail("the mutation returned an unexpected count");
  END;
  IO.Put("mutation applied: true\n");
  IO.Put("mutation count: " & Fmt.Int(mutationCount) & "\n");

  (* -- the resulting Live update: received over the same subscription,
     without polling HTTP again. -- *)
  gotUpdated := FALSE;
  FOR attempt := 1 TO 100 DO
    IF gotUpdated THEN EXIT; END;
    VAR batch := ConvexLive.Poll(live, 200);
    BEGIN
      FOR i := 0 TO batch.count - 1 DO
        IF Text.Equal(batch.events[i].subscriptionId, "counter") THEN
          IF batch.events[i].kind = ConvexLive.EventKind.Error THEN
            Fail("updated Live value: " & batch.events[i].errMessage);
          END;
          liveUpdatedCount := DecodeCount(batch.events[i].value, "updated Live value");
          gotUpdated := TRUE;
        END;
      END;
    END;
  END;
  IF NOT gotUpdated THEN Fail("updated Live value: timed out waiting for a Transition"); END;
  IF liveUpdatedCount # currentCount + 1 THEN
    Fail("the updated Live count disagreed with the mutation");
  END;
  IO.Put("live updated count: " & Fmt.Int(liveUpdatedCount) & "\n");

  (* Every operation above agreed before this proof line is printed. *)
  IO.Put("verified count: " & Fmt.Int(currentCount) & " -> " & Fmt.Int(liveUpdatedCount) & "\n");

  (* -- cleanup: close the Live connection cleanly before exiting. -- *)
  ConvexLive.Close(live);
END main.
```
<!-- END GENERATED EXAMPLE -->

## Implementation Notes

The implementation is native Modula-3 built with CM3 `d5.12.0`. Plain TCP
uses CM3's `TCP.i3` and `IP.i3`. TLS crosses one narrow `EXTERNAL` procedure
boundary into the project's OpenSSL shim, which performs certificate and
hostname verification. JSON, HTTP/1.1 framing, WebSocket framing, and the
pinned Convex Live behavior are implemented in this client rather than
delegated to JavaScript, Node.js, Python, the Convex CLI, or another SDK.

`ConvexLive.T` is a mutable, single-threaded state machine. One caller owns it
and drives progress through `Poll`; the client does not start a hidden worker.
It reconnects with bounded exponential backoff, restores active subscriptions,
and suppresses the unchanged value that can arrive during rehydration. Its
pending queue is capped at 256 events. The test-only conformance adapter adds
an 8-slot, 4 MiB output queue and exposes `DebugDisconnect`; that hook is not
part of the educational client API.

The Docker build bootstraps CM3 from its pinned source and boot archive, then
copies the compiled programs and their runtime library closure into pruned
non-root images. The relevant gates are:

```sh
./run test modula-3
./run verify-example modula-3
./run verify modula-3
./run verify-hosted modula-3
./run verify-all modula-3
```

`test` covers compilation and language-local fixtures. `verify-example` runs
this exact example. The remaining commands add local and hosted black-box
conformance. They are distinct claims, and only the shared evaluator awards
capabilities.

## Known Issues

1. Live authentication is not implemented. `setAuth` applies only to HTTP
   query, mutation, and action calls.
2. An unrecognized `TransitionChunk` is reported as a `ProtocolError` and
   triggers reconnect instead of being reassembled.
3. The client's pending queue is bounded by 256 events, not by bytes. The
   conformance adapter's separate 8-slot, 4 MiB queue bounds output toward a
   stopped consumer.
4. `ConvexTransport.Connect` has no connect-specific timeout because CM3's
   `TCP.Connect` does not expose one. Callers still have overall operation
   deadlines after connection.
