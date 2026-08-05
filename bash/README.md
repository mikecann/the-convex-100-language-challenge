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

# Load the educational HTTP client kept beside this canonical example.
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/convex.sh"

# A verifier supplies a unique room. This friendly fallback is for manual runs.
room=${1:-bash-example}
require_convex_url

# Ask Convex for the current counter value over its JSON query endpoint.
before=$(convex_query 'demo:state' "$(jq -cn --arg room "$room" '{room:$room}')")
count=$(jq -er '.count | if floor == . then . | tostring | sub("\\.0$"; "") else error("count is not a whole number") end' <<<"$before")
printf 'current count: %s\n' "$count"

# Apply one idempotent mutation. The run id identifies this exact write.
run_id="bash-$(date +%s)-$$"
mutation=$(convex_mutation 'demo:increment' "$(jq -cn --arg room "$room" --arg run "$run_id" '{room:$room,language:"Bash",runId:$run}')")
jq -e '.applied == true' <<<"$mutation" >/dev/null
after=$(jq -er '.state.count | if floor == . then . | tostring | sub("\\.0$"; "") else error("count is not a whole number") end' <<<"$mutation")
test "$after" = "$((count + 1))"
printf 'mutation applied: true\nmutation count: %s\n' "$after"
printf 'verified HTTP count: %s -> %s\n' "$count" "$after"
```
<!-- END GENERATED EXAMPLE -->

Run `./run test bash` to exercise the client inside Docker. `./run verify bash`
is intentionally not claimed until Live support and root-owned evidence exist.

## Notes

`client/convex.sh` uses `wget` only as a low-level HTTPS transport and `jq` only
as a JSON parser. Convex request construction, response interpretation, error
propagation, and auth are Bash code. The adapter is test infrastructure and
speaks NDJSON on stdin/stdout; TCP adapter mode is deferred with Live.
