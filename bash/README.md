# Convex from Bash

This is a small Bash client for Convex's documented JSON HTTP endpoints. It can
call queries, mutations, and actions without `curl`, Node, Python, the Convex
CLI, or another Convex client.

This is educational and unofficial, not a production SDK.

## Start here

The [basic example](examples/basics/main.sh) queries a counter then increments
it with an idempotency key. It deliberately stops there: HTTP polling is not a
substitute for a Convex Live subscription.

## What works

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Implemented, pending shared evidence |
| Bearer authentication | Implemented |
| UTF-8 and nested JSON | Implemented via jq |
| Live subscriptions | Deferred |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sh -->
```text
#!/usr/bin/env bash
set -euo pipefail

# Load both the documented HTTP calls and the direct RFC6455 Live client.
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/convex.sh"
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/live.sh"
room=${1:-bash-example}
require_convex_url
whole() { jq -er '.count | if floor == . then tostring | sub("\\.0$"; "") else error("count must be whole") end' <<<"$1"; }

# First obtain the authoritative HTTP snapshot.
before=$(convex_query demo:state "$(jq -cn --arg room "$room" '{room:$room}')")
count=$(whole "$before")
printf 'current count: %s\n' "$count"

# Start Live before changing anything, then require its initial snapshot.
live_connect
live_add 0 example demo:state "$(jq -cn --arg room "$room" '{room:$room}')"
initial=$(live_next_value 0); test "$(whole "$initial")" = "$count"
printf 'live initial count: %s\n' "$count"

# The idempotency key makes this one exact mutation safe to retry.
mutation=$(convex_mutation demo:increment "$(jq -cn --arg room "$room" --arg run "bash-$$-$RANDOM" '{room:$room,language:"Bash",runId:$run}')")
jq -e '.applied == true' <<<"$mutation" >/dev/null
after=$(whole "$(jq -c .state <<<"$mutation")"); test "$after" = "$((count + 1))"
printf 'mutation applied: true\nmutation count: %s\n' "$after"

# The second Live message must reflect that mutation without a new HTTP query.
updated=$(live_next_value 0); test "$(whole "$updated")" = "$after"
printf 'live updated count: %s\nverified count: %s -> %s\n' "$after" "$count" "$after"
```
<!-- END GENERATED EXAMPLE -->

Run `./run test bash` to exercise the client inside Docker. `./run verify bash`
is intentionally not claimed until Live support and root-owned evidence exist.

## Notes

`client/convex.sh` uses `wget` only as a low-level HTTPS transport and `jq` only
as a JSON parser. Convex request construction, response interpretation, error
propagation, and auth are Bash code. The adapter is test infrastructure and
speaks NDJSON on stdin/stdout; TCP adapter mode is deferred with Live.
