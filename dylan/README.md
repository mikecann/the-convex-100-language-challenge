<img src="logo.png" alt="Open Dylan logo" width="220">
<!-- Logo source: https://opendylan.org/_static/images/opendylan-light.png -->

# Dylan

Dylan is a general-purpose, object-oriented language created at Apple in the
early 1990s, initially with the Newton in mind. Scheme and Common Lisp shaped
its object model, but the modern language uses readable infix syntax rather
than Lisp parentheses. It combines dynamic-language features such as multiple
dispatch and macros with optional type constraints that help a compiler produce
efficient native code. The [official history](https://package.opendylan.org/opendylan/history/)
and [Open Dylan tour](https://opendylan.org/about/) are good introductions.

Today Dylan is a small but active open source niche centred on the
[Open Dylan compiler and libraries](https://opendylan.org/). This repository
uses it for a native network client, which is a practical way to see how its
types, multiple return values, modules, and C foreign-function interface feel
in real code. This is an educational, unofficial demonstration, not a
production SDK and not supported by Convex.

## Getting Started

Start with the canonical
[`examples/basics/main.dylan`](examples/basics/main.dylan). It queries a fresh
counter, subscribes to that same counter before changing it, applies one
idempotent mutation, and waits for the reactive `0 -> 1` update.

From the repository root, run:

```sh
./run verify-example dylan
```

That command builds and runs the exact example in Docker against a unique test
room, then checks its concise stdout transcript. It does not install Open Dylan
on your host.

## Interesting Parts

### One `let` binds a value, an error, and the logs

Dylan inherited multiple return values from Common Lisp: a function hands back
several results directly, and the caller binds them all in a single `let`. The
client's HTTP entry point uses that instead of wrapping everything in a result
object.

```dylan
// TypeScript: const state = await client.query("demo:state", { room })
let (state, query-error, _logs) =
  convex-http-call(base-url, "query", "demo:state", query-args, #f,
                   cx-now-ms() + 15000);
if (query-error)
  error(query-error.err-message); // A structured <convex-error>, not a string.
end if;
```

The trailing `#f` — Dylan's false — doubles as "no auth token" here, and
results you do not want, like the Convex log lines, simply get a throwaway
name.

### `false-or(<integer>)` is an optional type you can spell

Dylan pioneered optional typing back in 1992: annotations are ordinary type
expressions, so "an integer, or nothing" is just `false-or(<integer>)`. The
basics example uses it to absorb a real Convex quirk — the `json` HTTP format
may render a whole count as either `0` or `0.0`.

```dylan
define function count-of (value :: <object>)
 => (count :: false-or(<integer>)) // TypeScript: number | undefined
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
```

The signature documents the "maybe", and the compiler can hold callers to it.

### Waiting for a Live update is a `block` with a named exit

The Live client is a one-owner reactor: `sync-subscribe` returns a query ID,
and nothing moves until someone calls `sync-pump`. To wait for the next
reactive value, the example wraps a loop in `block (done)` — Dylan's non-local
exit, another piece of Lisp ancestry wearing infix syntax.

```dylan
// TypeScript: const state = useQuery(api.demo.state, { room })
let query-id =
  sync-subscribe(mgr, "demo:state", query-args, cx-now-ms() + 8000);
let deadline-ms = cx-now-ms() + 10000;
block (done)
  while (#t)
    let update = sync-poll-update(mgr, query-id);
    if (update) done(update) end if;          // Exit the block, value in hand.
    if (cx-now-ms() > deadline-ms) done(#f) end if;
    sync-pump(mgr, 50); // Live only advances while the reactor is pumped.
  end while;
end block
```

Each update is a `<sync-update>` whose `upd-kind` slot is the symbol
`#"value"` or `#"error"`, so the counter's `0 -> 1` change arrives as plain
data rather than a callback.

### The POSIX socket layer is declared in Dylan, not C

Open Dylan's C foreign-function interface is a set of definition macros, so
binding to C means writing more Dylan. The client's entire native layer —
sockets, `poll`, OpenSSL — is declared this way in
[`client/convex-native.dylan`](client/convex-native.dylan), with no separate C
stub file to compile.

```dylan
define C-function c-poll
  parameter fds :: <pollfd*>;
  parameter nfds :: <C-unsigned-long>;
  parameter timeout-ms :: <C-int>;
  result rc :: <C-int>;
  c-name: "poll";
end C-function;
```

This one declaration is what wakes the Live reactor whenever the WebSocket has
bytes ready.

## Status

| Capability | State | Notes |
| --- | --- | --- |
| HTTP query, mutation, action | Verified | Hand-written HTTP/1.1 over the native transport layer |
| Structured Convex errors | Verified | `FunctionError`, `ProtocolError`, and `TransportError` preserve names, messages, data, and log lines |
| TLS certificate and hostname verification | Verified | Covered by local private-CA tests and hosted evidence |
| Live subscribe, update, unsubscribe | Verified | RFC 6455 framing and the sync state machine are written in Dylan |
| WebSocket handshake verification | Verified | Checks `Sec-WebSocket-Accept` using SHA-1 from libcrypto |
| Live reconnect and rehydration | Verified | Five real reconnects were covered, with unchanged rehydration suppressed |
| Live authentication, optimistic updates, WebSocket mutations | Not implemented | Deferred in the current client |
| Earned badges | **HTTP, Live** | Existing evidence records 31/31 shared checks on local and hosted profiles |

These are evidence-backed repository results, not a claim that this README
reran conformance. The manifest records native provenance, Open Dylan 2026.2,
`linux/amd64`, and the pinned sync profile used for those results.

## Example

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

## Implementation Notes

The client is native Dylan. It does not call another Convex SDK, Node.js,
Python, `curl`, or the Convex CLI. Dylan code implements JSON, HTTP/1.1,
WebSocket framing, and the pinned Live sync behaviour. Its only foreign calls
are POSIX socket and polling functions plus OpenSSL, declared directly with
Dylan's `define C-function`. There is no separate C support file.

Open Dylan resolves the source records listed by each `.lid` project beside
that project file. The repository keeps one clear educational copy of each
client source, so the Docker build assembles a temporary directory for each
executable before compiling it:

| File | Responsibility |
| --- | --- |
| [`client/convex-native.dylan`](client/convex-native.dylan) | POSIX and OpenSSL foreign-function declarations |
| [`client/convex-json.dylan`](client/convex-json.dylan) | JSON values represented by Dylan strings, tables, vectors, numbers, and booleans |
| [`client/convex-http.dylan`](client/convex-http.dylan) | HTTP framing and Convex query, mutation, and action calls |
| [`client/convex-ws.dylan`](client/convex-ws.dylan) | WebSocket masking, fragmentation, control frames, and UTF-8 validation |
| [`client/convex-sync.dylan`](client/convex-sync.dylan) | One-owner Live reactor and bounded per-subscription queues |

One call path, `sync-pump`, owns WebSocket reads, writes, reconnects, and query
set changes. The example and conformance adapter call that reactor explicitly,
so Live only progresses while it is being pumped. On reconnect, the client
resends active subscriptions and suppresses an unchanged first value so callers
do not see a duplicate update.

TLS setup explicitly enables certificate and hostname checks. The WebSocket
handshake also recomputes `Sec-WebSocket-Accept` with libcrypto's SHA-1 rather
than trusting any HTTP 101 response. Language-local tests cover trusted,
untrusted, and wrong-host certificate cases, framing details, JSON behaviour,
and the sync state machine.

The conformance adapter is test infrastructure rather than part of the public
client API. It adds `debugDisconnect` so shared tests can force reconnects.
The underlying `/api/sync` profile is pinned but undocumented, so this project
does not claim it is a stable public Convex protocol.

## Known Issues

1. Live authentication, optimistic updates, WebSocket mutations and actions,
   and `TransitionChunk` assembly are not implemented.
2. Live values support Convex's JSON-safe subset. Tagged
   `convex_encoded_json` values are deferred.
3. Live is single-threaded and advances only while `sync-pump` runs. Local
   state-machine tests use hand-built transitions instead of an in-process
   fixture WebSocket server.
4. Each subscription holds at most 64 pending updates and drops the oldest on
   overflow. Live text messages and HTTP responses are capped at 2 MiB.
5. The client keeps one session ID for its lifetime and reuses it after a
   reconnect. That is a deliberate implementation choice recorded in the
   source, not a documented Convex guarantee.
6. Open Dylan has no standard source formatter. Docker enforces spaces, final
   newlines, no trailing whitespace, and repository line-length limits instead.
