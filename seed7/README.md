<img src="logo.png" alt="Seed7 logo" width="50">
<!-- Logo source: https://seed7.net/images/hearts7m.png -->

# Seed7

[Seed7](https://seed7.net/) is an open-source, general-purpose programming
language designed and maintained by Thomas Mertes. It looks a little like
Pascal or Ada, but its most unusual idea is that much of the language is not
hard-coded into the compiler. Libraries can define new statements, operators,
and syntax using Seed7 itself.

Seed7 is a niche language rather than a mainstream application ecosystem. Its
toolchain includes an interpreter and a compiler that translates Seed7 to C,
then uses a C compiler to produce machine code. Its standard library covers
areas such as networking, databases, graphics, files, and cryptography. This
repository uses those facilities for a native HTTP and Live client
demonstration, without delegating Convex behaviour to another client.

This client is an educational, unofficial demonstration. It is not a
production Convex SDK.

## Getting Started

See [`examples/basics/main.sd7`](examples/basics/main.sd7) for a complete
working example. It reads a counter over HTTP, starts a live subscription,
applies one safely repeatable mutation, and observes the resulting update.

From the project root, run:

```sh
./run verify-example seed7
```

The command builds the example in Docker, starts the project's dedicated local
Convex backend, and verifies the complete `0 -> 1` journey. You do not need to
install Seed7 on your computer.

## Interesting Parts

### A library can teach the language a new sentence

Seed7's headline idea, mentioned above, is that control structures like `for`
and even `:=` are ordinary library declarations, not compiler built-ins. This
client leans on that directly: a two-line `$ syntax` pragma teaches the
compiler a brand-new statement shape, so calling a Convex query reads like a
sentence instead of a three-argument function call.

```text
$ syntax expr: .().query.().withArgs.() is -><- 9;
const func convexOutcome: (inout convexClient: client) query (in string: path)
    withArgs (in jsonValue: args) is
  return convexCall(client, "query", path, args);

# TypeScript: const state = useQuery(api.demo.state, { room });
outcome := client query "demo:state" withArgs jsonValue(queryArgs);
```

`query ... withArgs ...` isn't a macro or a parser special case — it's exactly
as "built-in" as Seed7's own `if`, defined by the same mechanism.

### JSON grows with an operator, not a builder

Instead of a `.set()` chain or an object literal, appending a field to a JSON
object uses `@:=`, an operator the standard library itself defines rather than
hard-wiring into the compiler. It reads like updating a hash map in place, one
field at a time.

```text
var jsonObject: mutationArgs is jsonObject.value;
mutationArgs @:= ["room"] jsonValue(room);
mutationArgs @:= ["language"] jsonValue("Seed7");
mutationArgs @:= ["runId"] jsonValue(randomSessionId);
outcome := client mutate "demo:increment" withArgs jsonValue(mutationArgs);
# TypeScript: await mutation(api.demo.increment, { room, language, runId })
```

### Live has no thread, so you pump it yourself

Seed7 ships no thread library, so this client can't hand the WebSocket to a
background worker the way a browser's `useQuery` implicitly does. A
subscription is instead a value you poll: `waitForLiveValue` drives Seed7's
own single event loop until a pushed update arrives or a deadline passes.

```text
live := openConvexLive(client);
subscribeLive(live, "state", "demo:state", jsonValue(queryArgs));
outcome := waitForLiveValue(live, "state", 10 . SECONDS);
# TypeScript: useQuery just re-renders; here you ask for the next value.
if outcome.ok then
  outcome := client mutate "demo:increment" withArgs jsonValue(mutationArgs);
end if;
outcome := waitForLiveValue(live, "state", 10 . SECONDS);
unsubscribeLive(live, "state");
closeLive(live);
```

One socket, one loop, no callbacks — the whole subscription lifecycle fits in
eight lines. The complete [`main.sd7` example](examples/basics/main.sd7)
decodes and checks every result along the way.

## Status

| Capability | Status |
| --- | --- |
| HTTP queries, mutations and actions | Verified by shared local and hosted conformance |
| Bearer-token replacement and structured function errors | Verified by shared local and hosted conformance |
| Live initial values and updates | Verified by shared local and hosted conformance |
| Remove, reconnect, query-error recovery and bounded delivery | Verified by shared local and hosted conformance |

HTTP and Live are both earned capabilities. The implementation was tested
against the project's pinned local backend and its hosted compatibility target.

## Example

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

## Implementation Notes

This is a native Seed7 implementation. Seed7's own standard library handles
JSON, HTTP, network sockets, and encrypted connections. Unlike many clients in
this experiment, it does not rely on OpenSSL, libcurl, or a WebSocket package.
Seed7 has no WebSocket library, so `client/convex_live.s7i` implements the
WebSocket message format itself and then implements Convex's live-query
conversation on top. A WebSocket is simply a long-lived, two-way network
connection that lets Convex push a new query result as soon as the underlying
data changes.

Seed7 also has no thread library. Instead of putting the live connection on a
background thread, the client uses one event loop which alternates between
commands from the test controller and updates from Convex. The controller is a
small program used by this repository to ask every language client the same
questions. During normal conformance testing it talks to the Seed7 program over
a local TCP socket. When the program is controlled through ordinary standard
input instead, live updates are delivered between commands rather than while
the input is sitting idle, because Seed7 cannot check whether console input is
ready without blocking.

One especially interesting detail is that Seed7's TLS 1.2 support is itself
written in Seed7. TLS is the security layer used by HTTPS and secure
WebSockets. Its implementation includes AES-GCM, which encrypts data and
detects tampering; HMAC, which proves that handshake messages were not altered;
elliptic-curve key exchange, which lets two computers agree on a secret without
sending that secret over the network; and X.509 parsing, which reads website
certificates. This makes the runtime impressively self-contained, but it also
exposes the most important limitation listed below: the library verifies the
mathematics of the certificate chain without confirming that the chain ends at
a root certificate trusted by the operating system.

The client contains two less obvious correctness fixes. Convex may encode a
whole JSON number as either `0` or `0.0`, so `wholeNumberOf` checks the preserved
decimal text instead of converting through a floating-point number and risking
rounding. Seed7 can also reuse the initializer of a local variable when that
initializer calls an impure function. A network deadline based on the current
time was therefore observed reusing an old timestamp. This client declares
such variables with a neutral value and performs the real assignment inside
the function body, where it is evaluated on every call.

For deeper verification, `./run test seed7` runs the Seed7-local tests, while
`./run verify seed7` and `./run verify-hosted seed7` run the full shared test
suite against local and hosted Convex deployments.

## Known Issues

1. **Certificate trust is incomplete.** Encrypted connections validate the
   signatures in the certificate chain, but do not prove that the chain ends at
   a root certificate trusted by the operating system. A determined attacker
   able to substitute an entirely different valid chain would not be detected.
2. **Standard-input mode cannot push while idle.** Live updates are delivered
   between controller commands in this mode. The normal Docker verification
   path uses a local TCP control connection and is not affected.
3. **Some advanced Convex behaviour is outside this example's scope.** Live
   authentication, optimistic updates, and mutations or actions sent over the
   WebSocket are not implemented. Mutations and actions still work over HTTP.
4. **Slow test controllers can apply backpressure.** Each subscription keeps
   only its newest 16 updates, but once an update is handed to the operating
   system, a controller that stops reading can temporarily stall output.
5. **Replacing a subscription is not perfectly economical.** Reusing a
   subscription ID immediately retires the old local state, but the reconnect
   snapshot does not first send a separate removal for the old server-side
   query ID.
