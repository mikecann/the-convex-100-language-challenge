# Convex from Pony

A native Convex client written in Pony. It reads a shared counter over the
documented HTTP API, subscribes to the same query over a WebSocket, increments
the counter once, and proves that all three views agree on the change.

Pony is the interesting part. One actor owns the Live socket, the query set,
reconnect state, and every delivery decision, and no other actor can reach any
of it. That is not a convention this code follows carefully; it is the only
arrangement the type system permits, which removes an entire category of
reactive-client bug before the first test runs.

This is educational and unofficial. It is not a production SDK, not a
sanctioned Convex client, and not published to any package registry.

## Start here

[examples/basics/main.pony](examples/basics/main.pony) is the canonical source
and is projected verbatim below. It walks the whole journey: parse the
deployment URL, create a client, query `demo:state` over HTTP, start listening
before writing, apply `demo:increment` with an idempotency key, and then watch
the same change arrive through the live subscription. It prints six lines and
nothing else, and it fails rather than printing an unexpected value.

Pony has no blocking calls, so the example is a small state machine: each
Convex operation carries a caller-chosen step name and the answer arrives later
under that name. Reading the steps in order is reading the program in order.

## What works

| Area | Current state |
| --- | --- |
| HTTP query, mutation, action | Implemented, covered by deterministic local tests |
| Strict bounded HTTP envelopes | Implemented, covered by deterministic local tests |
| Bearer token lifecycle | Implemented, covered by deterministic local tests |
| Live subscribe, update, failure, recovery | Implemented, covered by deterministic local tests |
| Live reconnect, replay, rehydration suppression | Implemented, covered by deterministic local tests |
| Bounded Live delivery and bounded deadlines | Implemented, covered by deterministic local tests |
| NDJSON adapter over stdio and TCP | Implemented, verified |
| TLS transport (`net_ssl`) | Implemented, verified |
| Docker build, image hardening, runtime probes | Passing |
| Shared conformance, example verification, hosted drift | 31/31 on both profiles |
| Capability badges | `http`, `live` |

The shared black-box controller awarded both badges from a clean build: 31 of
31 checks against a local backend and 31 of 31 against the hosted deployment
over real TLS, with the canonical example byte-compared against the shared
transcript on both profiles.

## The basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.pony -->
```pony
use "../../client"
use "../../client/tls"
use "random"
use "time"

// Convex from Pony: read a shared counter, watch it, increment it once, and
// prove that the HTTP read, the mutation, and the live subscription all agree.
//
// Pony has no blocking calls, so the journey is written as a small state
// machine. Each Convex operation is given a caller-chosen step name, and the
// answer arrives later on `convex_ok` or `convex_failed` carrying that same
// name. Reading the steps in order below is reading the program in order.

actor Main
  new create(env: Env) =>
    // The verifier passes a room id no other run shares, so this example's
    // counter starts at zero. The default only exists for running the image
    // by hand.
    let room = try env.args(1)? else "pony-example" end

    // Configuration is the deployment URL and nothing else. Convex needs no
    // authentication for these public demo functions, so no token is set.
    let url = ExampleEnv.lookup(env.vars, "CONVEX_URL")
    if url.size() == 0 then
      env.err.print("CONVEX_URL is required")
      env.exitcode(2)
      return
    end

    try
      // Parsing the URL up front decides once whether this deployment needs
      // TLS and which host header every request carries.
      let config = ConvexConfig(ConvexEndpoint(url)?)
      // The clock is injected so deadlines are explicit, and the TLS opener
      // dials `https://` deployments and plain `http://` ones alike.
      let ticker = RealTicker
      let client = ConvexClient(config, TlsStreamOpener(env.root), ticker)
      CounterExample(env, client, ticker, room).start()
    else
      env.err.print("CONVEX_URL is not a usable Convex deployment URL")
      env.exitcode(2)
    end

primitive ExampleEnv
  """
  Pony hands a program its environment as a list of `NAME=value` strings rather
  than a map, so a small lookup is needed before anything else can start.
  """

  fun lookup(vars: Array[String] val, name: String): String =>
    let prefix: String val = name + "="
    for entry in vars.values() do
      if Bytes.starts_with(entry, prefix) then
        return HttpText.slice(entry, prefix.size(), entry.size())
      end
    end
    ""

primitive CounterValue
  """
  Decoding a Convex result into the value this example actually wants.

  Convex numbers are JSON numbers, and an integral count can legitimately
  arrive as `0`, `0.0`, or `0e0`. This client keeps a number's exact source
  text, so `integral` converts it without a float ever being involved: a
  fractional, quoted, or out-of-range count is a decoding failure rather than
  a number that has silently changed.
  """

  fun count(value: JsonValue): I64 ? =>
    match value
    | let fields: JsonObject =>
      match fields("count")?
      | let number: JsonNumber => number.integral()?
      else
        error
      end
    else
      error
    end

  fun applied(value: JsonValue): Bool ? =>
    match value
    | let fields: JsonObject =>
      match fields("applied")?
      | let flag: Bool => flag
      else
        error
      end
    else
      error
    end

  fun state(value: JsonValue): JsonValue ? =>
    match value
    | let fields: JsonObject => fields("state")?
    else
      error
    end

primitive ExampleLimits
  fun deadline_ms(): U64 => 60_000
  fun deadline_tick(): U64 => 1

actor CounterExample
  let _env: Env
  let _client: ConvexClient
  let _ticker: RealTicker
  let _room: String
  var _initial: I64 = 0
  var _expected: I64 = 0
  var _stage: USize = 0
  var _pending_live: I64 = 0
  var _has_pending: Bool = false
  var _finished: Bool = false

  new create(
    env: Env,
    client: ConvexClient,
    ticker: RealTicker,
    room: String)
  =>
    _env = env
    _client = client
    _ticker = ticker
    _room = room

  be start() =>
    // One deadline covers the whole journey. Without it a deployment that
    // never answers would leave the example waiting rather than failing.
    _ticker.schedule(
      ExampleLimits.deadline_ms(), this, ExampleLimits.deadline_tick())

    // Step one: read the room's current state over the HTTP API.
    _client.query(
      "initial-query", "demo:state", JsonOf.obj1("room", _room), this)

  be tick(tick_id: U64) =>
    _fail("timed out waiting for Convex")

  be convex_ok(step: String, result: ConvexResult) =>
    if step == "initial-query" then
      // Decode the JSON result into the one number this example cares about.
      _initial =
        try
          CounterValue.count(result.value)?
        else
          _fail("the initial query did not return an integral count")
          return
        end
      _env.out.print("current count: " + _initial.string())

      // Step two: start listening before the mutation. Subscribing first is
      // what makes the update that follows unambiguously caused by it.
      _stage = 1
      _client.subscribe(
        "counter",
        "demo:state",
        JsonOf.obj1("room", _room),
        this,
        "subscribe",
        this)
    elseif step == "mutation" then
      // Step four: the mutation's own answer, which reports whether this run
      // applied the write and what the room became.
      let applied =
        try
          CounterValue.applied(result.value)?
        else
          _fail("the mutation did not report whether it applied")
          return
        end
      if not applied then
        _fail("the mutation was not applied; the idempotency key was reused")
        return
      end
      _env.out.print("mutation applied: " + applied.string())

      let mutated =
        try
          CounterValue.count(CounterValue.state(result.value)?)?
        else
          _fail("the mutation did not return an integral count")
          return
        end
      if mutated != _expected then
        _fail("the mutation produced " + mutated.string() + ", expected " +
          _expected.string())
        return
      end
      _env.out.print("mutation count: " + mutated.string())

      // The live update may already have arrived while the mutation's HTTP
      // response was still in flight, so it is held until now to keep the
      // printed journey in the order the reader expects.
      _stage = 3
      if _has_pending and (_pending_live == _expected) then _verify() end
    end

  be convex_failed(step: String, error': ConvexError) =>
    _fail(step + " failed: " + error'.describe())

  be live_value(handle: LiveHandle, result: ConvexResult) =>
    let count =
      try
        CounterValue.count(result.value)?
      else
        _fail("a live update did not carry an integral count")
        return
      end

    if _stage == 1 then
      // Step three: a subscription publishes the query's current value first.
      // It has to match the HTTP read, or the two views of the same room have
      // already disagreed.
      if count != _initial then
        _fail("the initial live value was " + count.string() + ", expected " +
          _initial.string())
        return
      end
      _env.out.print("live initial count: " + count.string())

      // Now the write. `runId` is the idempotency key: replaying the same one
      // for this room returns the existing result instead of counting twice,
      // which is what makes a retry safe.
      _expected = _initial + 1
      _stage = 2
      _client.mutation(
        "mutation",
        "demo:increment",
        JsonOf.obj3(
          "room", _room, "language", "Pony", "runId", ExampleRunId.next()),
        this)
    elseif (_stage == 2) or (_stage == 3) then
      if count == _expected then
        _pending_live = count
        _has_pending = true
        if _stage == 3 then _verify() end
      end
    end

    // Live delivery is demand driven, so the next update is only sent once it
    // has been asked for. That is what bounds the client's memory when a
    // watcher falls behind.
    handle.request_next()

  be live_failed(handle: LiveHandle, error': ConvexError) =>
    _fail("the live subscription failed: " + error'.describe())

  fun ref _verify() =>
    if _finished then return end
    // Step five: the same increment, observed through Live rather than by
    // asking again over HTTP.
    _env.out.print("live updated count: " + _pending_live.string())
    // Reaching this line means the HTTP read, the mutation, and the live
    // subscription all agreed about the same change.
    _env.out.print("verified count: " + _initial.string() + " -> " +
      _pending_live.string())
    _finish(0)

  fun ref _fail(message: String) =>
    if _finished then return end
    // Diagnostics go to standard error. Standard output belongs to the six
    // lines the shared verifier compares.
    _env.err.print("convex example failed: " + message)
    _finish(1)

  fun ref _finish(code: I32) =>
    _finished = true
    _stage = 4
    _env.exitcode(code)
    // Cleanup: cancel the deadline and close the client, which unsubscribes,
    // shuts the Live socket down, and lets the program exit.
    _ticker.cancel(this, ExampleLimits.deadline_tick())
    _client.close("close", this)

primitive ExampleRunId
  """
  A fresh idempotency key for this run. Convex uses it to recognise a retry of
  the same logical increment, so it must not be shared between runs.
  """

  fun next(): String =>
    let random = Rand(Time.nanos(), Time.millis())
    var raw: Array[U8] iso = Array[U8](8)
    var index: USize = 0
    while index < 8 do
      raw.push(random.u8())
      index = index + 1
    end
    Hex.encode(consume raw)
```
<!-- END GENERATED EXAMPLE -->

## Verify it in Docker

    ./run test pony
    ./run verify-example pony
    ./run verify pony
    ./run verify-hosted pony

`./run test pony` builds a `linux/amd64` image that checks source style,
compiles the client, the adapter, and the example, runs both deterministic test
suites, and then probes the real adapter binary over both stdio and TCP with
malformed input. `./run verify-example pony` runs the exact
`/usr/local/bin/convex-example` entrypoint from the minimal image against a
unique room and compares its six stdout lines to the shared transcript.
`./run verify pony` adds the shared black-box conformance suite against the
approved local backend, and `./run verify-hosted pony` repeats both against the
hosted drift target.

## Conformance and protocol notes

The Live transport implements the `convex-rs 0.10.4` unversioned `/api/sync`
profile pinned in `manifest.yaml`. That endpoint is not a documented, versioned
public API, so an unrecognised envelope, including `TransitionChunk`, fails the
connection rather than being skipped.

Design decisions worth knowing before reading the code:

- **One owner.** `LiveOwner` is the only actor that touches the socket, the
  query set version, reconnect state, and replay. Subscribers and the
  conformance adapter send it behaviours.
- **Demand-driven, bounded delivery.** The owner holds a bounded queue per
  subscription (32 updates or a conservatively charged 2 MiB memory budget,
  whichever binds first) and keeps exactly
  one update in flight. A watcher asks for the next one through
  `LiveHandle.request_next()`. A watcher that stops asking cannot grow an
  unbounded Pony mailbox: the oldest updates are dropped and the newest state
  survives, which is the right trade for a reactive query. The
  `live/bounded-slow-watcher` test asserts exactly that boundary.
- **Exact numbers.** JSON numbers keep their source lexeme rather than becoming
  floats, so `0.0`, `1e2`, and `9007199254740993` all decode exactly, and a
  fractional, quoted, or out-of-range count is a decoding failure rather than a
  number that quietly changed. Echoed values also round-trip byte for byte.
- **Real handshakes.** `Sec-WebSocket-Accept` is computed and compared, client
  frames are masked, server frames must not be, and a text message is validated
  as UTF-8 only after its fragments are joined.
- **Nothing resumes mid-frame.** The frame reader never discards a partially
  received frame, so a timeout can only abandon the connection; it can never
  resynchronise at a byte that is not a frame boundary.
- **Injected time and sockets.** Deadlines and connections are interfaces, so
  every Live test runs in process against a scripted peer and a hand-fired
  clock. Nothing sleeps, and no test binds a port. Those tests prove five
  owner-level connection generations, not five real TCP/WSS reconnects. The
  latter remains a mandatory shared-verifier gate.
- **Adapter ordering.** Every emitted line passes through one output actor that
  tracks the active relay generation, so an event from a retired subscription
  can never appear after the acknowledgement that retired it. The adapter
  writes to standard output through a non-blocking descriptor rather than
  Pony's output actor. A full stdio pipe fails the adapter, and TCP pressure
  hard-closes the controller connection, so a stopped reader cannot pin an
  actor inside libc or grow the runtime's socket queue without limit.
- **`debugDisconnect` is adapter-only.** It is behind the `convex_adapter`
  build flag and is declared in `manifest.yaml`. An ordinary client build
  refuses it.

## Limitations

Honest status, in the order it matters:

- **Nothing has been compiled or run.** There is no Pony toolchain and no
  Docker build behind this source. Expect a first Docker pass to fix real
  compile errors.
- **The most likely places to break** are the ones with the least local
  evidence: the `net_ssl` API used in `client/tls`, the `ponyc` flags in the
  Dockerfile (`--static`, `--define`, `--path`), the `ifdef "convex_adapter"`
  gate, the OpenSSL `RAND_bytes` FFI used for WebSocket entropy, and the
  `@fcntl`/`@write` FFI used by the adapter's standard output writer.
  Core protocol code otherwise uses Pony's standard library, while Live links
  libcrypto only for operating-system-backed entropy.
- **Base images and `net_ssl` are pinned.** The Dockerfile records immutable
  Docker Hub digests and verifies that the `net_ssl` 1.3.2 tag resolves to the
  reviewed commit. A first Docker build still has to prove those exact pins.
- **The runtime version is stamped by the image.** Pony does not expose its
  runtime version to a program, so the Dockerfile sets
  `PONY_RUNTIME_VERSION` from the pinned toolchain and the adapter reports
  exactly that.
- **Pony has no official formatter.** The Docker test stage enforces the
  project's own rules instead: no tabs, no trailing whitespace, no line wider
  than eighty columns.
- **Deferred protocol behaviour.** Live authentication, mutations and actions
  over the WebSocket, optimistic updates, and `TransitionChunk` reassembly are
  not implemented. Each fails closed rather than being approximated.
- **Unsubscribe does not wait for the server.** It removes local state and
  writes `Remove` on a best-effort basis, then acknowledges. Close does wait,
  but only for a bounded 250 ms.
- **HTTP and Live are earned.** `capabilities` in `manifest.yaml` records the earned HTTP and Live capabilities.
