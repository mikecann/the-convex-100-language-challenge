#!/usr/bin/env bash
set -euo pipefail

# Load both the documented HTTP calls and the direct RFC6455 Live client.
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/convex.sh"
source "$(cd -- "$(dirname -- "$0")/../../client" && pwd)/live.sh"
room=${1:-bash-example}
require_convex_url
whole() { convex_whole_number "$(jq -c .count <<<"$1")"; }

# First obtain the authoritative HTTP snapshot.
before=$(convex_query demo:state "$(jq -cn --arg room "$room" '{room:$room}')")
count=$(whole "$before")
test "$count" = 0 || { echo "expected room to start at 0, got $count" >&2; exit 1; }
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
