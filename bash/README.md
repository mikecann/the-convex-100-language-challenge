# Bash

[Bash](https://www.gnu.org/software/bash/) is the GNU command-line shell and a
programming language for joining commands into scripts. It was created for the
GNU project as a compatible successor to the Bourne shell (`sh`), and it also
borrows features from the Korn shell and C shell. Today its natural home is
interactive Unix-like terminals, system scripts, build jobs, and small pieces
of automation where processes, files, and text are the main building blocks.

This client is an educational, unofficial demonstration. It is not a
production SDK or an officially supported Convex client.

## Getting Started

The [canonical example](examples/basics/main.sh) reads a counter, subscribes to
it, performs an idempotent increment, and waits for the reactive update.

```console
./run verify-example bash
```

Run that command from the repository root. It builds the minimal Docker image
and runs the exact example shown below against the repository's approved local
Convex test deployment.

## Interesting Parts

### JSON values cross a text boundary

In a React app, generated Convex types keep the argument and result as typed
JavaScript objects.

**TypeScript with React**

```tsx
import { useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function CounterSnapshot() {
  const room = "bash-readme";
  const state = useQuery(api.demo.state, { room });

  if (state === undefined) return <p>Loading...</p>;
  return <p>{state.count}</p>; // state and count are type-safe here.
}
```

Bash has strings rather than typed object values, so this client uses `jq` at
both sides of the call. `--arg` safely constructs the named argument object,
and `convex_whole_number` rejects a fractional or non-number count.

**Bash**

```bash
# Load the repository's HTTP client and require its CONVEX_URL configuration.
source bash/client/convex.sh
require_convex_url

room=bash-readme
args=$(jq -cn --arg room "$room" '{room:$room}') # Build { room } as JSON.
state=$(convex_query demo:state "$args")          # Make one HTTP query.
count=$(convex_whole_number "$(jq -c '.count' <<<"$state")")
printf '%s\n' "$count"
```

The Bash call is a one-off snapshot. Unlike `useQuery`, it does not stay
subscribed or rerun code when the value changes.

### Reactivity is an explicit sequence

React owns the subscription behind `useQuery`, rerenders when the value
changes, and releases the subscription when the component unmounts.

**TypeScript with React**

```tsx
import { useMutation, useQuery } from "convex/react";
import { api } from "./convex/_generated/api";

export function CounterButton() {
  const room = "bash-reactive-readme";
  const state = useQuery(api.demo.state, { room });
  const increment = useMutation(api.demo.increment);

  async function addOne() {
    const result = await increment({
      room,
      language: "TypeScript",
      runId: crypto.randomUUID(),
    });
    console.log(result.state.count); // The mutation also returns the new state.
  }

  return <button onClick={addOne}>Count: {state?.count ?? "..."}</button>;
}
```

The command-line client owns those steps directly. It starts Live before the
mutation so it cannot miss the change, then blocks for each selected value.

**Bash**

```bash
# Load the HTTP and Live clients, and always release the subscription and socket.
source bash/client/convex.sh
source bash/client/live.sh
require_convex_url
trap 'live_remove 0 || true; live_close' EXIT

room=bash-reactive-readme
query_args=$(jq -cn --arg room "$room" '{room:$room}')
live_connect
live_add 0 readme-counter demo:state "$query_args" # Subscribe as query 0.

initial=$(live_next_value 0) # Wait for the initial reactive value.
printf 'initial: %s\n' "$(convex_whole_number "$(jq -c '.count' <<<"$initial")")"

run_id="bash-readme-$$-$RANDOM" # Give this increment its own idempotency key.
mutation_args=$(jq -cn --arg room "$room" --arg run_id "$run_id" \
  '{room:$room,language:"Bash",runId:$run_id}')
result=$(convex_mutation demo:increment "$mutation_args")
printf 'mutation: %s\n' "$(convex_whole_number "$(jq -c '.state.count' <<<"$result")")"

updated=$(live_next_value 0) # Wait for Live to deliver the changed state.
printf 'updated: %s\n' "$(convex_whole_number "$(jq -c '.count' <<<"$updated")")"
```

The blocking `live_next_value` operation is a choice made by this small client,
not a Bash language restriction. It keeps a terminal example linear while a
separate worker owns socket reads, reconnects, and query-set changes.

## Status

Clean parent commit `305e9a4` passed `./run verify-all bash`: 31 of 31 checks
passed against both the local and hosted profiles from the same built image.
This prose-only reconciliation does not change the verified build inputs.

| Capability | Status |
| --- | --- |
| JSON HTTP queries, mutations, and actions | Verified by recorded shared local and hosted conformance |
| Bearer authentication | Implemented |
| UTF-8 and nested JSON | Implemented with `jq` |
| Live subscriptions, removal, reconnect, and query-error recovery | Verified by recorded shared local and hosted conformance |

## Example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.sh -->
```bash
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

## Implementation Notes

This is a native Bash implementation of the documented Convex JSON HTTP API
and the repository's pinned Live sync profile. `client/convex.sh` builds the
request envelope, applies bearer authentication, limits responses to 2 MiB,
and turns Convex failures into nonzero shell results. It delegates ordinary
HTTP transport to `wget` and JSON correctness to `jq`, but it does not call
another Convex SDK, `curl`, Node.js, Python, or the Convex CLI.

`client/live.sh` performs the WebSocket upgrade and RFC 6455 framing in Bash.
OpenSSL supplies verified TLS and random masking bytes. One worker owns the
socket, query-set versions, and reconnect loop, leaving the adapter parent free
to accept unsubscribe and close commands. Text messages may be fragmented, but
binary messages are rejected because Bash variables cannot safely hold NUL
bytes. Frames and assembled messages are each capped at 2 MiB.

Socket deadlines have a subtle rule. If the child reader produced every byte,
the parser keeps that complete result even when process reaping races with the
deadline. If a timeout occurs after only part of a frame has been consumed, the
client retires the connection and reconnects. It never treats the remaining
payload as a new frame header. Reconnects resend active subscriptions, suppress
an unchanged rehydration value, and reset their exponential backoff after a
successful handshake.

The final Alpine 3.22 images run GNU Bash 5.2.37 as user `65532:65532`. Their
BusyBox is compiled with only the applets this client needs, then installed
without a `busybox` command that could expose undeclared applets through a
forged command name. A tiny static `timeout` helper supplies only the
sub-second deadline operation needed by the Live reader. `jq`, OpenSSL, and
`socat` remain deliberate runtime dependencies, with `socat` used only by the
test adapter's TCP listener.

## Known Issues

1. Live targets the unversioned sync profile pinned in `manifest.yaml`. It is
   project evidence, not a promise that an internal protocol will stay stable.
2. WebSocket mutations and actions, Live authentication, optimistic updates,
   and `TransitionChunk` assembly are deferred. Queries, mutations, actions,
   and bearer authentication are available through the JSON HTTP path.
3. Each adapter subscription keeps only its newest 16 pending updates. A slow
   consumer can miss intermediate states, although it still converges on a
   recent value.
4. The recorded platform is `linux/amd64`, and the runtime still depends on
   Bash, `jq`, OpenSSL, restricted `wget`, and the adapter-only `socat` listener.
