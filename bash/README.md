# Convex from Bash

This is a small Bash client for Convex's documented JSON HTTP endpoints and the
pinned Live sync profile. It calls queries, mutations, and actions, then keeps a
query current over a directly implemented RFC6455 connection. It does not use
`curl`, Node, Python, the Convex CLI, or another Convex client.

This is educational and unofficial, not a production SDK.

## Start here

The [basic example](examples/basics/main.sh) queries a counter, starts Live,
increments with an idempotency key, and proves the update arrived reactively.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, pending shared evidence |
| Bearer authentication | Implemented |
| UTF-8 and nested JSON | Implemented via jq |
| Live Add, Remove, reconnect, and query-error recovery | Implemented, pending shared evidence |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sh -->
```text
#!/usr/bin/env bash
set -euo pipefail

# Load both the documented HTTP calls and the direct RFC6455 Live client.
# shellcheck source=/dev/null
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/convex.sh"
# shellcheck source=/dev/null
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/live.sh"
room=${1:-bash-example}
require_convex_url
whole() { convex_whole_number "$(printf '%s\n' "$1" | jq -c .count)"; }

# First obtain the authoritative HTTP snapshot.
before=$(convex_query demo:state "$(jq -cn --arg room "$room" '{room:$room}')")
count=$(whole "$before")
test "$count" = 0 || {
	echo "expected room to start at 0, got $count" >&2
	exit 1
}
printf 'current count: %s\n' "$count"

# Start Live before changing anything, then require its initial snapshot.
live_connect
live_add 0 example demo:state "$(jq -cn --arg room "$room" '{room:$room}')"
initial=$(live_next_value 0)
test "$(whole "$initial")" = "$count"
printf 'live initial count: %s\n' "$count"

# The idempotency key makes this one exact mutation safe to retry.
mutation=$(convex_mutation demo:increment "$(jq -cn --arg room "$room" --arg run "bash-$$-$RANDOM" '{room:$room,language:"Bash",runId:$run}')")
printf '%s\n' "$mutation" | jq -e '.applied == true' >/dev/null
after=$(whole "$(printf '%s\n' "$mutation" | jq -c .state)")
test "$after" = "$((count + 1))"
printf 'mutation applied: true\nmutation count: %s\n' "$after"

# The second Live message must reflect that mutation without a new HTTP query.
updated=$(live_next_value 0)
test "$(whole "$updated")" = "$after"
printf 'live updated count: %s\nverified count: %s -> %s\n' "$after" "$count" "$after"
```
<!-- END GENERATED EXAMPLE -->

Run `./run test bash` for deterministic HTTP, RFC6455, TCP, reconnect, overflow,
and serialization fixtures. `./run verify-example bash` executes the canonical
source against local Convex. Capability badges still require root-owned local
and hosted conformance evidence.

## Notes

`client/convex.sh` uses `wget` only as a low-level HTTPS transport and `jq` only
as a JSON parser. Convex request construction, response interpretation, error
propagation, auth, RFC6455 framing, and Convex sync state are Bash code. OpenSSL
provides TLS and random bytes, while `socat` provides the adapter's single TCP
listener. The bounded per-subscription queue keeps the newest 16 updates.
