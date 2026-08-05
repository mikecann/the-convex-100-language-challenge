# Go Convex client pilot

This directory contains a native Go implementation of Convex's documented HTTP
Functions API plus a deliberately small Live WebSocket client.

It does not wrap `convex-js`, `convex-rs`, the Convex CLI, `curl`, or another
runtime. `github.com/coder/websocket` supplies ordinary WebSocket transport;
all Convex-specific request, response, subscription, transition, reconnect,
and lifecycle behaviour is implemented here in Go.

## Protocol scope

HTTP uses the documented `/api/query`, `/api/mutation`, and `/api/action`
endpoints with `format: "json"`. It supports an optional user bearer token and
keeps success values, function logs, structured application error data, and
transport errors distinct.

The shared suite exercises absent, rejected, replaced, and cleared tokens. A
race-enabled Go transport test proves exact bearer-header forwarding. The pilot
does not claim a successful signed identity because the dedicated deployment
has no configured identity provider; that integration is outside the current
HTTP and Live scope.

Live is pinned to the internal `convex-rs` 0.10.4 profile at commit
`6f1df8a8ba1665084ec001e307ca841ca17074d7`. It uses the unversioned
`/api/sync` endpoint and implements initial results, later transitions,
unsubscribe, reconnect with active-query restoration, query failures, server
inactivity detection, and deterministic close.

That source revision defines chunked transitions, but chunk assembly is
deliberately deferred from this pilot. Receiving `TransitionChunk` is surfaced
as protocol drift and causes a clean reconnect instead of silently corrupting
the subscription state.

This pin is a compatibility target, not a claim that Convex supports a stable
third-party sync protocol.

## Usage

<!-- BEGIN GENERATED EXAMPLE: examples/basics/main.go -->
```go
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"time"

	convex "github.com/mikecann/100-convex-clients/go/client"
)

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

	var state struct {
		Count float64 `json:"count"`
	}
	// Decode the JSON result into a typed Go value the application can use.
	if err := json.Unmarshal(result.Value, &state); err != nil {
		panic(err)
	}
	fmt.Printf("current count: %.0f\n", state.Count)

	// Begin listening for changes to the same query over Convex Live.
	subscription, err := client.Subscribe(ctx, "demo:state", map[string]any{"room": room})
	if err != nil {
		panic(err)
	}

	// Stop listening when the example exits.
	defer subscription.Close()

	// A subscription first sends the current value. Read that snapshot before
	// making a change so the following update is unambiguous.
	printJSON("live initial", nextUpdate(subscription))

	// Run a mutation over HTTP. The subscription above will observe this write.
	mutation, err := client.Mutation(ctx, "demo:increment", map[string]any{
		"room":     room,
		"language": "go",
		"runId":    randomID(),
	})
	if err != nil {
		panic(err)
	}
	printJSON("mutation", mutation.Value)

	// Receive the changed room through Live without issuing another HTTP query.
	printJSON("live update", nextUpdate(subscription))
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

// printJSON makes a raw Convex result readable in the terminal. Application
// code would normally decode the value into a typed struct instead.
func printJSON(label string, raw json.RawMessage) {
	// Decode only so MarshalIndent can add whitespace without changing the data.
	var indented any
	if err := json.Unmarshal(raw, &indented); err != nil {
		panic(err)
	}
	formatted, _ := json.MarshalIndent(indented, "", "  ")
	fmt.Printf("%s: %s\n", label, formatted)
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

This block is generated from `examples/basics/main.go`, which is also the source shown
on the evidence website. Edit and run the source file, then use
`./run sync-examples` to refresh this README projection.

## Adapter

The final image runs a thin Go adapter which accepts NDJSON protocol v1 on
stdin and reserves stdout for NDJSON events. It supports:

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
./run verify go
./run verify-hosted go
```

`test` runs race-enabled unit tests against mock HTTP and WebSocket peers.
`verify` runs the complete JavaScript-oracle and Go black-box suites against the
pinned local backend. `verify-hosted` repeats them over current HTTPS and WSS.
Only those shared controller results can calculate HTTP or Live. Trusted-main
CI alone publishes the badges shown by the official evidence site.

## Outside the current HTTP and Live scope

- Full tagged Convex value encoding and Go-native Int64/bytes/special-float mappings.
- Live auth, auth rotation, and token refresh.
- WebSocket mutations and actions.
- Ordered mutation queue, mutation replay, and commit-timestamp resolution.
- Action non-replay guarantees.
- Query journals, reactive pagination, optimistic updates, and query deduplication.
- The npm-versioned sync profile and `TransitionChunk` assembly.
- Repeated fault, large-payload, and atomic multi-query-view testing.
