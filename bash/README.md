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

### Where TypeScript has types, Bash has `jq`

Bash values are all strings, so this client hands JSON correctness to `jq`,
the tiny JSON language that became the shell world's standard toolkit. `--arg`
builds the argument object with proper escaping no matter what the variable
holds, and `convex_whole_number` refuses any count that is not a whole JSON
number.

```bash
room=bash-readme
args=$(jq -cn --arg room "$room" '{room:$room}') # Correct JSON, whatever $room holds.
# TypeScript: const state = useQuery(api.demo.state, { room })
state=$(convex_query demo:state "$args")
convex_whole_number "$(jq -c '.count' <<<"$state")"
```

Every value crosses the wire as text, and `jq` is the checkpoint on both
sides.

### One unprintable byte smuggles the exit status

Capturing a command's output normally discards the exit status of the process
that produced it. `client/convex.sh` recovers it with a gift from the 1963
ASCII table: byte `0x1E`, the record separator, can never occur inside valid
JSON, so wget's status rides home behind one.

```bash
IFS= read -r -N "$((CONVEX_MAX_RESPONSE_BYTES + 5))" response_envelope < <(
  printf %s "$body" | wget -qO- --post-file=- "${CONVEX_URL%/}/api/query"
  printf '\036%s' "$?" # Append wget's exit code behind a record separator.
)
transport_status=${response_envelope##*$'\036'} # The digits after the last 0x1E.
response=${response_envelope%$'\036'*}          # The JSON before it.
```

The same `read -N` bound enforces the 2 MiB response cap before the payload
ever becomes a Bash variable.

### The WebSocket begins as a redirect to `/dev/tcp`

Bash has no networking library, but it inherited a piece of magic from the
Korn shell: redirecting to the virtual path `/dev/tcp/host/port` makes the
shell itself open a TCP socket. `client/live.sh` reaches Convex's sync
endpoint that way, then performs the WebSocket upgrade with a `printf`.

```bash
exec {LIVE_FD}<>"/dev/tcp/$host/$port" # The shell opens the socket for ws://.
# For wss://, a coprocess wraps the same byte stream in verified TLS instead.
coproc LIVE_TLS (openssl s_client -quiet -connect "$host:$port" -servername "$host")

printf 'GET /api/sync HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n\r\n' \
  "$hostport" >&"$LIVE_FD" # (Key and version headers elided.)
```

From there, `live.sh` masks and parses RFC 6455 frames byte by byte with
`printf`, `dd`, and `od`.

### `trap` is the unmount handler

`trap` has been the shell's cleanup hook since the 1977 Bourne shell: run this
string whenever the script exits, however it exits. Here it plays the part of
React's effect cleanup, releasing the subscription and socket even when a
`set -e` failure aborts the script halfway through.

```bash
trap 'live_remove 0 || true; live_close' EXIT # TypeScript: useQuery unsubscribes on unmount
live_connect
live_add 0 readme-counter demo:state "$args"  # Subscribe as query id 0.
initial=$(live_next_value 0)                  # Block until the first pushed value.
convex_mutation demo:increment "$mutation_args" >/dev/null
updated=$(live_next_value 0)                  # The new count arrives; no polling.
```

Blocking on `live_next_value` keeps a terminal script linear while the server
does the reactive work of deciding when there is something new to deliver.

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
