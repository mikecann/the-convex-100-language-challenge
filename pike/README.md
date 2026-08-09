# Convex from Pike

This folder is a small, deliberately readable Convex client written in Pike. It
reads a shared counter over Convex's JSON HTTP API, watches the same query over
a live WebSocket subscription, increments it once, and proves the resulting
`0 -> 1` journey.

It is educational and unofficial. It is not a Convex SDK, it is not supported,
and it is not published anywhere. The shared conformance suites have since run
against this commit and passed, 31 of 31 checks on both the local and the
hosted profile, so it carries the `http` and `live` badges.

## Start here

[examples/basics/main.pike](examples/basics/main.pike) is the canonical runnable
source, and it is the only example projected into this README and the website.
It walks the whole journey in order: read the room over HTTP, subscribe before
writing anything, check that Convex's first live value agrees with the HTTP
read, apply one idempotent increment, and then wait for the reactive update to
arrive on the subscription that was already open. Nothing is printed as verified
until HTTP and Live agree.

The client itself is in [client/](client/). It is one program assembled from
seven readable pieces: structured errors, the JSON boundary, byte transport,
HTTP, RFC 6455, the Live sync state machine, and the client facade.

## What works

| Area | Repository state |
| --- | --- |
| HTTP queries, mutations, actions, bearer tokens | Verified locally and hosted |
| Live subscriptions, reconnect, replay, recovery | Verified locally and hosted |
| RFC 6455 client framing, masking, bounded close | Implemented in Pike, asserted byte for byte in tests |
| NDJSON adapter over stdin/stdout and `ADAPTER_LISTEN` | Implemented, with a local TCP round trip in the Docker test stage |
| Docker images, final runtime, shared verification | Passed for the reviewed source |
| Earned capabilities | HTTP and Live |

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pike -->
```pike
#!/usr/local/bin/pike

// Convex from Pike: read a shared counter over HTTP, watch the same query over
// Live, increment it once, and prove the 0 -> 1 journey.
//
// This is the canonical example. The README and the website show this exact
// file, and the Docker verifier runs this exact file against a fresh room.

// The client is compiled from source at startup rather than linked in, so the
// example, the tests, and the conformance adapter all run the same code
// wherever it happens to be installed.
string client_source()
{
  array(string) locations = ({
    getenv("CONVEX_CLIENT_PATH"),
    "/opt/convex/client",
    combine_path(dirname(__FILE__), "..", "..", "client"),
  });
  foreach (locations, string directory) {
    if (!directory || !sizeof(directory))
      continue;
    string candidate = combine_path(directory, "convex.pike");
    if (Stdio.is_file(candidate))
      return candidate;
  }
  error("could not find the Pike Convex client source\n");
  return 0;
}

// Convex sends JSON numbers, and a whole number may legitimately arrive as 0.0.
// The client's decoder accepts a mathematically integral value and rejects
// fractions, quoted numbers, and anything out of range, so the example never
// has to guess what a count meant.
int room_count(object convex, mixed state, string what)
{
  mapping room_state = convex->require_object(state, what);
  // Pike's `->` on a mapping returns 0 for a missing key, which is also a
  // legitimate count, so absence has to be checked before extraction can
  // treat a bare 0 as meaningful.
  if (zero_type(room_state->count))
    throw(convex->protocol_error(what + " state is missing its count field"));
  return convex->require_whole_number(room_state->count, what + " count");
}

// A Live update carries either a value or a classified failure, never both.
// Raising on the failure keeps the printed transcript honest: nothing is
// reported as verified unless every operation really agreed.
int live_count(object convex, object update, string what)
{
  if (update->failure)
    error("%s failed: %s\n", what, update->failure->describe());
  return room_count(convex, update->value, what);
}

int demonstrate(object convex, object client, string room)
{
  // Read the room's current state through Convex's documented JSON HTTP query
  // endpoint. A fresh room reports zero without needing to be created first.
  object current = client->query("demo:state", ([ "room": room ]));
  int before = room_count(convex, current->value, "current query");
  if (before != 0)
    error("the room started at %d instead of 0\n", before);
  write("current count: %d\n", before);

  // Subscribe before writing anything. Starting Live first is what makes the
  // increment below observable: a subscription opened afterwards could not
  // prove that the update was pushed rather than polled.
  object updates = client->subscribe("demo:state", ([ "room": room ]));

  // Convex hydrates a new Live query with its current value. That first value
  // has to agree with the HTTP read before the example changes anything.
  object initial = updates->next_update(20000);
  int live_before = live_count(convex, initial, "initial Live value");
  if (live_before != before)
    error("Live started at %d but HTTP reported %d\n", live_before, before);
  write("live initial count: %d\n", live_before);

  // runId is the mutation's idempotency key. Convex records it, so retrying
  // this logical request would return the same write instead of incrementing
  // the room a second time.
  string run_id = sprintf("pike-%s-%d-%d", room, time(), random(1000000000));
  object applied = client->mutation("demo:increment", ([
    "room": room,
    "language": "Pike",
    "runId": run_id,
  ]));
  mapping outcome = convex->require_object(applied->value, "mutation result");
  if (!convex->json_is_true(outcome->applied))
    error("Convex reported that the increment was not applied\n");
  write("mutation applied: true\n");
  int after = room_count(convex, outcome->state, "mutation");
  if (after != before + 1)
    error("the increment moved the count to %d instead of %d\n", after,
          before + 1);
  write("mutation count: %d\n", after);

  // The reactive update now arrives on the subscription opened earlier, with
  // no second HTTP query. This is the whole point of Live.
  object changed = updates->next_update(20000);
  int live_after = live_count(convex, changed, "updated Live value");
  if (live_after != after)
    error("Live reported %d but the mutation returned %d\n", live_after, after);
  write("live updated count: %d\n", live_after);

  // Only now, with HTTP and Live agreeing on the whole journey, is the run
  // verified.
  write("verified count: %d -> %d\n", before, after);

  // Stop this query before the shared client is torn down.
  updates->close();
  return 0;
}

int main(int argc, array(string) argv)
{
  string deployment_url = getenv("CONVEX_URL");
  if (!deployment_url || !sizeof(deployment_url)) {
    werror("CONVEX_URL is required\n");
    return 2;
  }

  // The verifier passes a unique room so independent runs never collide. The
  // default only exists for someone running this image by hand.
  string room = argc > 1 ? argv[1] : (getenv("EXAMPLE_ROOM") || "pike-example");

  object convex = compile_file(client_source())();
  object client = convex->Client(deployment_url);

  // Diagnostics belong on stderr: stdout is the transcript the verifier
  // compares line for line.
  int status = 1;
  mixed failed = catch { status = demonstrate(convex, client, room); };
  client->close();
  if (failed) {
    werror("pike example failed: %s\n",
           convex->as_convex_error(failed)->describe());
    return 1;
  }
  return status;
}
```
<!-- END GENERATED EXAMPLE -->

Run `./run sync-examples` after changing the source so this block and the
website stay identical to the file above.

## Verify it in Docker

    ./run test pike
    ./run verify-example pike
    ./run verify pike
    ./run verify-hosted pike

`./run test pike` builds the `test` image on `linux/amd64` and, inside it,
asserts the container architecture, the exact Pike module surface, and the
formatting gate; compiles the client, the example, and the adapter; runs every
language-local test, including the loopback socket tests; and then drives the
adapter through its stdin lifecycle, a structured `TransportError` from a real
unconfigured call, its end-of-input lifecycle, and one real `ADAPTER_LISTEN`
TCP connection. Both minimal images then run their own installed entrypoint
before they are exported, so a broken shebang, a missing include, or a client
the stripped runtime cannot compile fails the build rather than a later
verification run.

`./run verify-example pike` builds the minimal `example-runtime` image and runs
the exact canonical example above against a unique room, comparing its stdout to
the shared transcript line for line. `./run verify` adds the shared black-box
conformance suite against the approved local backend, and `./run verify-hosted`
repeats both against the hosted drift target. Only the shared result evaluator
awards capability badges.

## Conformance and protocol notes

The conformance executable in
[client/tests/conformance/](client/tests/conformance/) speaks strict NDJSON
adapter protocol v1 over stdin and stdout, or over one accepted controller
connection when `ADAPTER_LISTEN` is set. stdout carries protocol events only and
diagnostics go to stderr. Every operation calls the real client; nothing is
simulated. Failures are published as `FunctionError`, `ProtocolError`,
`TransportError`, or `ClosedError`, and optional fields are omitted rather than
serialized as null, because the shared schema has no room for an invented one.

Live uses the pinned `convex-rs-0.10.4-unversioned-sync` profile at source
commit `6f1df8a8ba1665084ec001e307ca841ca17074d7`, over `/api/sync`. One owner
object is the only thing that reads the socket, writes the socket, changes the
query-set version, or schedules a reconnect; subscribers and the adapter send it
commands. A `Transition` is fully validated before any of it is applied, so a
rejected modification cannot advance the version, move the observed timestamp,
or leave half a transaction visible. Connections carry `connectionCount`,
`lastCloseReason`, and `maxObservedTimestamp`, replay their active `Add`
operations, and reset exponential backoff after a completed handshake or a valid
transition. An unchanged rehydration after a reconnect is suppressed, so the
observed sequence over five real reconnects stays exactly initial value,
acknowledgement, external mutation, new value. A connection the server has gone
quiet on for 30 seconds is retired as `InactiveServer` and replaced, because a
blackholed socket is indistinguishable from an idle one and would otherwise
strand every subscription it was carrying.

Underneath all of that, one byte channel owns the socket. It reports itself
ready only once the stream has proved it can accept application bytes, which
for TLS means the handshake finished rather than merely started, and it keeps
the write callback armed only while bytes are actually queued so an idle
connection cannot spin the backend on a CPU-limited container. A connection
that fails before its owner has attached handlers still announces that failure
exactly once, so a refused connect is diagnosed rather than lost. Those are the
parts an in-process fake cannot prove, so they are tested over loopback with a
real descriptor.

The RFC 6455 layer is written in Pike over one byte channel. It validates the
101 accept value against the key it sent, masks every client frame, reassembles
fragmented messages byte for byte including UTF-8 sequences split across
fragments, answers pings, and refuses reserved bits, masked server frames,
oversized frames, malformed control frames, and interleaved data frames. A frame
that has started arriving keeps its exact parser state; if it stalls past the
deadline the connection is abandoned rather than resynchronised at a guessed
boundary. Close is bounded by a deadline, not by the peer: an idle peer, a
flooding peer, and a peer stalled halfway through a frame all retire on time.

Buffering is deliberate and bounded in both directions. A subscription relay
holds at most 16 updates and 2 MiB of accounted payload and fails closed with a
structured transport error rather than growing or silently dropping the oldest
update. The adapter's output FIFO holds at most 64 events and 8 MiB, counts a
conservative per-entry allowance alongside the encoded line, and keeps a
partially written line queued and accounted for while a stopped reader blocks
the write. Both bounds are asserted by tests that stop the reader, not by
inspection.

## Limitations

Docker images, language-local tests, the canonical example, and shared local
and hosted conformance passed, earning HTTP and Live.
The base image is pinned by digest and every apt package is pinned to its exact
bookworm revision taken from the published Debian index, so a revision that has
since left the archive will fail that build line loudly rather than resolve to a
newer one. Two TLS assumptions are still source-level claims. Pike spells the
`SSL.Context` trust store API differently across releases, so the setup probes
the context's identifiers and refuses to open an unverified connection when it
finds none; the runtime image asserts that the trust store loads and holds a
plausible number of authorities, which is where that probe gets settled. The
socket channel likewise assumes `SSL.File` reports itself writable once its
handshake completes, and the loopback tests can only prove that half of the
contract without TLS.

Values cover Convex's JSON-safe subset. Tagged Convex values such as `Int64` and
bytes, Live authentication, WebSocket mutations and actions, optimistic updates,
journals, and `TransitionChunk` assembly are deliberately deferred, and a
`TransitionChunk` is refused rather than half-applied. Pike ships no canonical
source formatter, so formatting is enforced by a language-local style gate over
tabs, trailing whitespace, line width, line endings, and non-ASCII source
characters instead of by a tool. This demonstration is tied to an undocumented
Live profile and treats any drift from it as an error.
