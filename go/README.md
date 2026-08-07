# Convex from Go

This folder shows a small Go program talking directly to Convex. It can call
queries, mutations, and actions over HTTP, then keep a query updated in real
time over a WebSocket.

This is an educational demonstration for the 100-language project. It is not
an official Convex SDK or a package intended for production use.

## Start here

The [basic example](examples/basics/main.go) is the best place to begin. It:

1. Connects to a Convex deployment.
2. Queries the current state of a counter room.
3. Starts a Live subscription to that same query.
4. Runs a mutation which changes the counter.
5. Receives the new value through Live without polling again.

The implementation behind it lives in [client](client/). Everything is built
and tested inside Docker, so no Go toolchain is installed on the host.

## What works

| Capability | Status |
| --- | --- |
| Queries, mutations, and actions over HTTP | Verified by shared local and hosted conformance |
| Bearer-token authentication for HTTP calls | Implemented and covered by Go-local tests |
| Initial and updated Live query values | Verified by shared local and hosted conformance |
| Unsubscribe, reconnect, timeouts, and clean shutdown | Implemented and covered by Go-local tests |
| Canonical basic example executed in Docker | Verified against self-hosted and hosted deployments |
| Authentication for Live subscriptions | Not yet |
| Full tagged Convex value types | Not yet |

## Basic example

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.go -->
```go
package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"time"

	convex "github.com/mikecann/100-convex-clients/go/client"
)

// roomState is the part of the Convex query result used by this example.
type roomState struct {
	Count integralCount
}

// integralCount accepts Convex's integral decimal forms, such as 1.0, without
// letting float rounding turn a fractional or overflowing value into an integer.
type integralCount int64

func (state *roomState) UnmarshalJSON(raw []byte) error {
	var encoded struct {
		Count json.RawMessage `json:"count"`
	}
	if err := json.Unmarshal(raw, &encoded); err != nil {
		return err
	}
	if encoded.Count == nil {
		return fmt.Errorf("count is required")
	}
	return json.Unmarshal(encoded.Count, &state.Count)
}

func (count *integralCount) UnmarshalJSON(raw []byte) error {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] == '"' {
		return fmt.Errorf("count must be a JSON number")
	}
	var number json.Number
	if err := json.Unmarshal(trimmed, &number); err != nil {
		return fmt.Errorf("count must be a finite JSON number: %w", err)
	}
	rational, ok := new(big.Rat).SetString(number.String())
	if !ok || !rational.IsInt() {
		return fmt.Errorf("count must be mathematically integral")
	}
	integer := rational.Num()
	if !integer.IsInt64() {
		return fmt.Errorf("count is outside the int64 range")
	}
	*count = integralCount(integer.Int64())
	return nil
}

// incrementResult mirrors the mutation response so the example can verify that
// the write was applied and produced the expected next state.
type incrementResult struct {
	Applied bool      `json:"applied"`
	State   roomState `json:"state"`
}

func main() {
	ctx := context.Background()
	deploymentURL := os.Getenv("CONVEX_URL")
	if deploymentURL == "" {
		fmt.Fprintln(os.Stderr, "CONVEX_URL is required")
		os.Exit(2)
	}

	// Create a Convex client connected to the deployment from the environment.
	client, err := convex.New(deploymentURL)
	if err != nil {
		panic(err)
	}

	// Close the client's network connections when the example exits.
	defer client.Close(ctx)

	room := "go-example"
	if len(os.Args) > 1 {
		room = os.Args[1]
	}

	// Run a Convex query over HTTP to get the room's current state.
	result, err := client.Query(ctx, "demo:state", map[string]any{"room": room})
	if err != nil {
		panic(err)
	}

	var state roomState
	// Decode the JSON result into a typed Go value the application can use.
	decodeJSON("current query", result.Value, &state)
	fmt.Printf("current count: %d\n", state.Count)

	// Begin listening for changes to the same query over Convex Live.
	subscription, err := client.Subscribe(ctx, "demo:state", map[string]any{"room": room})
	if err != nil {
		panic(err)
	}

	// Stop listening when the example exits.
	defer subscription.Close()

	// A subscription first sends the current value. Read that snapshot before
	// making a change so the following update is unambiguous.
	initialValue := nextUpdate(subscription)
	var initialState roomState
	decodeJSON("initial Live value", initialValue, &initialState)
	expectCount("initial Live value", initialState.Count, state.Count)
	fmt.Printf("live initial count: %d\n", initialState.Count)

	// Run a mutation over HTTP. The subscription above will observe this write.
	mutation, err := client.Mutation(ctx, "demo:increment", map[string]any{
		"room":     room,
		"language": "go",
		"runId":    randomID(),
	})
	if err != nil {
		panic(err)
	}
	var increment incrementResult
	decodeJSON("mutation", mutation.Value, &increment)
	if !increment.Applied {
		panic("mutation was not applied")
	}
	fmt.Printf("mutation applied: %t\n", increment.Applied)
	if state.Count == integralCount(1<<63-1) {
		panic("current count cannot be incremented within the int64 range")
	}
	expectedCount := state.Count + 1
	expectCount("mutation", increment.State.Count, expectedCount)
	fmt.Printf("mutation count: %d\n", increment.State.Count)

	// Receive the changed room through Live without issuing another HTTP query.
	updatedValue := nextUpdate(subscription)
	var updatedState roomState
	decodeJSON("updated Live value", updatedValue, &updatedState)
	expectCount("updated Live value", updatedState.Count, expectedCount)
	fmt.Printf("live updated count: %d\n", updatedState.Count)

	// Reaching this line proves the query, mutation, and Live subscription all
	// agreed on the same change.
	fmt.Printf("verified count: %d -> %d\n", state.Count, updatedState.Count)
}

// nextUpdate waits for one value from a Live subscription. It turns a closed
// stream, query error, or stalled connection into a clear example failure.
func nextUpdate(subscription *convex.Subscription) json.RawMessage {
	select {
	case update, ok := <-subscription.Updates():
		if !ok {
			panic("Live subscription closed before delivering an update")
		}
		if update.Err != nil {
			panic(update.Err)
		}
		return update.Value
	case <-time.After(10 * time.Second):
		panic("timed out waiting for Live update")
	}
}

// decodeJSON turns a raw Convex result into the typed value needed by the next
// step and includes the operation name if decoding fails.
func decodeJSON(operation string, raw json.RawMessage, destination any) {
	if err := json.Unmarshal(raw, destination); err != nil {
		panic(fmt.Errorf("decode %s: %w", operation, err))
	}
}

// expectCount makes the example fail instead of merely printing an unexpected
// value. Docker uses that failure to reject a broken example.
func expectCount(operation string, actual integralCount, expected integralCount) {
	if actual != expected {
		panic(fmt.Sprintf("%s count was %d, expected %d", operation, actual, expected))
	}
}

// randomID gives this mutation its idempotency key. Reusing the same ID for
// the same room returns the existing result instead of incrementing twice.
func randomID() string {
	// Cryptographic randomness avoids collisions between concurrent example runs.
	var value [8]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(value[:])
}
```
<!-- END GENERATED EXAMPLE -->

This block is generated from `examples/basics/main.go`, which is also the source
shown on the evidence website. Edit and run the source file, then use
`./run sync-examples` to refresh this README projection.

## Conformance tests

The test-only source under `client/tests/conformance/` builds a thin Go executable
which accepts NDJSON protocol v1 on stdin and reserves stdout for NDJSON
events. It lets the shared harness exercise the real client and is not part of
the educational client API. It supports:

- `hello`
- `query`
- `mutation`
- `action`
- `subscribe`
- `unsubscribe`
- `close`

The adapter build also exposes `debugDisconnect`. This command is adapter-only
and test-only. It force-closes the current WebSocket while leaving the client
alive so the shared controller can test reconnect without Docker socket or host
network access. The hook is hidden from normal Go builds by the
`convexadapter` build tag.

Each Live subscription buffers at most 16 updates. If a subscriber falls
behind, the client discards the oldest buffered state and keeps the newest one.
The adapter's separate output owner accepts at most 16 encoded records and 8
MiB including conservative per-record overhead. It fails closed when either
budget is exhausted, and adapter shutdown does not wait indefinitely for a
controller that has stopped reading.

Example handshake:

```json
{"protocolVersion":1,"id":"hello-1","op":"hello"}
```

Runtime variables:

- `CONVEX_URL`, required before the first network command.
- `CONVEX_AUTH_TOKEN`, optional bearer token for HTTP calls.

## Docker-only verification

No Go tooling should run on the host.

```sh
./run test go
./run verify-example go
./run verify go
./run verify-hosted go
```

`test` runs race-enabled unit tests against mock HTTP and WebSocket peers.
`verify-example` builds this exact basic example into a minimal container, runs
it against a unique room, and requires the query, mutation, and Live subscription
to agree on a `0 -> 1` change. `verify` runs that check plus the complete
JavaScript-oracle and Go black-box suites against the pinned local backend.
`verify-hosted` repeats them over current HTTPS and WSS. Only those shared
controller results can calculate HTTP or Live. Trusted-main CI alone publishes
the badges shown by the official evidence site.

## How it talks to Convex

HTTP calls use Convex's documented `/api/query`, `/api/mutation`, and
`/api/action` endpoints. The client keeps successful values, function logs,
structured application errors, and transport failures distinct.

Live uses an ordinary Go WebSocket library, but the Convex-specific subscription
and reconnect behaviour is implemented in Go. It does not wrap `convex-js`,
`convex-rs`, the Convex CLI, `curl`, or another runtime.

The Live implementation is deliberately experimental. It targets the internal
`convex-rs` 0.10.4 protocol profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7` and the unversioned `/api/sync`
endpoint. That is a tested compatibility target, not a claim that Convex offers
a stable third-party sync protocol. See the
[protocol notes](../docs/protocol-profiles.md) for the exact boundary.

## Outside the current HTTP and Live scope

- Full tagged Convex value encoding and Go-native Int64/bytes/special-float mappings.
- Live auth, auth rotation, and token refresh.
- WebSocket mutations and actions.
- Ordered mutation queue, mutation replay, and commit-timestamp resolution.
- Action non-replay guarantees.
- Query journals, reactive pagination, optimistic updates, and query deduplication.
- The npm-versioned sync profile and `TransitionChunk` assembly.
- Repeated fault, large-payload, and atomic multi-query-view testing.
