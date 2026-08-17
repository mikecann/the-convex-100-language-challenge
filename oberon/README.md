# Oberon-07

[Oberon](https://people.inf.ethz.ch/wirth/Oberon/) is a compact, general-purpose language created by Niklaus Wirth at ETH Zurich as part of the Oberon operating-system project. It evolved from Modula-2, keeps the Pascal family’s structured style, and adds type extension while deliberately trimming the language down. The original language and system were developed in 1986 to 1990; this repository uses the [2007 revision, last revised in 2016](https://people.inf.ethz.ch/wirth/Oberon/Oberon07.Report.pdf). Today Oberon is a niche language, seen mainly in teaching, compiler work, and small systems projects such as [Project Oberon](https://people.inf.ethz.ch/wirth/ProjectOberon/index.html), rather than mainstream application development.

This is an educational, unofficial Convex client. It is not a production SDK and is not intended for package publication.

## Getting Started

Start with [`examples/basics/main.obn`](examples/basics/main.obn). It queries a fresh counter, opens a Live subscription, applies one idempotent mutation, and confirms the same `0 -> 1` result through both HTTP and Live.

From the repository root, Docker builds the Oberon program and runs that exact example against the approved test deployment:

```sh
./run verify-example oberon
```

## Interesting Parts

### A JSON value is text you search, not a tree you walk

Convex answers arrive as JSON, but this client never builds an object model for them. Every value stays a fixed, zero-terminated `ARRAY OF CHAR`, and `ConvexJSON.Member` scans that buffer by hand to pull out one field at a time, leaving everything else as untouched text.

```oberon
VAR raw: ARRAY 64 OF CHAR; found, ok: BOOLEAN;
(* ... *)
(* TypeScript: const count = state.count *)
ok := J.Member(value, "count", raw, found) & found;
IF ok THEN ok := J.IsIntegralNumber(raw) END;
(* raw is still JSON text -- ordinary digits, parsed by hand from here *)
```

There is no parse step to fail up front: a caller only pays for decoding the fields it actually names.

### A Live update only shows up when you Pump for it

Oberon does have procedure values, so this client could have taken a callback. It doesn't. `Subscribe` hands back a `handle`, and the caller keeps calling `Pump` — a single blocking procedure that owns the WebSocket, reconnects, and the queue of pending updates — until an event carrying that handle appears.

```oberon
S.Subscribe("demo:state", args, handle, ok, errorText);
IF ~ok THEN Fail(errorText) END;

REPEAT
	(* One caller, one socket: Pump is the only place a Live event arrives. *)
	S.Pump(200, eventKind, eventHandle, value, logs, errorName,
		errorMessage, errorData, hasErrorData)
UNTIL (eventKind # 0) & (eventHandle = handle);
(* TypeScript: const state = useQuery(api.demo.state, { room }) *)
```

`useQuery` hides exactly this loop inside a hook; here it is a visible `REPEAT` the caller owns outright.

### No `LOOP`, no `EXIT`: a boolean carries you out

Oberon-07 trims even earlier Oberon dialects, dropping `LOOP`/`EXIT` entirely, and a procedure's `RETURN` must be its final statement. With no early break available, a "wait until" loop threads its own exit condition through a plain flag instead.

```oberon
waited := 0;
done := FALSE;
WHILE ~done DO
	S.Pump(200, eventKind, eventHandle, eventValue, eventLogs,
		eventErrorName, eventErrorMessage, eventErrorData, eventHasErrorData);
	IF (eventKind # 0) & (eventHandle = targetHandle) THEN
		decoded := DecodeCount(eventValue, result);
		done := TRUE
	ELSE
		INC(waited);
		IF waited > 150 THEN Fail("timed out waiting for a Live update") END
	END
END
```

The flag reads almost like documentation: this loop ends when, and only when, `done` says so.

## Status

| Capability | Evidence-backed status |
| --- | --- |
| HTTP queries, mutations, actions, bearer auth, log lines, and structured errors | Earned. The recorded local and hosted shared-conformance runs pass. |
| Live initial values, external updates, error recovery, and reconnects | Earned. Language-local fixture tests and the recorded local and hosted shared-conformance runs pass. |
| WebSocket mutations and actions, Live authentication, optimistic updates, and journals | Not implemented. |
| Production SDK compatibility | Not claimed. This remains an educational client. |

## Example

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

## Implementation Notes

The implementation is native by this repository's rules. [`ConvexSync.obn`](client/ConvexSync.obn) implements Convex calls, subscription state, reconnects, and event delivery in Oberon-07. The HTTP, JSON, base64, URL, and WebSocket layers are also Oberon modules. [`ConvexShim.c`](client/ConvexShim.c) is the one foreign module, limited to generic POSIX sockets, OpenSSL, polling, clocks, random bytes, and SHA-1. It does not delegate any Convex behavior to another SDK.

The pinned [OBNC 0.17.2 compiler](https://miasap.se/obnc/) translates the Oberon modules to C inside Docker. The final images contain the compiled programs and their runtime libraries, not OBNC, a C compiler, a package manager, Node.js, Python, or the Convex CLI.

`ConvexSync` is a process-wide singleton. The caller of `Pump()` alone touches the WebSocket, reconnect state, and subscription changes. Pending Live events sit in a fixed ring of 32 entries, and each subscription has bounded storage for its path, arguments, and last value. This makes memory use predictable, but it also means a caller must keep pumping and must accept explicit limits.

The compact language changes how ordinary plumbing reads. Oberon-07 has no `LOOP`/`EXIT`, and a function's `RETURN` must be its final statement, so the client threads `ok` and `done` flags through multi-step work. OBNC also does not zero-initialise local arrays, so append destinations are cleared explicitly. Its accepted string syntax cannot escape a quote inside a quoted literal, which is why the client's JSON builders translate backticks to `CHR(34)`.

The language-local tests cover JSON decoding, an initial Live value, an external update, `QueryFailed` recovery, and a forced reconnect that resends subscriptions without repeating an unchanged value. The test-only adapter supports the repository's stdin/stdout and TCP controller modes, but it is not part of the educational API.

## Known Issues

1. Live is read-only. Authentication, mutations, actions, optimistic updates, and journals over the WebSocket are deferred; function calls use HTTP.
2. `TransitionChunk` is not assembled. An unknown server message becomes a `ProtocolError` and causes active subscriptions to reconnect.
3. Values remain raw JSON text. Callers use `ConvexJSON` to extract and validate the fields they need rather than receiving an idiomatic value tree.
4. The client allows at most 16 active Live subscriptions. Paths are capped at 256 bytes, arguments and remembered values at 8192 bytes, HTTP bodies at 2 MiB, and WebSocket messages at 4 MiB.
5. If more than 32 Live events wait for `Pump()`, the oldest event is dropped. That overflow behavior exists but has no dedicated saturation test, and the adapter has not been pressure-tested with a stopped reader at the shared 128 MiB process limit.
6. Chunked HTTP transfer encoding is rejected instead of decoded.
