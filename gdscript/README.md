<img src="logo.png" alt="Godot Engine logo used for GDScript" width="120">
<!-- Logo source: https://godotengine.org/assets/press/icon_color.png (Godot Engine icon; GDScript has no separate official logo.) -->

# GDScript

[GDScript](https://docs.godotengine.org/en/4.4/tutorials/scripting/gdscript/gdscript_basics.html)
is Godot Engine's high-level, object-oriented scripting language. It is
gradually typed, uses indentation-based syntax that will look familiar to a
Python developer, and is entirely independent from Python. Godot created it
after earlier work with languages including Lua and Python showed that a
tightly integrated language made the engine easier to use and maintain.

Its main home is gameplay and application logic inside Godot. The engine's
[official FAQ](https://docs.godotengine.org/en/4.4/about/faq.html) recommends
it to people starting with Godot because it is the engine's native language.
This repository takes it somewhere less usual: a headless Godot 4 process
talking to Convex. This client is educational, unofficial, and not a
production SDK.

## Getting Started

Start with the runnable [basic example](examples/basics/main.gd). It reads a
counter, subscribes before changing it, makes one idempotent mutation, then
waits for Convex to push the new value back over Live.

From the repository root, Docker builds the example image and runs that exact
file against a unique room:

```sh
./run verify-example gdscript
```

## Interesting Parts

### Your whole program is a scene tree

Godot has no free-standing `main()`. Even in a windowless terminal run, the
engine starts its main loop and calls you — so this example *is* a
`SceneTree`, and `_init` runs the whole Convex journey.

```gdscript
class_name ConvexExampleMain
extends SceneTree

func _init() -> void:
	quit(_run())

func _run() -> int:
	# := infers the type; the annotation below re-types the decoded Variant.
	var created := ConvexClient.create(OS.get_environment("CONVEX_URL"))
	var client: ConvexClient = created["value"]
	print(client.query("demo:state", {"room": "gdscript-example"})["value"])
	return 0
```

That pair of declarations is GDScript's gradual typing in one screenful.

### No try, no catch: failure is a Dictionary

GDScript deliberately ships without exceptions — Godot prefers game code that
keeps running over stack unwinding. So this client cannot throw: every call
returns a `Dictionary` carrying either `value` or `error`, and `ConvexResult`
is the small vocabulary for asking which arrived.

```gdscript
var mutated := client.mutation("demo:increment", {
	"room": room,
	"language": "gdscript",
	"runId": run_id, # A fresh ID makes this logical write idempotent.
})
# TypeScript: await increment(args) — failure travels as a rejected promise.
if ConvexResult.is_failure(mutated):
	printerr(ConvexResult.error_message(mutated))
	return 1
var state: Dictionary = mutated["value"]["state"]
```

### Every number off the wire is a float, so an int must be earned

Godot's `JSON` parser reads numbers with `String.to_float`, so Convex's
integral counter arrives as `1.0` — and `"1e999"` becomes infinity rather
than a parse error. Instead of casting and hoping, the client interrogates
the value:

```gdscript
static func count_from_json(value: Variant, context: String) -> Dictionary:
	if typeof(value) != TYPE_FLOAT:
		return ConvexResult.protocol_failure("%s is not a JSON number" % context)
	var number: float = value
	if not is_finite(number):
		return ConvexResult.protocol_failure("%s is not finite" % context)
	if number != floor(number):
		return ConvexResult.protocol_failure("%s is not a whole number" % context)
	if absf(number) > float(MAX_EXACT_INTEGER):
		return ConvexResult.protocol_failure("%s is outside the exact integer range" % context)
	return ConvexResult.ok(int(number))
```

Only a whole, finite number inside JavaScript's exact-integer range becomes
an `int`, so the counter never advances on a value Convex did not send.

### Reactivity you pump one frame at a time

Convex's signature move is the server pushing fresh query results to you.
React hides that machinery inside `useQuery`; in a game engine its natural
home is the frame loop. A subscription here is a handle you drain however
your program breathes:

```gdscript
var subscribed := client.subscribe("demo:state", {"room": room})
var subscription: ConvexSubscription = subscribed["value"]
# TypeScript: const state = useQuery(api.demo.state, { room })

# A one-shot script blocks until Convex pushes the next value:
var update := subscription.next_update(15.0)

# A running game pumps the WebSocket once per frame instead:
func _process(_delta: float) -> void:
	client.poll()
	var latest := subscription.try_next_update()
	if not latest.is_empty():
		print(latest["value"].get("count"))
```

The basic example subscribes *before* mutating, so the update it receives is
provably a push from the server, not a lucky re-read.

## Status

| Surface | Repository state |
| --- | --- |
| JSON HTTP queries, mutations, actions, and bearer auth | Verified by shared conformance on both profiles; HTTP badge earned |
| Live subscriptions, reconnects, and query recovery | Verified by shared conformance on both profiles; Live badge earned |
| Canonical `0 -> 1` HTTP and Live journey | Verified against a local backend and the hosted deployment over real TLS |
| Docker images and the hardened runtime | Built and verified on both profiles |
| Earned capabilities | http, live |

## Example

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

The block above is projected byte-for-byte from the runnable source. If that
source changes, `./run sync-examples` updates both this README and the website.

## Implementation Notes

This is a native GDScript client. Godot's
[`HTTPClient`](https://docs.godotengine.org/en/4.4/classes/class_httpclient.html)
provides HTTP and TLS, while
[`WebSocketPeer`](https://docs.godotengine.org/en/4.4/classes/class_websocketpeer.html)
handles WebSocket framing. The Convex request envelopes, bearer token header,
Live query set, reconnects, deadlines, and structured errors are implemented
in GDScript under [client](client/).

One `ConvexLive` object exclusively owns the socket. A subscription queues at
most 16 updates and charges them against a 16 MiB budget, dropping the oldest
state for a slow consumer. That is a useful fit for reactive state: the newest
value matters more than replaying every intermediate value.

The headless `--script` path used here does not load Godot's normal certificate
trust store, so the Docker build bundles the pinned Debian CA bundle and passes
it explicitly to HTTP and Live connections. The runtime uses Godot
4.4.1-stable, and the Live implementation is pinned to the
`convex-rs-0.10.4-unversioned-sync` profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`.

`./run test gdscript` runs formatting, linting, parsing, and language-local
tests in Docker. `./run build gdscript` builds the minimal adapter runtime.
Those checks are different from the shared deployment verification recorded
in the status table above.

## Known Issues

1. Values are limited to Convex's JSON-safe subset and JavaScript's exact
   integer range because Godot parses JSON numbers as floats.
2. Standard-input adapter mode reads a byte at a time on a helper thread. The
   shared harness uses the better-behaved TCP mode.
3. Godot hides partial WebSocket frames from GDScript. The client bounds the
   time between complete messages, which also means a completely idle server
   triggers a reconnect.
4. Live authentication, `TransitionChunk` assembly, optimistic updates, and
   WebSocket mutation replay are not implemented.
