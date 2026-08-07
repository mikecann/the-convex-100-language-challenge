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
