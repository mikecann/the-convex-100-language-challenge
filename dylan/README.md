# Convex from Dylan

This is a Convex client written in Dylan, the ALGOL-syntax Lisp Apple built
for the Newton and then killed. It reads a shared counter over Convex's
documented JSON HTTP endpoint, subscribes to the same query over Convex Live,
applies a mutation, and shows the change arriving reactively — multimethod
dispatch, real macros, and a genuine module system, all driven by a
foreign-function boundary declared in Dylan itself rather than in a separate
C file.

It is educational, unofficial, and not a production SDK. It exists to answer
one question honestly: does a language most people have never run still hold
up as a place to write a real network client? Nothing here is supported by
Convex. Shared local and hosted black-box conformance earned HTTP and Live.

## Start here

The whole demonstration is one file:
[`examples/basics/main.dylan`](examples/basics/main.dylan).

It walks a single journey and refuses to print its final line unless every
step agrees:

1. Query `demo:state` over HTTP and read the current count.
2. Subscribe to the same query over Live, **before** mutating, so no update
   can fall into the gap.
3. Check that the first Live value hydrates the same count the HTTP query
   returned.
4. Apply `demo:increment` with a fresh idempotency key.
5. Receive the new count over Live, with no second HTTP request.

Against a fresh room, that is the `0 -> 1` journey printed below.

## What works

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Verified | Hand-rolled HTTP/1.1 over the native transport layer |
| Structured Convex errors | Verified | `FunctionError`, `ProtocolError` and `TransportError` keep name, message, data and log lines |
| TLS with certificate and hostname verification | Verified | Checked against a private CA in the Docker test stage, and against the real hosted deployment |
| Live subscribe, update, unsubscribe | Verified | RFC 6455 framing written in Dylan |
| WebSocket handshake `Sec-WebSocket-Accept` verification | Verified | Real SHA-1 via libcrypto, checked against a public echo server |
| Live reconnect and rehydration | Verified | Adapter-only `debugDisconnect`, five real reconnects, unchanged rehydration suppressed |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented | Deferred; see limitations |
| Earned badges | **HTTP, Live** | 31/31 shared conformance checks, both self-hosted and hosted profiles |

Every capability above passed the shared black-box conformance suite
(`./run verify-all dylan`) on both the self-hosted and the hosted deployment
profiles, from the same built image, at the commit this README was generated
from — not merely a green Docker build.

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.dylan -->
```text
module: convex

// -------------------------------------------------------------------------
// Convex from Dylan: the canonical basics example.
//
// Demonstrates the shared counter's 0 -> 1 journey: an initial HTTP
// query, an initial Live value over WebSocket, an idempotent mutation,
// and the resulting Live update -- verifying every step before printing
// the final confirmation line. Stdout here is a universal happy-path
// transcript compared byte-for-byte against
// _shared/examples/basics.expected.txt, so every diagnostic goes to
// stderr instead.
// -------------------------------------------------------------------------

define function die (message :: <byte-string>) => ()
  format-err(message);
  format-err("\n");
  force-err();
  c-exit(1);
end function;

// Convex's "json" HTTP format may render a whole count as either 0 or
// 0.0; this accepts both without silently truncating a genuinely
// fractional value (see convex-json.dylan's header comment on why floats
// and integers are distinct Dylan types here).
define function count-of (value :: <object>)
 => (count :: false-or(<integer>))
  let count-value = json-object-ref(value, "count");
  if (instance?(count-value, <integer>))
    count-value
  elseif (instance?(count-value, <float>))
    let whole = truncate(count-value);
    if (as(<double-float>, whole) = count-value) whole else #f end if
  else
    #f
  end if
end function;

// Blocks (via the same reactor step the adapter uses) until the next
// value or error arrives for query-id, or the overall deadline passes.
define function await-update
    (mgr :: <sync-manager>, query-id :: <integer>, deadline-ms :: <integer>)
 => (update :: false-or(<sync-update>))
  block (done)
    while (#t)
      let update = sync-poll-update(mgr, query-id);
      if (update)
        done(update);
      end if;
      if (cx-now-ms() > deadline-ms)
        done(#f);
      end if;
      sync-pump(mgr, 50);
    end while;
    #f
  end block
end function;

define function main () => ()
  // Configuration: the deployment URL comes from the environment, and
  // the verifier passes a unique room as this container's first
  // argument, forwarded here as EXAMPLE_ROOM by the Docker entrypoint
  // wrapper so a human running the image directly can also just set it.
  let url-text = cx-getenv("CONVEX_URL");
  if (~url-text)
    die("CONVEX_URL is required");
  end if;
  let base-url = parse-convex-url(url-text);
  if (~base-url)
    die("CONVEX_URL is not a valid http(s) URL");
  end if;
  let room = cx-getenv("EXAMPLE_ROOM") | "dylan-basic-example";

  let query-args = make-json-object();
  json-object-set!(query-args, "room", room);

  // The HTTP query: ask Convex for the room's current state.
  let (initial-value, query-err, _query-logs) =
    convex-http-call(base-url, "query", "demo:state", query-args, #f,
                      cx-now-ms() + 15000);
  if (query-err | count-of(initial-value) ~= 0)
    die("unexpected initial query value");
  end if;
  format-out("current count: 0\n");

  // Start Live before the mutation so no reactive update can be missed.
  let mgr = sync-manager-new(base-url);
  let query-id =
    sync-subscribe(mgr, "demo:state", query-args, cx-now-ms() + 8000);
  let initial-live = await-update(mgr, query-id, cx-now-ms() + 10000);
  if (~initial-live | initial-live.upd-kind ~= #"value"
        | count-of(initial-live.upd-value) ~= 0)
    die("unexpected initial Live value");
  end if;
  format-out("live initial count: 0\n");

  // The run ID makes the mutation safe to retry without incrementing
  // twice.
  let mutation-args = make-json-object();
  json-object-set!(mutation-args, "room", room);
  json-object-set!(mutation-args, "language", "Dylan");
  json-object-set!(mutation-args, "runId", concatenate(room, "-once"));
  let (mutation-value, mutation-err, _mutation-logs) =
    convex-http-call(base-url, "mutation", "demo:increment", mutation-args,
                      #f, cx-now-ms() + 15000);
  if (mutation-err)
    die("mutation failed");
  end if;
  let applied = json-object-ref(mutation-value, "applied");
  let state = json-object-ref(mutation-value, "state");
  if (applied ~= #t | count-of(state) ~= 1)
    die("unexpected mutation result");
  end if;
  format-out("mutation applied: true\n");
  format-out("mutation count: 1\n");

  // Decode the resulting Live update, then cleanly remove the
  // subscription.
  let updated-live = await-update(mgr, query-id, cx-now-ms() + 10000);
  if (~updated-live | updated-live.upd-kind ~= #"value"
        | count-of(updated-live.upd-value) ~= 1)
    die("unexpected updated Live value");
  end if;
  format-out("live updated count: 1\n");
  sync-unsubscribe(mgr, query-id, cx-now-ms() + 5000);

  // Print verification only after HTTP and Live agree on the 0 -> 1
  // journey.
  format-out("verified count: 0 -> 1\n");
  force-out();
end function;

main();
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

Everything builds and runs inside Docker; nothing is installed on the host.

```sh
./run test dylan
```

Installs Open Dylan 2026.2 from its official release tarball, runs the style
gate, compiles every target (the client-local suites, the TLS suite, the
conformance adapter, and the example), and runs the language-local suites:
strict JSON and the number rules, HTTP framing and the Convex envelope, the
WebSocket codec and the sync state machine, and TLS verification against a
private CA. It also proves the example fails cleanly with no deployment
configured and prints nothing on stdout when it does.

```sh
./run verify-example dylan
```

Builds the minimal example image and runs the exact canonical example against
a unique room, comparing stdout byte for byte with the shared transcript.

```sh
./run verify dylan
./run verify-hosted dylan
./run verify-all dylan
```

Add shared black-box conformance against the approved local backend, then the
hosted drift target, then both from the same built source. Only the shared
result evaluator may award a badge.

## How it is put together

Open Dylan resolves a library's own module files by plain relative filename
within the directory a `.lid` file lives in, not through the registry
mechanism the release's own bundled libraries use — and this project's public
layout has nowhere honest to put a registry entry for a client's own code.
So, exactly like `algol60/Dockerfile`'s `assemble_flat`/`assemble_live` shell
functions, the Dockerfile copies the same shared module files into a fresh
directory alongside each target's own entry point before compiling it:

| File | Responsibility |
| --- | --- |
| `client/convex-library.dylan` | The `define library`/`define module` declarations every other file compiles into |
| `client/convex-native.dylan` | `define C-function` declarations for POSIX sockets/poll and OpenSSL — the only foreign code in this client |
| `client/convex-json.dylan` | A JSON reader and writer over Dylan's own strings, tables and vectors |
| `client/convex-http.dylan` | HTTP/1.1 framing (including chunked transfer-encoding) and Convex's documented JSON HTTP functions |
| `client/convex-ws.dylan` | RFC 6455 WebSocket framing: masking, fragmentation, control frames, and UTF-8 validation |
| `client/convex-sync.dylan` | The `/api/sync` state machine, its single reactor owner, and its per-subscription delivery queues |

### No separate C file

Unlike this project's other compile-to-C native clients, there is no reviewed
`.c` support file at all. `client/convex-native.dylan` declares POSIX and
OpenSSL entry points directly with Dylan's `define C-function`, and Open
Dylan's C-FFI marshals Dylan strings, integers and structs to and from the C
calling convention itself. The boundary is proven, not assumed: `cx-getenv`'s
result is explicitly converted from Open Dylan's `<C-string>` wrapper class to
a genuine `<byte-string>` before anything else touches it, because the two
merely *look* alike at the REPL.

TLS verification is switched on next to the connection, not left to a
default: `SSL_CTX_set_default_verify_paths`, `SSL_CTX_set_verify` with
`SSL_VERIFY_PEER`, and `SSL_set1_host` for hostname checking are all set on
every handshake. The Docker test stage proves it by connecting three ways to
a local TLS server — trusted, untrusted issuer, and wrong hostname — and only
the first may succeed.

### A real `Sec-WebSocket-Accept` check

The WebSocket handshake recomputes the server's expected
`Sec-WebSocket-Accept` value with a real SHA-1 (borrowed from libcrypto,
`cx-sha1` in `client/convex-native.dylan`) and rejects the handshake if it
does not match, rather than accepting any HTTP 101 response the way a
from-scratch implementation without easy access to a hash function might.

### One owner, and no threads to enforce it with

Exactly one call path may touch the WebSocket, change the query-set version,
or decide to reconnect: `convex-sync.dylan`'s `sync-pump`, called from
whichever caller — the example, the adapter's own event loop — invokes it.
This client's C-FFI boundary exposes no threading primitive, so unlike the
reference C client's dedicated worker thread, single ownership here is not
enforced by a lock; it is simply the only code path that exists. Live
progress happens only while `sync-pump` is running, which the adapter does
continuously between reading commands.

After a reconnect the server resends the current value of every active query.
Publishing that unchanged value would turn one logical update into two, so
each subscription remembers the exact JSON value it last published and
suppresses an identical rehydration. Publishing an error clears that memory,
which is what lets a `QueryFailed` be followed by the same value again and
still read as a recovery.

## Conformance and protocol notes

`client/tests/conformance/adapter.dylan` is test infrastructure, not public
client code. It speaks NDJSON adapter protocol v1 over stdin and stdout, or
over one accepted TCP connection when `ADAPTER_LISTEN` is set, and calls the
real client for every operation. Stdout carries protocol events only; every
diagnostic goes to stderr.

It implements the adapter-only `debugDisconnect` command, declared in
`manifest.yaml` under `adapter.adapterOnlyCommands`, so the shared controller
can prove real reconnects. That command is not part of the educational client
API.

Optional fields are omitted rather than serialized as null: an absent command
id, an absent error `data`, and an absent `logs` array never appear as
`null`. `client/convex-json.dylan`'s ordered-object builder is what makes the
adapter's emitted field order match the shapes documented here.

The pinned sync profile is recorded in `manifest.yaml`. It is an undocumented
protocol, and nothing here implies it is stable or officially supported. In
particular, the session id sent in the `Connect` message is generated once
per client lifetime and resent on every reconnect — a deliberate choice made
where this project's own C and ALGOL 60 reference clients disagree with each
other (see `convex-sync.dylan`'s header comment).

## Limitations and deferred behaviour

- `convex-sync.dylan`'s reactor has no real concurrency primitive backing it
  (see "One owner, and no threads to enforce it with" above), so
  `client/tests/live-test.dylan` tests the sync state machine's own logic
  directly by constructing manager and subscription fixtures and feeding
  them hand-built Transition messages, rather than by running a fixture
  WebSocket server concurrently with the client under test in one process —
  the same tradeoff, for the same reason, documented in the ALGOL 60
  client's `live-test.alg`. The framing and handshake layer itself (masking,
  continuation-frame assembly, control frames, UTF-8 validation, and the
  real `Sec-WebSocket-Accept` check) is instead proven against a real public
  echo server, not a loopback fixture.
- Live authentication, optimistic updates, WebSocket mutations, WebSocket
  actions, and `TransitionChunk` assembly are deferred.
- Live values cover Convex's JSON-safe subset; tagged Convex value
  conversions (the undocumented `convex_encoded_json` format) are deferred.
- JSON numbers are accepted whether the server renders a whole count as an
  integer or as an integral float; a genuinely fractional value decodes as a
  Dylan `<float>` rather than being silently truncated.
- Active Live subscriptions are bounded: each subscription's delivery queue
  holds at most 64 pending updates and drops the oldest undelivered event on
  overflow rather than growing without bound. A single Live text message is
  capped at 2 MiB, matching the HTTP response cap.
- Open Dylan has no standard source formatter, so source style (no tabs, no
  trailing whitespace, a final newline, and a column limit) is checked
  explicitly in the Docker test stage rather than against a canonical
  formatter's output — the same position this project's ALGOL 60 and Forth
  clients are in.
