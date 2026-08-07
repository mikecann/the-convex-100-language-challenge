# Convex from Oberon-07

This is a small native Oberon-07 client for Convex HTTP functions and reactive Live queries, built with OBNC, the Oberon-to-C compiler.

It is an educational, unofficial experiment. It is not a production SDK and is not intended for package publication.

## Start here

Read [`examples/basics/main.obn`](examples/basics/main.obn). It queries a fresh counter over HTTP, opens a Live subscription before mutating anything, applies one idempotent mutation, and checks that the HTTP query, the mutation result, and the Live subscription all agree on the same `0 -> 1` journey.

## What works

| Capability | Status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, log lines, and structured errors | Implemented; language-local Docker tests pass, shared conformance pending |
| Live initial values, external updates, and `QueryFailed` followed by recovery | Implemented; proved against a loopback fixture in `client/tests/TestLive.obn`, shared conformance pending |
| A forced reconnect with Add resend, rehydration suppression, and `connectionCount` bookkeeping | Implemented; proved against `client/tests/FixtureServer.obn`, shared conformance pending |
| WebSocket mutations, actions, Live authentication, optimistic updates | Not implemented |
| `TransitionChunk` assembly | Not implemented; treated as protocol drift and reconnects |
| Production SDK compatibility | Not claimed |

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.obn -->
```oberon
(*Convex from Oberon-07: the canonical "shared counter" walkthrough.

  This program is the single source of truth for the code shown in the
  README and on the project website; ./run sync-examples projects this
  exact file there, comments and all.

  It demonstrates, over a real Convex deployment:
    - configuring the client from the deployment URL,
    - an HTTP query,
    - opening a Live subscription and reading its initial value,
    - an idempotent HTTP mutation,
    - the Live update that the mutation produces,
    - and orderly shutdown.*)
MODULE main;

	IMPORT J := ConvexJSON, S := ConvexSync, Shim := ConvexShim, extEnv, extArgs, Out;

	CONST MaxJson = 65536;

	VAR
		url: ARRAY 512 OF CHAR;
		room: ARRAY 256 OF CHAR;
		args, value, logs, errorName, errorMessage, errorData: ARRAY MaxJson OF CHAR;
		hasErrorData, ok: BOOLEAN;
		transportError: ARRAY 256 OF CHAR;
		handle, count: INTEGER;
		haveUrlRes, roomRes: INTEGER;

	(*AppendLit appends a 0X terminated literal to a 0X terminated buffer;
	  Oberon has no string concatenation operator. A backtick stands in
	  for a literal double quote, since OBNC's lexer accepts neither an
	  escaped quote nor the language report's alternative single quote
	  delimiter (see ConvexSync.obn's AppendBuf for the same convention).*)
	PROCEDURE AppendLit(text: ARRAY OF CHAR; VAR destination: ARRAY OF CHAR);
	VAR base, extra, i: INTEGER;
	BEGIN
		base := 0;
		WHILE destination[base] # 0X DO INC(base) END;
		extra := 0;
		WHILE text[extra] # 0X DO INC(extra) END;
		i := 0;
		WHILE i < extra DO
			IF text[i] = "`" THEN destination[base + i] := CHR(34) ELSE destination[base + i] := text[i] END;
			INC(i)
		END;
		destination[base + extra] := 0X
	END AppendLit;

	(*Fail prints a diagnostic and exits non zero: the example must fail
	  loudly on any unexpected value, not just when a call errors
	  outright.*)
	PROCEDURE Fail(message: ARRAY OF CHAR);
	BEGIN
		Out.String("basics: "); Out.String(message); Out.Ln;
		Shim.Exit(1)
	END Fail;

	(*DecodeCount extracts the "count" member of a Convex demo:state style
	  JSON object and decodes it as an ordinary integer. Convex may encode
	  a whole number in JSON's integral float form (0.0, 1.0); this only
	  accepts values that are mathematically integral, matching
	  AGENTS.md's requirement that example decoding reject genuinely
	  fractional values rather than silently truncating them.*)
	PROCEDURE DecodeCount(VAR json: ARRAY OF CHAR; VAR result: INTEGER): BOOLEAN;
	VAR raw: ARRAY 64 OF CHAR; found, negative, ok: BOOLEAN; i, cap: INTEGER;
	BEGIN
		ok := J.Member(json, "count", raw, found) & found;
		IF ok THEN ok := J.IsIntegralNumber(raw) END;
		IF ok THEN
			cap := 0;
			WHILE raw[cap] # 0X DO INC(cap) END;
			negative := FALSE;
			i := 0;
			IF (cap > 0) & (raw[0] = "-") THEN negative := TRUE; i := 1 END;
			result := 0;
			WHILE (i < cap) & (raw[i] >= "0") & (raw[i] <= "9") DO
				result := result * 10 + (ORD(raw[i]) - ORD("0"));
				INC(i)
			END;
			IF negative THEN result := -result END
		END;
		RETURN ok
	END DecodeCount;

	PROCEDURE AwaitLiveCount(targetHandle: INTEGER; VAR result: INTEGER);
	VAR
		eventKind, eventHandle, waited: INTEGER;
		eventValue, eventLogs, eventErrorName, eventErrorMessage, eventErrorData: ARRAY MaxJson OF CHAR;
		eventHasErrorData, done, decoded: BOOLEAN;
	BEGIN
		waited := 0;
		done := FALSE;
		WHILE ~done DO
			S.Pump(200, eventKind, eventHandle, eventValue, eventLogs, eventErrorName, eventErrorMessage, eventErrorData, eventHasErrorData);
			IF (eventKind # 0) & (eventHandle = targetHandle) THEN
				IF eventKind = 2 THEN Fail("Live subscription failed unexpectedly") END;
				decoded := DecodeCount(eventValue, result);
				IF ~decoded THEN Fail("Live value was not a demo:state object") END;
				done := TRUE
			ELSE
				INC(waited);
				IF waited > 150 THEN Fail("timed out waiting for a Live update") END
			END
		END
	END AwaitLiveCount;

	(*CheckMutationResult validates demo:increment's {"applied":true,
	  "state":{...,"count":1,...}} shape without assuming field order.*)
	PROCEDURE CheckMutationResult(VAR result: ARRAY OF CHAR);
	VAR appliedRaw, stateRaw: ARRAY MaxJson OF CHAR; found, decoded: BOOLEAN; stateCount: INTEGER;
	BEGIN
		IF ~(J.Member(result, "applied", appliedRaw, found) & found) THEN
			Fail("unexpected mutation result")
		END;
		IF ~((appliedRaw[0] = "t") & (appliedRaw[1] = "r") & (appliedRaw[2] = "u") & (appliedRaw[3] = "e") & (appliedRaw[4] = 0X)) THEN
			Fail("unexpected mutation result")
		END;
		IF ~(J.Member(result, "state", stateRaw, found) & found) THEN
			Fail("unexpected mutation result")
		END;
		decoded := DecodeCount(stateRaw, stateCount);
		IF ~decoded OR (stateCount # 1) THEN
			Fail("unexpected mutation result")
		END
	END CheckMutationResult;

BEGIN
	(*Configure this client from the verifier-selected deployment. The
	  dedicated public demo functions need no authentication token.*)
	url[0] := 0X;
	extEnv.Get("CONVEX_URL", url, haveUrlRes);
	IF haveUrlRes < 0 THEN Fail("CONVEX_URL is required") END;
	S.Init(url, "");

	(*Accept the verifier's unique room ID as argv[1], with a friendly
	  default for anyone running the image by hand.*)
	IF extArgs.count > 0 THEN
		extArgs.Get(0, room, roomRes)
	ELSE
		AppendLit("oberon-basic-example", room)
	END;

	(*Query the counter over HTTP before opening the Live subscription, so
	  the printed transcript always starts from a known value.*)
	args[0] := 0X;
	AppendLit("{`room`:", args);
	IF ~J.AppendQuoted(room, args) THEN Fail("room id was too long") END;
	AppendLit("}", args);
	S.Call("query", "demo:state", args, value, logs, errorName, errorMessage, errorData, hasErrorData, ok, transportError);
	IF ~ok THEN Fail(transportError) END;
	IF errorName[0] # 0X THEN Fail("unexpected initial HTTP value") END;
	IF ~DecodeCount(value, count) OR (count # 0) THEN Fail("unexpected initial HTTP value") END;
	Out.String("current count: 0"); Out.Ln;

	(*Start the Live subscription before the mutation, so the mutation
	  cannot race past it.*)
	S.Subscribe("demo:state", args, handle, ok, transportError);
	IF ~ok THEN Fail(transportError) END;
	AwaitLiveCount(handle, count);
	IF count # 0 THEN Fail("unexpected initial Live value") END;
	Out.String("live initial count: 0"); Out.Ln;

	(*The room-specific idempotency key makes a retry of this example
	  safe: this mutation increments the counter at most once.*)
	args[0] := 0X;
	AppendLit("{`room`:", args);
	IF ~J.AppendQuoted(room, args) THEN Fail("room id was too long") END;
	AppendLit(",`language`:`Oberon-07`,`runId`:`", args);
	AppendLit(room, args);
	AppendLit("-once`}", args);
	S.Call("mutation", "demo:increment", args, value, logs, errorName, errorMessage, errorData, hasErrorData, ok, transportError);
	IF ~ok THEN Fail(transportError) END;
	IF errorName[0] # 0X THEN Fail("unexpected mutation result") END;
	CheckMutationResult(value);
	Out.String("mutation applied: true"); Out.Ln;
	Out.String("mutation count: 1"); Out.Ln;

	(*Wait for the server Transition carrying the same updated counter.*)
	AwaitLiveCount(handle, count);
	IF count # 1 THEN Fail("unexpected updated Live value") END;
	Out.String("live updated count: 1"); Out.Ln;

	(*Unsubscribe before the process exits so the server sees an orderly
	  close rather than a dropped connection.*)
	S.Unsubscribe(handle);

	(*Stdout is deliberately this exact six line happy-path transcript.*)
	Out.String("verified count: 0 -> 1"); Out.Ln
END main.
```
<!-- END GENERATED EXAMPLE -->

## Docker verification

```sh
./run sync-examples
./run validate
./run test oberon
./run build oberon
```

The `test` target builds OBNC 0.17.2 from source, compiles every module and program for real `linux/amd64`, runs the language-local unit and Live acceptance tests, and exercises the NDJSON adapter's hello/close lifecycle. The `build` target produces the non-root `runtime` (adapter) image; `example-runtime` is built the same way with a different Dockerfile target. Root owns `verify-example`, `verify`, and `verify-hosted` because those commands serialize the shared backend and evidence store.

## Protocol and runtime notes

The client implements Convex's HTTP envelopes and this repository's pinned `/api/sync` profile directly in Oberon-07. The only foreign code is `client/ConvexShim.c`, a small C shim declared to OBNC through `client/ConvexShim.obn`'s `(*implemented in C*)` module (the same mechanism the standard library uses for its own C-backed modules, such as file and pipe I/O) that supplies raw POSIX sockets, OpenSSL for TLS, `poll()`, a monotonic clock, CSPRNG bytes, and SHA-1 for the WebSocket handshake key. It contains no Convex, HTTP, JSON, or WebSocket framing logic; all of that is `client/ConvexBase64.obn`, `client/ConvexJSON.obn`, `client/ConvexURL.obn`, `client/ConvexHTTP.obn`, `client/ConvexWS.obn`, and `client/ConvexSync.obn`.

`ConvexSync` is a process-wide singleton with one worker: the process calling `Pump()` is the sole owner of the WebSocket socket, reconnect state, and query-set version, matching this repository's requirement that controller and subscription work never touch the socket concurrently. `Add`/`Remove` are queued and flushed the next time `Pump()` runs; a `debugDisconnect`-triggered reconnect resends every still-active `Add` in one `ModifyQuerySet` message and suppresses a rehydrated value that is byte-identical to what the subscription already had, so the observable sequence is initial value, disconnect, external mutation, updated value, never a spurious repeat of the old value. `QueryFailed` is delivered as a structured `FunctionError` without ending the subscription, and a later valid `Transition` recovers it normally. Timestamps are decoded from Convex's base64 little-endian 8-byte counters and compared by magnitude so `maxObservedTimestamp` only advances.

The deterministic Live acceptance test in `client/tests/TestLive.obn`, run against the loopback fixture in `client/tests/FixtureServer.obn`, exercises the initial value, `QueryFailed` and recovery, an external update, and a forced reconnect with resend and rehydration suppression - the same script this project's other compiled clients use, adapted to OBNC's control-flow constraints.

The conformance adapter under `client/tests/conformance/ConvexAdapter.obn` implements NDJSON adapter protocol v1 over both stdin/stdout and TCP (`ADAPTER_LISTEN`), reserves stdout for protocol events, sends diagnostics to stderr, and omits optional fields (`id`, `subscriptionId`, `logs`, `errorData`) rather than serializing them as `null` when absent. `debugDisconnect` is exposed only there, not in the educational client API, exactly as this project requires for proving real reconnects.

OBNC 0.17.2 implements a genuinely smaller language than some Oberon dialects, and this client works within those bounds throughout rather than around them in a few places:

- **No `LOOP`/`EXIT`, and `RETURN` (if present) must be a procedure's last statement.** Standard Modula-2-style early returns from inside a loop or partway through a procedure do not exist in Oberon-07. Every guard clause in this client is instead written as an explicit boolean flag (`ok`, `done`) threaded through a flat sequence of `IF ok THEN ... END` steps, and every scanning loop uses that flag in its own condition (`WHILE ok & ~done DO ... END`) rather than breaking out of it.
- **Nested procedures see only the module's top level declarations, not an enclosing procedure's own locals.** Oberon-07 has no closures over local state. Helpers that would naturally be nested inside their one caller (message builders, request writers) are ordinary module level procedures operating on module level buffers instead, documented at each one.
- **The lexer accepts only double quoted string literals** - neither an escaped quote inside one nor the language report's alternative single quote delimiter compiles. Any text that needs a literal double quote character uses `CHR(34)` directly, and the JSON template fragments built by this client's shared `AppendBuf`/`AppendLit` helpers use a backtick as a stand-in for a quote mark instead, translated as each helper copies its text.
- **Local array variables are not zero-initialised.** This matters concretely: `ConvexBase64.Encode` and `ConvexJSON.AppendQuoted` both append after whatever they find as a destination's existing 0X terminator, so a freshly declared local array passed to either without first being cleared can silently append after garbage bytes rather than at position zero. Every call site in this client clears its destination explicitly immediately beforehand; this was found and fixed via the loopback Live acceptance test during development, not by inspection.
- **A module's file must be named exactly after the module itself.** `examples/basics/main.obn` therefore declares `MODULE main`, matching this project's canonical example filename, rather than a more descriptive module name.

## Limitations

Live authentication, WebSocket mutations, WebSocket actions, optimistic updates, and journals are deferred; every query, mutation, and action goes over the HTTP API, and Live is read-only subscription delivery. `TransitionChunk` assembly is deferred: receiving one, or any other unrecognised server message type, is reported as a `ProtocolError` and reconnects every active subscription.

At most 16 Live subscriptions may be active at once (`client/ConvexSync.obn`'s fixed subscription table), with a 256-byte path and an 8192-byte argument and last-value cap per subscription. `Pump()` delivers from a bounded ring buffer of the newest 32 pending events; a slow or absent consumer causes the oldest queued event to be dropped rather than unbounded growth, but that overflow path is implemented without a dedicated language-local test yet. HTTP bodies are capped at 2 MiB and WebSocket messages at 4 MiB; chunked HTTP transfer-encoding is rejected as a transport error rather than decoded.

Values are exposed as raw JSON text rather than a richer Oberon value tree; the example and tests decode only the specific fields they need. The root-owned local and hosted evaluators have not yet run against this exact commit, so no capability badge is claimed in `manifest.yaml` even though the language-local Docker `test` gate, the loopback HTTP/TLS/WebSocket smoke tests exercised during development, and the two-process Live acceptance test all pass.
