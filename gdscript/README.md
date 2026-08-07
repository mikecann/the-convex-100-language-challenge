# Convex from GDScript

This folder demonstrates a small native Convex client written in GDScript and
running on headless Godot 4. It calls Convex queries, mutations, and actions
over the documented JSON HTTP API, and subscribes to a reactive query over a
Live WebSocket, using only Godot's own networking.

This is educational, unofficial, and not a production SDK. It is an honest
work in progress: no capability badge is earned until the coordinator runs the
shared local and hosted conformance suites, and none has been run yet.

## Start here

The [basic example](examples/basics/main.gd) tells the whole story in one
file. It reads a counter room over HTTP, subscribes to that room before
changing anything, applies one idempotent increment, waits for the same change
to arrive over the subscription, and prints its verification line only after
HTTP and Live agree on the journey from `0` to `1`.

The client itself is in [client](client/): `convex.gd` holds the HTTP
envelopes and the public API, `http.gd` the bounded transport, `live.gd` the
single owner of the WebSocket, and `subscription.gd` one reactive query.

## What works

| Surface | Repository state |
| --- | --- |
| JSON HTTP queries, mutations, actions, and bearer auth | Native candidate with local fixtures; capability unearned |
| Live subscriptions, reconnects, and query recovery | Native candidate with deterministic fixtures; capability unearned |
| Canonical `0 -> 1` HTTP and Live journey | The exact runnable source is present; no run has been executed |
| Docker images and the hardened runtime | Designed and pinned in the Dockerfile; never built |
| Earned capabilities | None |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.gd -->
```gdscript
class_name ConvexExampleMain
extends SceneTree

# Convex from GDScript, end to end: read a counter room over HTTP, watch the
# same room over a Live WebSocket subscription, apply one idempotent
# increment, and only claim success once both transports agree.
#
# Godot runs a headless program through a main loop, so the example is a
# SceneTree whose _init does the work and sets the process exit status.


func _init() -> void:
	quit(_run())


func _run() -> int:
	# The deployment URL is configuration, never a compiled-in constant.
	var deployment_url := OS.get_environment("CONVEX_URL")
	if deployment_url.is_empty():
		return _fail("CONVEX_URL is required")

	# The verifier passes a unique room as the first user argument, so parallel
	# runs of this example can never increment each other's counter.
	var room := "gdscript-example"
	var arguments := OS.get_cmdline_user_args()
	if arguments.size() > 0:
		room = arguments[0]

	# Creating the client validates the deployment URL once, up front.
	var created := ConvexClient.create(deployment_url)
	if ConvexResult.is_failure(created):
		return _report(created, "client creation")
	var client: ConvexClient = created["value"]

	# Read the room's current state through Convex's documented HTTP query API.
	var current := client.query("demo:state", {"room": room})
	if ConvexResult.is_failure(current):
		return _report(current, "initial query")
	var initial := _count_of(current["value"], "initial query")
	if ConvexResult.is_failure(initial):
		return _report(initial, "initial query")
	var initial_count: int = initial["value"]
	print("current count: %d" % initial_count)

	# Subscribe before mutating. Starting Live first is what makes the update
	# below provably reactive: no change can slip in between the read and the
	# subscription.
	var subscribed := client.subscribe("demo:state", {"room": room})
	if ConvexResult.is_failure(subscribed):
		return _report(subscribed, "subscribe")
	var subscription: ConvexSubscription = subscribed["value"]

	# Convex hydrates a new subscription with the query's current value. It has
	# to agree with the HTTP read before this example writes anything.
	var live_initial := _verify_live_value(
		subscription,
		initial_count,
		"initial Live value",
		"initial Live value disagreed with the HTTP query",
		"live initial count: %d"
	)
	if live_initial.has("exit_code"):
		return live_initial["exit_code"]

	var mutation := _apply_increment(client, room, initial_count)
	if mutation.has("exit_code"):
		return mutation["exit_code"]
	var mutated_count: int = mutation["value"]

	# The same change now arrives over the subscription, pushed by Convex
	# rather than polled for over HTTP.
	var live_update := _verify_live_value(
		subscription,
		mutated_count,
		"Live update",
		"Live update disagreed with the mutation",
		"live updated count: %d"
	)
	if live_update.has("exit_code"):
		return live_update["exit_code"]

	# Only claim the journey once HTTP and Live have agreed on every step.
	print("verified count: %d -> %d" % [initial_count, live_update["value"]])

	# Stop this query before closing the client, so the Live owner retires its
	# socket with an empty query set and never schedules a reconnect.
	var stopped := subscription.close()
	if ConvexResult.is_failure(stopped):
		return _report(stopped, "unsubscribe")
	var closed := client.close()
	if ConvexResult.is_failure(closed):
		return _report(closed, "close")
	return 0


# Awaits one Live delivery and checks it against the count the caller already
# knows to be current, so `_run` shares this between the initial rehydration
# and the update that follows the mutation instead of repeating it - the two
# call sites differ only in the strings passed in here. On success, "value"
# is the delivered count and the matching print line has already happened;
# on failure, "exit_code" is the process exit status `_run` returns as-is,
# since the failure has already been reported through `_fail` or `_report`.
func _verify_live_value(
	subscription: ConvexSubscription,
	expected: int,
	context: String,
	mismatch_message: String,
	print_format: String
) -> Dictionary:
	var update := subscription.next_update(15.0)
	if ConvexResult.is_failure(update):
		return {"exit_code": _report(update, context)}
	var counted := _count_of(update["value"], context)
	if ConvexResult.is_failure(counted):
		return {"exit_code": _report(counted, context)}
	if counted["value"] != expected:
		return {"exit_code": _fail(mismatch_message)}
	print(print_format % counted["value"])
	return {"value": counted["value"]}


# Applies the idempotent increment and checks that it actually landed. Same
# "exit_code" or "value" convention as `_verify_live_value` above.
func _apply_increment(client: ConvexClient, room: String, initial_count: int) -> Dictionary:
	# runId is the mutation's idempotency key. Convex records it, so a repeated
	# runId returns the current state with applied false instead of counting
	# the same logical increment twice.
	var run_id := "gdscript:%s:%d:%d" % [room, Time.get_ticks_usec(), randi()]
	var increment := {"room": room, "language": "gdscript", "runId": run_id}
	var applied := client.mutation("demo:increment", increment)
	if ConvexResult.is_failure(applied):
		return {"exit_code": _report(applied, "mutation")}
	var mutation_value: Variant = applied["value"]
	if typeof(mutation_value) != TYPE_DICTIONARY or mutation_value.get("applied") != true:
		return {"exit_code": _fail("mutation was not applied")}
	var mutated := _count_of(mutation_value.get("state"), "mutation")
	if ConvexResult.is_failure(mutated):
		return {"exit_code": _report(mutated, "mutation")}
	var mutated_count: int = mutated["value"]
	if mutated_count != initial_count + 1:
		return {"exit_code": _fail("mutation count did not advance by exactly one")}
	print("mutation applied: true")
	print("mutation count: %d" % mutated_count)
	return {"value": mutated_count}


# Both the room state and the mutation's new state carry the counter in a
# "count" field. Godot's JSON parser makes every number a float, so Convex's
# integral 0.0 or 1.0 has to be checked and converted rather than cast: this
# example must fail loudly on a fractional or out-of-range value instead of
# printing a rounded number as if Convex had sent it.
func _count_of(value: Variant, context: String) -> Dictionary:
	if typeof(value) != TYPE_DICTIONARY:
		return ConvexResult.protocol_failure("%s did not return an object" % context)
	return ConvexValues.count_from_json(value.get("count"), "%s count" % context)


# Diagnostics go to standard error. Standard output carries only the six lines
# above, because the shared verifier compares it byte for byte.
func _fail(message: String) -> int:
	printerr("convex example failed: %s" % message)
	return 1


func _report(result: Dictionary, step: String) -> int:
	var failure_name := ConvexResult.error_name(result)
	var failure_message := ConvexResult.error_message(result)
	return _fail("%s: %s: %s" % [step, failure_name, failure_message])
```
<!-- END GENERATED EXAMPLE -->

The block above is projected from the runnable source. Run `./run
sync-examples` after changing it so the README and the website show the same
code. The shared projector has no GDScript entry in its fence map yet, so the
block is fenced as plain text; adding one is a shared-infrastructure change.

## Docker checks

`./run test gdscript` formats, lints, parses, and executes every language-local
test inside Docker, then exports the two release packs. `./run build gdscript`
produces the minimal adapter runtime image, and the shared example verifier
builds the separate `example-runtime` image. Only the coordinator runs
`./run verify-example gdscript`, `./run verify gdscript`, and
`./run verify-hosted gdscript` against the approved deployments.

Both runtime images pair Godot's Linux release export template, which contains
no editor and no exporter, with one exported pack. The build proves inside each
final image that the pack boots, that the example fails closed without
configuration while writing nothing at all to standard output, and that the
adapter answers `hello` and `close` with exactly two NDJSON lines.

## Conformance and protocol notes

The conformance executable under
[client/tests/conformance](client/tests/conformance/) speaks NDJSON adapter
protocol v1 over standard input and output, or over the TCP address in
`ADAPTER_LISTEN`, which is what the isolated harness uses. Failures are
serialized as `FunctionError`, `ProtocolError`, `TransportError`, or
`ClosedError`, and absent optional fields are omitted rather than sent as null.

One owner object holds the only `WebSocketPeer`. Subscriptions, the example,
and the adapter send it commands; nothing else reads, writes, closes, or
reconnects a socket, and the owner refuses any command that arrives from a
different thread. Each subscription keeps at most 16 updates and a
conservatively charged 16 MiB memory budget, and
drops and counts the oldest beyond that. The adapter's output queue holds at
most 64 events and 8 MiB, including the line currently being written, so a
TCP controller that stops reading produces a structured, bounded transport
failure rather than unbounded growth. With one 2 MiB inbound Live frame, one
2 MiB HTTP response, and one subscription queue added, retained application
buffers remain well below the shared 128 MiB limit.

Godot supplies the parts a native client should not reimplement: HTTPClient
does HTTP/1.1 and TLS, and WebSocketPeer does the HTTP 101 handshake, frame
masking, continuation-frame reassembly, UTF-8 validation, and ping and close
control frames. Convex-specific behaviour is all GDScript: the request and
response envelopes, `format: "json"`, bearer transport, the query set and its
versions, atomic transition application, unchanged-rehydration suppression,
timestamp tracking, backoff, and every deadline.

The image pins Godot 4.4.1-stable by the published SHA-512 of its Linux
editor archive and export templates, Debian bookworm-slim and BusyBox
1.37.0-musl by digest, and gdtoolkit 4.3.4 for `gdformat` and `gdlint`. The
runtime shell is built from checksum-pinned BusyBox source with only the
required applets compiled in. The Live wire profile is pinned to
`convex-rs-0.10.4-unversioned-sync` at source commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

## Limitations

No Docker build, example run, or conformance run has been executed against
this source, so every capability is unearned and the Dockerfile is a design
rather than evidence.

Values cover Convex's JSON-safe subset. Godot's JSON parser decodes every
number as a float and is lax about numeric literals, so integers are validated
and converted rather than cast. Values outside JavaScript's safe integer range
are refused instead of rounded, including a literal that Godot already rounded
while parsing.

Standard input is the transport with a genuine Godot limitation behind it.
`OS.read_buffer_from_stdin` blocks until the requested number of bytes has
arrived or the pipe closes, there is no readiness query, no non-blocking mode,
and no way to cancel a read in progress. The adapter therefore reads standard
input one byte at a time on a helper thread, which is correct but slow for
large values, and a controller that keeps the pipe open after `close` leaves
that thread parked, which the adapter reports on standard error before it
exits. The TCP transport has none of these problems and is what the shared
harness uses.

Standard output purity is a property of the runtime image rather than of a
flag. Godot's `--quiet` cannot be used here: it disables the engine's standard
output entirely, including the client's own `print`, so it would silence the
example's six lines along with any engine chatter. The images use the release
export template instead, which prints no engine banner, and both runtime
stages prove that at build time by asserting the example writes nothing at all
to standard output on its failure path and the adapter writes exactly two
NDJSON lines for a hello and a close.

Godot's standard-output API does not expose partial writes or a non-blocking
mode. The bounded stopped-reader guarantee therefore applies to the TCP
adapter transport used by the shared harness. Stdio remains suitable for an
ordinary reading controller, but it cannot provide the same memory proof.

A partially read WebSocket frame is not something this client can resume, and
not because of an oversight: Godot's WebSocketPeer owns frame parsing and
never exposes a half-read frame to GDScript. The owner places one absolute
deadline between complete messages and abandons the whole connection when it
expires. That bounds a continuously dribbled partial frame, but it also means
GDScript cannot distinguish that attack from a completely idle server. The
retry opens a new peer, so no read can resume at a false frame boundary.

Live authentication, `TransitionChunk` assembly, optimistic updates, and
WebSocket mutation replay are deliberately deferred. This demonstration is tied
to a pinned, undocumented Live profile and treats protocol drift as an error.
