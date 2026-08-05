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
