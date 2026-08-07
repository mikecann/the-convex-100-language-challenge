"""The shared counter, from 0 to 1, over HTTP and Live from Mojo."""

from std.os import getenv
from std.sys import argv, exit, stderr

from convex import Client, default_ca_file
from json import parse, quote


fn die(message: String):
    """Report a failure on stderr and stop.

    Stdout is the transcript the shared verifier compares byte for byte, so
    nothing diagnostic is ever allowed to reach it.
    """
    print(message, file=stderr)
    exit(1)


fn count_of(value_json: String) -> Int:
    """Decode the `count` field of a `demo:state` value.

    Convex JSON writes a whole count as either `0` or `0.0`, so this accepts
    any mathematically integral number and rejects a fractional, quoted or
    out-of-range one instead of silently truncating it.
    """
    try:
        var doc = parse(value_json)
        return doc.as_int(doc.member(doc.root, "count"))
    except:
        return -1


fn main() raises:
    # The deployment comes from the environment; the room is the first
    # argument, which is how the verifier gives every run its own counter.
    var url = getenv("CONVEX_URL")
    if not url:
        die(String("CONVEX_URL is required"))
    var arguments = argv()
    var room = String(arguments[1]) if len(arguments) > 1 else String(
        "mojo-basic-example"
    )

    # Create the client. It reads the CA bundle staged in this image, because
    # every hosted Convex deployment is reached over TLS.
    var client = Client(url, default_ca_file())
    var room_args = String('{"room":') + quote(room) + "}"

    # Read the counter over HTTP first, so the starting point is established
    # before anything reactive is involved.
    var initial = client.call(String("query"), String("demo:state"), room_args)
    if not initial.ok or count_of(initial.value_json) != 0:
        die(String("unexpected initial query value: ") + initial.error_message)
    print("current count: 0")

    # Subscribe before the mutation. Starting Live first is what guarantees the
    # update caused by the mutation cannot be missed in the gap between them.
    client.subscribe(String("live"), String("demo:state"), room_args)
    var first = client.wait_update(String("live"), 20000)
    if first.failed or count_of(first.value_json) != 0:
        die(String("unexpected initial Live value: ") + first.error_message)
    print("live initial count: 0")

    # The run ID makes the mutation idempotent: replaying it after a retry
    # returns the same state instead of incrementing the counter twice.
    var mutation_args = String('{"room":')
    mutation_args += quote(room)
    mutation_args += ',"language":"Mojo","runId":'
    mutation_args += quote(room + "-once")
    mutation_args += "}"
    var applied = client.call(
        String("mutation"), String("demo:increment"), mutation_args
    )
    if not applied.ok:
        die(String("mutation failed: ") + applied.error_message)
    var result = parse(applied.value_json)
    if not result.truth(result.member(result.root, "applied")):
        die(String("the mutation reported that it was not applied"))
    var state = result.member(result.root, "state")
    if result.as_int(result.member(state, "count")) != 1:
        die(String("the mutation returned an unexpected count"))
    print("mutation applied: true")
    print("mutation count: 1")

    # The same subscription now carries the reactive consequence of that write.
    var updated = client.wait_update(String("live"), 20000)
    if updated.failed or count_of(updated.value_json) != 1:
        die(String("unexpected updated Live value: ") + updated.error_message)
    print("live updated count: 1")

    # Retire the subscription and the connection before reporting success.
    client.unsubscribe(String("live"))
    client.close(2000)

    # Printed only once HTTP and Live agree on the whole 0 -> 1 journey.
    print("verified count: 0 -> 1")
