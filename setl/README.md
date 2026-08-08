# Convex from SETL

A from-scratch Convex client written in [GNU SETL](https://setl.org/setl/),
built directly on GNU SETL's own socket, TLS-callout, and set/map/tuple
primitives -- no delegated JavaScript, Node, or other Convex client underneath
it anywhere.

This is an educational demonstration for the 100 Convex Clients project, not
an official Convex SDK and not a package meant for publication.

- Selection tier: `ranked`
- Implementation status: `working`
- Earned capabilities: `http`, `live` -- see `_shared/results/` for the
  evidence and "Docker verification" below for the exact commands.

## Start here

`examples/basics/main.setl` is the canonical example: it reads a room's
counter over Convex's documented HTTP API, opens a Live subscription over
`/api/sync`, increments the counter once, and proves the Live subscription
reported the same change without polling again. It produces exactly the
shared project's universal happy-path transcript, byte for byte:

```
current count: 0
live initial count: 0
mutation applied: true
mutation count: 1
live updated count: 1
verified count: 0 -> 1
```

## What works

| Piece | Status |
| --- | --- |
| GNU SETL interpreter + TLS boundary build | Proven in Docker |
| `client/json.setl` (JSON codec) | Tested, including nested/trailing JSON `null` round-tripping |
| `client/tcp.setl` / `client/tls.setl` / `client/stream.setl` (transports) | Tested against real hosts, including a long-lived (non-closing) connection |
| `client/http.setl` (HTTP/1.1 framing) | Tested against real hosts, both transports |
| `client/convex.setl` (query/mutation/action + envelope classification) | Unit-tested; full HTTP conformance verified |
| `client/websocket.setl` (RFC 6455 framing, masking, fragmentation, UTF-8) | Tested against a real echo service, real and synthetic frames |
| `client/sync.setl` (`/api/sync` Connect/ModifyQuerySet/Transition) | Single-connection primitive; unit-tested against synthetic Transition messages |
| `client/live.setl` (reconnect, backoff, rehydration suppression) | Unit-tested synthetically; full Live conformance verified end to end |
| `examples/basics/main.setl` | Verified against both deployment profiles via `./run verify-example`/`verify-all` |
| NDJSON conformance adapter (`client/tests/conformance/main.setl`) | Full shared conformance verified, both deployment profiles |
| `example-runtime` / `runtime` Docker stages | Built, pruned, policy-checked, and verified |

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
service plus synthetic protocol-shape tests), the `/api/sync` connection
primitive and the reconnecting Live layer on top of it (synthetic Transition
messages), the example's integral-count decoding regression, a parse-and-guard
check of the canonical example, and a `hello`/`close` smoke check of the
conformance adapter. `CMD` reruns this exact suite from the built image, so
`./run test setl` re-verifies rather than only proving the build-time steps
once.

```
./run verify-example setl   # the canonical example against the local backend
./run verify setl           # + shared black-box conformance, local backend
./run verify-hosted setl    # the same, against the hosted drift target
./run verify-all setl       # both deployment profiles from one built image
```

build the `example-runtime` and `runtime` Docker stages -- a minimal,
non-root, read-only, all-capabilities-dropped image for each, staging only
GNU SETL's own runtime closure (the `setl` interpreter plus its required
`setltran`/`setlcpp` siblings, found and copied via `ldd`, never placed on
`PATH`) and this client's `.setl` source -- and run the example and the
shared conformance controller against it. `./run verify-all setl` is the
evidence in `_shared/results/local/setl-pilot-result.json` and
`_shared/results/hosted/setl-pilot-result.json`: every required HTTP and
Live test passing on both deployment profiles from the same built image,
`dirty: false`, at the exact commit this README was updated alongside.
Only the shared result evaluator computes the `http`/`live` capability
badges from that evidence; this README does not round up ahead of it.

## Known limitations

- `setltran` (GNU SETL's compiler) and `setlcpp` (its preprocessor) are
  required boot dependencies staged alongside the interpreter in the
  runtime images -- `setl` always shells out to setlcpp once a source
  file contains `#`, and to setltran to translate every program before
  running it. Neither is placed on `PATH`.
- The client keeps only the latest delivered value per subscription (no
  unbounded queue); the conformance adapter's own bounded output queue
  (8 slots, 4 MiB) is what bounds memory toward a slow or stopped
  consumer.
- Live authentication, WebSocket-issued mutations and actions, and
  `TransitionChunk` assembly are deferred; an unrecognized Transition
  modification is reported as a `ProtocolError` and the connection
  reconnects.
- `tcp_connect` has no per-call connect timeout of its own (GNU SETL's
  `open()` for `tcp-client` exposes none).

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

## `/api/sync` Live

`client/sync.setl` implements one connection's whole lifetime against the
pinned `convex-rs-0.10.4-unversioned-sync` protocol: the `Connect` handshake,
`ModifyQuerySet` (`Add`/`Remove`), and `Transition` handling (`QueryUpdated`,
`QueryFailed`, `QueryRemoved`) with the little-endian version/timestamp
tracking the reference Go client's `protocol.go` documents (a one-element
`args` array per query, and an omitted `maxObservedTimestamp` on a first
connection). `client/tests/sync_test.setl` proves the decode and
version-tracking logic by injecting hand-built `Transition` messages
directly into a connection's read buffer (no live deployment needed for this
layer, the same style `client/tests/convex_test.setl` uses for the HTTP
envelope), covering an initial `QueryUpdated`, a chained external update,
`QueryFailed` followed by a recovering `QueryUpdated` on the same
subscription, and rejection of a `Transition` whose `startVersion` does not
match.

`client/live.setl` threads a sequence of those connections together across
drops, and is the single owner of the Live socket: every read, write,
reconnect attempt, and query-set change goes through its own small set of
entry points (`live_pump`, `live_add`, `live_remove`, `live_debug_disconnect`),
each threading the same session map through explicitly. It implements:

- Automatic reconnection with exponential backoff (200ms base, capped at
  5s), reset to the base the moment a handshake succeeds -- a healthy
  connection never inherits a stale, grown delay from an earlier run of
  failures.
- Resubscribing the whole active query set on every reconnect, and
  suppressing exactly one unchanged rehydration per subscription: a
  reconnect's replayed `Add` naturally reproduces whatever value the
  subscription already had, and delivering that as if it were a new update
  would be wrong. Any later Transition -- changed or not -- delivers
  normally again.
- `connectionCount`, `lastCloseReason`, and the running maximum
  `maxObservedTimestamp` across every connection in the session, all
  resumed on the next `Connect`.
- The adapter-only `debugDisconnect` hook: tears the active connection down
  and schedules an immediate reconnect, acknowledged only after both have
  happened.

`client/tests/live_test.setl` proves the bookkeeping a live deployment is
not needed for, in the same synthetic style `client/tests/sync_test.setl`
uses one layer down: delivery, `QueryFailed` then recovery, an unchanged
rehydration being suppressed versus a changed one being delivered normally,
`live_remove`/`live_add` clearing every bit of state under a reused
subscription ID, and exponential backoff growing then capping against a real
(if instantly refused) local connection. A full end-to-end reconnect against
a real backend -- five real reconnects, backoff actually resetting after a
good handshake -- is what `./run verify`'s shared conformance run proves;
AGENTS.md is explicit that only that shared evidence earns the Live badge.

## The conformance adapter

`client/tests/conformance/main.setl` is test infrastructure, not public
client code (see AGENTS.md's "Conformance executable" section): it wraps
`client/convex.setl` and `client/live.setl` and speaks the shared harness's
NDJSON protocol v1, either over stdin/stdout or over one accepted TCP
connection when `ADAPTER_LISTEN` names a listen address. It is single
threaded, so its main loop interleaves pumping the Live connection with
reading one controller command at a time -- the same shape `client/live.setl`
itself describes as "exclusive ownership" for an interpreter with no
concurrent callers to race against in the first place. Every read, whether
of stdin or the accepted socket, goes through `client/tcp.setl`'s
`tcp_read`, reusing the same drain-one-byte-behind-`select()` pattern
described above rather than a second, adapter-specific implementation of it.

Its own output is a bounded queue: 8 slots, a 4 MiB byte budget,
subscription events droppable oldest-first, and `hello`/`result`/`error`/
`ack`/`closed` responses never dropped -- comfortably inside the shared
128 MiB adapter memory limit even under a stopped reader with near-maximum
messages.

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
- GNU SETL map assignment `m(k) := om` does not store an entry at all
  (`om` is also what a missing-key lookup returns), and a tuple's length
  is defined as the index of its *last non-om* element -- so a naive JSON
  decoder that maps a literal `null` straight to `om` silently drops an
  object key entirely (`{"k":null}` decodes the same as `{}`) and can
  silently shorten an array with a trailing null. This was not just a
  theoretical gap: shared conformance failed two required HTTP tests on
  the first real run, because Convex's own documented `demo:state`
  response sends explicit nulls for unset optional fields
  (`lastLanguage`, `latestRunId`, `updatedAt`), and this client was
  quietly dropping them instead of echoing them back. The fix decodes a
  *nested* null to a fresh `newat()` atom instead of `om` (a map or tuple
  assignment does store an atom), and `json_encode` treats any atom as
  `null` on the way back out; `json_null_to_om` (used by
  `client/convex.setl` and `client/sync.setl` wherever a value's own "top
  level" is extracted) converts it back to `om` at that one boundary, so
  a call result or a Live value still compares equal to `om` -- and to
  another connection's null value -- the way it always has, which
  `client/live.setl`'s rehydration suppression depends on. See
  `client/json.setl`'s module comment for the full reasoning.
- The conformance adapter turns the same om-omission behavior into a
  feature for its own outgoing protocol messages: an optional field is
  omitted by simply never assigning that map key, matching the shared
  schema's "omit rather than serialize null" rule for free -- except for
  a result's `value` and a structured error's `data`, which are
  sometimes legitimately JSON `null` rather than absent, and are composed
  directly with `json_encode(value)` instead of through a map for exactly
  that reason (see `client/tests/conformance/main.setl`'s own module
  comment).
- `for x in t loop ... end loop;` supports `continue;` (next iteration) and
  `quit;` (leave the loop) inside its body, the same way a `while`/`loop`
  does -- undocumented in either texinfo manual shipped with this release,
  but confirmed directly by running a small loop and confirmed present as
  real grammar tokens (`src/tran/tokenize.c`, `parse.c`, and others).
- `open(spec, "tcp-server")` plus `accept(fd)` is GNU SETL's own native
  listening-socket support -- confirmed directly the same way as the
  client-socket mode this client already used (`open(f, "tcp-client")`):
  `accept` returns a new stream fd for the accepted peer, usable with the
  same `select`/`getn`/`putc` primitives as any other stream. This is what
  lets the conformance adapter implement `ADAPTER_LISTEN`'s TCP mode with
  no native code beyond the existing TLS `callout()` boundary.

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
  realistic SETL program. `runtime-base` in `Dockerfile` ships all three
  for exactly this reason, and keeps them off `PATH`: each launcher
  invokes `/opt/convex/bin/setl` by absolute path, so `setltran`/`setlcpp`
  are reachable only as its required siblings.

`client/tests/tls_smoke.setl`, run as part of the same `test` stage, proves
the point end to end: it calls the replaced `callskel.c` dispatcher through
SETL's `callout()` builtin to open a real TLS connection to a well-known
public host, writes a plain HTTP/1.1 request, reads back a real response,
and checks it starts with `HTTP/`.
