# Convex from Seed7

A native Seed7 client that calls Convex functions over HTTP and keeps a
query current over Convex's Live WebSocket sync protocol, hand-rolled
directly on raw TCP/TLS sockets.

This is educational and unofficial, not a production Convex SDK.

## Start here

[`examples/basics/main.sd7`](examples/basics/main.sd7) follows the shared
counter from 0 to 1 using an HTTP query, a Live subscription started
before the mutation, and an idempotent mutation.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sd7 -->
```text
$ include "seed7_05.s7i";
  include "convex_live.s7i";
  include "environment.s7i";


(**
 *  Read the shared counter's current value out of a decoded Convex
 *  object, accepting the `0` or `0.0` forms Convex's JSON encoding may
 *  use for a whole number. Returns -1 when `value` is not a JSON
 *  object with a whole-numbered "count" field, which the two die()
 *  call sites below treat as "unexpected value".
 *)
const func integer: countOf (in jsonValue: value) is func
  result
    var integer: count is -1;
  local
    var integer: decoded is 0;
  begin
    if category(value) = JSON_OBJECT and "count" in value then
      if not wholeNumberOf(value["count"], decoded) then
        count := -1;
      else
        count := decoded;
      end if;
    end if;
  end func;


const proc: die (in string: message) is func
  begin
    writeln(STD_ERR, message);
  end func;


const proc: main is func
  local
    var string: url is "";
    var string: room is "seed7-basic-example";
    var boolean: parsed is FALSE;
    var convexClient: client is convexClient.value;
    var jsonObject: queryArgs is jsonObject.value;
    var convexOutcome: outcome is convexOutcome.value;
    var convexLive: live is convexLive.value;
    var jsonObject: mutationArgs is jsonObject.value;
    var boolean: failed is FALSE;
  begin
    # Configure the deployment from the environment and create the client.
    # The verifier's unique room ID arrives as the program's first
    # argument; a friendly default lets someone run the image by hand.
    url := getenv("CONVEX_URL");
    if length(argv(PROGRAM)) >= 1 then
      room := argv(PROGRAM)[1];
    end if;
    client := openConvexClient(url, parsed);
    if not parsed then
      die("could not create client");
      failed := TRUE;
    end if;

    # Query the current counter over HTTP and decode its JSON object.
    if not failed then
      queryArgs @:= ["room"] jsonValue(room);
      outcome := client query "demo:state" withArgs jsonValue(queryArgs);
      if not outcome.ok or countOf(outcome.value) <> 0 then
        die("unexpected initial query value");
        failed := TRUE;
      else
        writeln("current count: 0");
      end if;
    end if;

    # Start Live before the mutation so no reactive update can be missed.
    if not failed then
      live := openConvexLive(client);
      subscribeLive(live, "state", "demo:state", jsonValue(queryArgs));
      outcome := waitForLiveValue(live, "state", 10 . SECONDS);
      if not outcome.ok or countOf(outcome.value) <> 0 then
        die("unexpected initial Live value");
        failed := TRUE;
      else
        writeln("live initial count: 0");
      end if;
    end if;

    # The run ID makes the mutation safe to retry without incrementing twice.
    if not failed then
      mutationArgs @:= ["room"] jsonValue(room);
      mutationArgs @:= ["language"] jsonValue("Seed7");
      mutationArgs @:= ["runId"] jsonValue(room & "-once");
      outcome := client mutate "demo:increment" withArgs jsonValue(mutationArgs);
      if not outcome.ok or category(outcome.value) <> JSON_OBJECT or
          not boolean(outcome.value["applied"]) or countOf(outcome.value["state"]) <> 1 then
        die("unexpected mutation result");
        failed := TRUE;
      else
        writeln("mutation applied: true");
        writeln("mutation count: 1");
      end if;
    end if;

    # Decode the resulting Live update, then cleanly remove the subscription.
    if not failed then
      outcome := waitForLiveValue(live, "state", 10 . SECONDS);
      if not outcome.ok or countOf(outcome.value) <> 1 then
        die("unexpected updated Live value");
        failed := TRUE;
      else
        writeln("live updated count: 1");
      end if;
      unsubscribeLive(live, "state");
      closeLive(live);
    end if;

    # Print verification only after HTTP and Live agree on the 0 -> 1 journey.
    if failed then
      exit(1);
    else
      writeln("verified count: 0 -> 1");
    end if;
  end func;
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

`./run test seed7` formats-checks (Seed7 has no standalone formatter, so
this is a warning-clean `s7c` compile of every checked-in source file
instead), compiles, and runs the client's unit tests and the conformance
adapter's basic protocol sanity checks. `./run verify-example seed7`
exercises the exact example above against the dedicated backend. `./run
verify seed7` and `./run verify-hosted seed7` run the shared HTTP and
Live conformance suite against the local and hosted deployments.

## Protocol notes and limits

The adapter speaks NDJSON protocol v1 on stdin/stdout or one
`ADAPTER_LISTEN` TCP connection. There is no delegated HTTP, TLS,
WebSocket, or JSON library underneath this client the way `libcurl` and
`json-c` sit underneath the C client: `client/convex.s7i` uses only
Seed7's own standard library (`json.s7i`, `https_request.s7i`/
`http_request.s7i`, `tls.s7i`) for HTTP, and `client/convex_live.s7i`
implements RFC 6455 WebSocket framing and the Convex sync protocol
(`Connect`, `ModifyQuerySet` Add/Remove, `Transition`) directly against
raw `socket.s7i`/`tls.s7i` sockets, because no WebSocket library exists
in Seed7's standard library to delegate to.

Seed7 ships no thread library, so the whole Live state machine runs on
one single-threaded event loop rather than a dedicated worker thread: the
conformance adapter's `ADAPTER_LISTEN` control connection is a real
`socket`, pollable exactly like the Live connection, so each loop
iteration flushes any decoded subscription values, then services
whichever of the two connections is ready. Plain stdin/stdout mode
delivers Live updates only between adapter commands, because this
toolchain's console file type has no readiness check to poll on (proved
directly against the interpreter, not assumed); the shared conformance
harness always drives a client's Live behaviour over `ADAPTER_LISTEN`, so
this does not affect the earned capability.

Seed7's own `tls.s7i` is a from-scratch TLS 1.2 implementation --
handshake state machine, AES-GCM, HMAC, elliptic-curve key exchange, X.509
parsing -- with no OpenSSL dependency at all, which is also why this
client's runtime image carries no OpenSSL library, configuration, or
provider modules. It cryptographically validates the certificate chain a
server presents (each certificate's signature against its issuer's public
key) but does not check the chain against a trusted root CA store, so a
fully substituted chain from an attacker's own root would not be
detected. This is recorded plainly here and in the manifest rather than
worked around, since fixing it honestly would mean shipping a CA-store
verifier as part of the client rather than quietly relying on the
underlying library to already do it.

Convex JSON numbers may render a whole count as `0` or `0.0`.
`client/convex.s7i`'s `wholeNumberOf` decodes either form by reading
`json.s7i`'s own preserved decimal text for a `jsonNumber` rather than
round-tripping through `float`, so it accepts both forms exactly and
rejects a genuinely fractional value, scientific notation, and a quoted
number; see `client/tests/client_test.sd7` for the regression.

## A sharp edge worth knowing about

A Seed7 `local` variable declared as `var T: x is someImpureCall();`
inside a function's `result`/`local`/`begin` block is *not* guaranteed to
re-evaluate that initializer on every call on this toolchain: a deadline
computed as `var time: deadline is time(NOW) + timeout;` was observed to
silently reuse a stale clock reading across calls, and the same shape
with a `/dev/urandom` read behaved identically. The fix used everywhere
in this client is to declare the variable with a neutral default and
assign the real value as the first statement in `begin` instead. This is
recorded here because it is exactly the kind of defect a conformance
suite exercising only one call per process would never catch, and it
cost real debugging time to isolate down to that one line shape.
