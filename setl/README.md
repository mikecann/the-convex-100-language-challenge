# Convex from SETL

A from-scratch Convex client written in [GNU SETL](https://setl.org/setl/),
built directly on GNU SETL's own socket, TLS-callout, and set/map/tuple
primitives -- no delegated JavaScript, Node, or other Convex client underneath
it anywhere.

This is an educational demonstration for the 100 Convex Clients project, not
an official Convex SDK and not a package meant for publication.

- Selection tier: `ranked`
- Implementation status: `attempting`
- Earned capabilities: none yet -- see "Where this stands" below.

## Start here

`examples/basics/main.setl` is the canonical example: it reads a room's
counter over Convex's documented HTTP API, opens a Live subscription over
`/api/sync`, increments the counter once, and proves the Live subscription
reported the same change without polling again. Run manually against the
local self-hosted backend, it produces exactly the shared project's
universal happy-path transcript:

```
current count: 0
live initial count: 0
mutation applied: true
mutation count: 1
live updated count: 1
verified count: 0 -> 1
```

That run has been proven by hand, byte for byte against
`_shared/examples/basics.expected.txt`, but not yet through
`./run verify-example setl` -- there is no `example-runtime` Docker stage to
run it from yet (see "Where this stands").

## What works so far

| Piece | Status |
| --- | --- |
| GNU SETL interpreter + TLS boundary build | Proven in Docker |
| `client/json.setl` (JSON codec) | Tested, 26 checks |
| `client/tcp.setl` / `client/tls.setl` / `client/stream.setl` (transports) | Tested against real hosts, including a long-lived (non-closing) connection |
| `client/http.setl` (HTTP/1.1 framing) | Tested against real hosts, both transports |
| `client/convex.setl` (query/mutation/action + envelope classification) | Unit-tested against synthetic responses |
| `client/websocket.setl` (RFC 6455 framing, masking, fragmentation, UTF-8) | Tested against a real echo service, real and synthetic frames |
| `client/sync.setl` (`/api/sync` Connect/ModifyQuerySet/Transition) | Single-connection subset; no reconnect/backoff/bounded queue yet |
| `examples/basics/main.setl` | Runs correctly by hand against the real local backend; not yet Docker-verified |
| NDJSON conformance adapter (`debugDisconnect`) | Not started |
| `example-runtime` / `runtime` Docker stages | Not started |

## The canonical example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.setl -->
```setl
-- Convex from SETL: the shared counter journey.
--
-- Reads a room's counter over Convex's documented HTTP API, starts a
-- Live subscription, increments the counter once, and proves that the
-- Live subscription reported the same change without polling. This is
-- an educational demonstration of a hand-written, from-scratch Convex
-- client (see ../../README.md), not an official Convex SDK.
--
-- Run it with:
--   CONVEX_URL=https://<deployment>.convex.cloud setl --cpp main.setl <room>
--
-- This file's own executable statements all come first, and every
-- helper it defines -- along with every client module it pulls in via
-- #include -- follows them: GNU SETL requires a source unit's mainline
-- statements to precede every proc definition, with no interleaving.
-- See client/json.setl's module comment for more on why this client is
-- laid out that way throughout.

-- Configuration: the deployment URL is required. The room comes from
-- the verifier's first command-line argument (so repeated runs never
-- collide), an EXAMPLE_ROOM environment variable for a convenient hand
-- run, or a literal fallback so this still does something either way.
deployment_url := getenv("CONVEX_URL");
if deployment_url = om or deployment_url = "" then
  printa(stderr, "SETL example failed: CONVEX_URL is required");
  stop 1;
end if;

room := om;
if #command_line >= 1 then
  room := command_line(1);
end if;
if room = om or room = "" then
  room := getenv("EXAMPLE_ROOM");
end if;
if room = om or room = "" then
  room := "setl-example";
end if;

query_args := {};
query_args("room") := room;

-- The HTTP query: reads the room's current counter through Convex's
-- documented POST /api/query envelope, before anything reactive is
-- involved, so the Live subscription below has a known value to agree
-- with.
response := convex_query(deployment_url, "demo:state", query_args, om, 10000);
if response("kind") /= "result" then
  printa(stderr, "SETL example failed: query: " + str(response("errMessage")));
  stop 1;
end if;
-- Decoding into an idiomatic value: Convex JSON may encode an integral
-- count as 0 or as 0.0 (see examples/basics/count.setl), and either
-- other shape is a bug this example must fail loudly on, not paper over.
[decoded, current, decode_message] := convex_state_count(response("value"), "current query");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  stop 1;
end if;
print("current count: " + str(current));

-- Client creation: opens the WebSocket handshake to /api/sync and sends
-- the Connect message (client/sync.setl). No query has been added yet.
[connected, sync] := sync_connect(deployment_url, "setl-0.1.0", 10000);
if not connected then
  printa(stderr, "SETL example failed: sync connect: " + str(sync));
  stop 1;
end if;

-- Starting Live before the mutation: subscribing first is what makes
-- the update received below an observation of a real change, rather
-- than a race against one that already happened.
[subscribed, sync, query_id] := sync_add(sync, "demo:state", query_args);
if not subscribed then
  printa(stderr, "SETL example failed: subscribe: " + str(sync("last_error")));
  sync_close(sync, "example failed");
  stop 1;
end if;

-- The initial Live value: the same state the HTTP query above already
-- read, delivered this time as the subscription's first Transition.
[outcome, sync, result] := sync_wait_next(sync, query_id, 10000);
if outcome /= "ok" or result("kind") /= "value" then
  printa(stderr, "SETL example failed: initial Live value: " + str(sync("last_error")));
  sync_close(sync, "example failed");
  stop 1;
end if;
[decoded, live_initial, decode_message] := convex_state_count(result("value"), "initial Live value");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  sync_close(sync, "example failed");
  stop 1;
end if;
if live_initial /= current then
  printa(stderr, "SETL example failed: the initial Live count disagreed with HTTP");
  sync_close(sync, "example failed");
  stop 1;
end if;
print("live initial count: " + str(live_initial));

-- The mutation and its idempotency key: runId lets Convex recognize a
-- retried request and return the previous result instead of
-- incrementing twice. A fresh random key means this run really applies
-- its increment rather than replaying an old one.
mutation_args := {};
mutation_args("room") := room;
mutation_args("language") := "setl";
mutation_args("runId") := random_hex(16);
mutation_response := convex_mutation(deployment_url, "demo:increment", mutation_args, om, 10000);
if mutation_response("kind") /= "result" then
  printa(stderr, "SETL example failed: mutation: " + str(mutation_response("errMessage")));
  sync_close(sync, "example failed");
  stop 1;
end if;
mutation_value := mutation_response("value");
if mutation_value = om or mutation_value("applied") /= true then
  printa(stderr, "SETL example failed: the mutation was not applied");
  sync_close(sync, "example failed");
  stop 1;
end if;
[decoded, mutation_count, decode_message] := convex_state_count(mutation_value("state"), "mutation");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  sync_close(sync, "example failed");
  stop 1;
end if;
expected := current + 1;
if mutation_count /= expected then
  printa(stderr, "SETL example failed: the mutation returned an unexpected count");
  sync_close(sync, "example failed");
  stop 1;
end if;
print("mutation applied: true");
print("mutation count: " + str(mutation_count));

-- The resulting Live update: received over the same subscription,
-- without polling HTTP again.
[outcome, sync, result] := sync_wait_next(sync, query_id, 10000);
if outcome /= "ok" or result("kind") /= "value" then
  printa(stderr, "SETL example failed: updated Live value: " + str(sync("last_error")));
  sync_close(sync, "example failed");
  stop 1;
end if;
[decoded, live_updated, decode_message] := convex_state_count(result("value"), "updated Live value");
if not decoded then
  printa(stderr, "SETL example failed: " + decode_message);
  sync_close(sync, "example failed");
  stop 1;
end if;
if live_updated /= expected then
  printa(stderr, "SETL example failed: the updated Live count disagreed with the mutation");
  sync_close(sync, "example failed");
  stop 1;
end if;
print("live updated count: " + str(live_updated));

-- Every operation above agreed before this proof line is printed.
print("verified count: " + str(current) + " -> " + str(live_updated));

-- Cleanup: close the Live connection cleanly before exiting.
sync_close(sync, "example complete");

-- Generates AByteCount random bytes as lowercase hex, for the mutation's
-- idempotency key above. It does not need to be unpredictable, only
-- unique enough that this run's key has never been sent before.
proc random_hex(byte_count);
  hex_digits := "0123456789abcdef";
  out := "";
  for i in [1..byte_count] loop
    b := random(255);
    out +:= hex_digits(b div 16 + 1);
    out +:= hex_digits(b mod 16 + 1);
  end loop;
  return out;
end proc;

#include "tcp.setl"
#include "tls.setl"
#include "stream.setl"
#include "http.setl"
#include "json.setl"
#include "websocket.setl"
#include "convex.setl"
#include "sync.setl"
#include "count.setl"
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```
./run test setl
```

builds GNU SETL from source and runs every unit-level test in this table
inside the Dockerfile's `test` stage: the JSON codec, both transports, the
HTTP envelope classifier, the WebSocket client (against a real public echo
service plus synthetic protocol-shape tests), the `/api/sync` subset
(synthetic Transition messages), and the example's integral-count decoding
regression. None of this proves the example or shared conformance; those
need `./run verify-example setl` and `./run verify setl`, which need the
runtime Docker stages this client does not have yet.

## Where this stands

This client is mid-build, not paused for a technical blocker. In order:

1. Interpreter build, TLS boundary, JSON, HTTP, and the Convex HTTP
   envelope -- done and Docker-tested.
2. RFC 6455 WebSocket framing -- done and Docker-tested (masking,
   fragmentation reassembly, interleaved control frames, UTF-8
   validation).
3. A single-connection `/api/sync` Live subset -- done and Docker-tested,
   but missing automatic reconnection, exponential backoff,
   `connectionCount`/`lastCloseReason` tracking, rehydration suppression,
   `debugDisconnect`, and the bounded delivery queue AGENTS.md requires.
   These are exactly what full Live conformance needs next.
4. The canonical example -- written and manually verified end to end
   against the real local backend (see "Start here"), but not yet run
   through Docker.
5. Still to build: the NDJSON conformance adapter, the
   `example-runtime`/`runtime` Docker stages, and every verification layer
   from `./run verify-example setl` through `./run verify-all setl`. No
   capability badge can be claimed before those run and pass.

## The `callout()` boundary

SETL2's `callout` (kept in GNU SETL for SETL2 compatibility) is not a
general FFI. It is a single fixed-signature C dispatcher:

```c
char *setl2_callout(int service, unsigned argc, char *const argv[]);
```

invoked from SETL source as `callout(service, om, arglist)`, where
`arglist` is a tuple of strings. Every argument and the single return value
are C strings, so this is the only native extension point GNU SETL exposes,
and every raw byte that crosses it -- both directions of TLS traffic --
must be encoded as a string. `client/callskel.c` uses GNU SETL's own
built-in `hex`/`unhex` operators for that encoding (not a hand-rolled
scheme), so the SETL-side wrapper never needs anything beyond what the
standard library already provides. See the block comment at the top of
`client/callskel.c` for the service codes (`PING`, `TLS_CONNECT`,
`TLS_WRITE`, `TLS_READ`, `TLS_CLOSE`, `SHA1`) and exactly what each returns.

Plain HTTP and Live against a local self-hosted deployment do not need any
of this: GNU SETL's native `open(f, "tcp-client")` opens a real socket
directly, so the local profile never touches `callout()` or OpenSSL at
all. Only the hosted (TLS) profile does.

## RFC 6455 WebSocket framing

`client/websocket.setl` sits on top of `client/stream.setl`, so it works
unchanged over either transport: plain TCP for the local profile, and the
hex-encoded `callout()` boundary for the hosted (TLS) profile. It
implements the HTTP Upgrade handshake with a verified
`Sec-WebSocket-Accept` token (the SHA-1 half of that check runs through a
`callout()` service rather than being hand-rolled in SETL, reusing the
OpenSSL already linked in for TLS), one masked, unfragmented text frame per
outbound send, and inbound reassembly of fragmented messages with
transparent ping/pong replies, peer-close handling, and a single UTF-8
validation pass over the fully reassembled message (never
fragment-by-fragment, since a multi-byte code point can legally split
across a fragment boundary).

`client/tests/websocket_test.setl` proves this two ways in the same `test`
stage: a real connection to a public WebSocket echo service round-trips a
short frame, a frame past the 125-byte length encoding, and a clean close;
a second real connection then has its read buffer filled by hand with
hand-built frames to deterministically exercise fragmentation reassembly, a
ping interleaved between fragments, and rejection of a lone UTF-8
continuation byte -- properties a public echo service cannot be relied on
to reproduce, since it only ever echoes back whatever this client already
sent it.

## `/api/sync` Live state machine (single-connection subset)

`client/sync.setl` implements the pinned `convex-rs-0.10.4-unversioned-sync`
protocol's `Connect` handshake, `ModifyQuerySet` (`Add`/`Remove`), and
`Transition` handling (`QueryUpdated`, `QueryFailed`, `QueryRemoved`) with
the little-endian version/timestamp tracking the reference Go client's
`protocol.go` documents (a one-element `args` array per query, and an
omitted `maxObservedTimestamp` on the first connection). `client/tests/sync_test.setl`
proves the decode and version-tracking logic by injecting hand-built
`Transition` messages directly into a connection's read buffer (no live
deployment needed for this layer, the same style `client/tests/convex_test.setl`
uses for the HTTP envelope), covering an initial `QueryUpdated`, a chained
external update, `QueryFailed` followed by a recovering `QueryUpdated` on
the same subscription, and rejection of a `Transition` whose `startVersion`
does not match.

Not implemented yet: automatic reconnection with exponential backoff,
`connectionCount`/`lastCloseReason` tracking across reconnects, rehydration
suppression, the adapter-only `debugDisconnect` hook, and the bounded
delivery queue AGENTS.md requires for a slow consumer. A transport failure
or unexpected server message currently surfaces as an `"error"`/`"closed"`
outcome instead of retrying.

## GNU SETL lessons learned along the way

- A source unit's mainline (executable) statements must all precede its
  `proc` definitions, with no interleaving -- confirmed by hitting the
  syntax error directly, not from documentation. Every proc-only module in
  `client/` is therefore meant to be `#include`d (via `setl --cpp`) near
  the end of a file, after that file's own mainline code. This applies
  inside a single file too: a helper `proc` a script calls must still be
  defined textually after every one of that script's own top-level
  statements, not before them.
- GNU SETL procs have no closure over their caller's variables. A bare
  identifier inside a `proc` that is not one of its own parameters is
  always a fresh local, never a reference to a same-named variable in the
  scope that called it -- confirmed directly (a proc that does `counter +:= 1`
  where `counter` is a mainline variable of the same name leaves the
  mainline's `counter` completely untouched). Every helper in this client
  therefore threads state through explicit parameters and return values,
  never through an assumed shared variable; `examples/basics/tests/count_test.setl`'s
  `check()` helper returns a pass/fail count for its caller to accumulate,
  rather than trying to increment a shared counter itself, for exactly
  this reason.
- Maps and tuples are passed to procs by value, with the same consequence:
  a helper that mutates a map parameter and returns nothing has mutated a
  copy nobody outside it can see. `client/sync.setl` hit this directly --
  a `sync_bump_revision(sync, queryId)` helper that updated `sync` but did
  not return it silently did nothing, because GNU SETL passes maps by
  value the same as everything else. The fix inlines the mutation instead
  of delegating to an unreturned helper; every other stateful module in
  this client (the WebSocket connection map, the sync session map) threads
  its state through explicit reassignment for the same reason.
- `getn(fd, n)` blocks until it has read exactly `n` bytes or hit EOF
  (confirmed against GNU SETL's own `get_chars` in `src/run/lib.c`, which
  loops a single-character read up to `n` times with no short-read
  return). `client/tcp.setl`'s original read function called
  `getn(fd, max_bytes)` as soon as `select()` reported the socket
  readable -- which works for a short HTTP exchange where the peer closes
  the connection after responding (EOF satisfies the call even with fewer
  than `max_bytes` available), but hangs indefinitely on a long-lived
  connection, such as a WebSocket, that sends one small frame and then
  goes quiet without closing. This was not caught by `client/tests/http_test.setl`
  (which only ever exercises connection-closing exchanges); it surfaced
  the first time `client/sync.setl` tried a real `/api/sync` handshake
  over plain TCP and the process hung past every timeout the code itself
  requested. The fix reads one byte once `select()` confirms readiness,
  then drains further bytes one at a time behind their own zero-timeout
  `select()` poll, stopping the moment nothing more is immediately
  available rather than blocking for a byte count the peer never
  promised to send.
- Several plausible identifiers are reserved words: `wr`, `reads`, `ok`,
  `is_float`, `host`, `port`, `body`, `status`, `hostname`, `op`, `len`,
  among others hit while writing this client. There is no single
  documented list to check against; `src/lexicon` in the GNU SETL source
  tree is the ground truth.
- GNU SETL map assignment `m(k) := om` does not store an entry (`om` is
  also what a missing-key lookup returns), so this client's JSON decoder
  cannot tell an object's `{"k":null}` apart from `{}` -- see the module
  comments in `client/json.setl` and `client/convex.setl`.

## Build recipe (proven)

`Dockerfile`'s `test` stage builds GNU SETL 8.13.22 from source
(`https://setl.org/setl/setl-8.13.22.tgz`, pinned by sha256) entirely inside
Docker, with `src/run/callskel.c` replaced by `client/callskel.c` before the
interpreter is compiled, then relinked against `-lssl -lcrypto`. Two things
had to be worked out and are captured directly in the Dockerfile's
comments:

- GNU SETL's own top-level `make` interactively prompts for a build
  directory and configure options on a clean checkout. The unattended path
  is to pre-seed `config.parms` (the file that prompt would otherwise
  write) with the desired `configure` arguments and touch its witness
  timestamp file, so `make` treats configuration as already done.
- `setl` resolves its `setltran` (compiler) and `setlcpp` (preprocessor)
  helpers relative to its own install location, not via `PATH`; without
  `make install`, the build stages symlinks next to the built `setl`
  binary instead. Both helpers turn out to be needed at runtime too, not
  just at build time: `setltran` compiles every script before it runs
  (confirmed by removing it and watching a trivial script fail), and
  `setlcpp` is invoked even without an explicit `--cpp` flag once a
  script uses the `#` length operator at all -- which is to say, in any
  realistic SETL program. The planned runtime Docker stages will need to
  ship all three binaries for exactly this reason.

`client/tests/tls_smoke.setl`, run as part of the same `test` stage, proves
the point end to end: it calls the replaced `callskel.c` dispatcher through
SETL's `callout()` builtin to open a real TLS connection to a well-known
public host, writes a plain HTTP/1.1 request, reads back a real response,
and checks it starts with `HTTP/`.
