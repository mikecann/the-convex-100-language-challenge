<img src="logo.png" alt="Go logo" width="180">
<!-- Logo source: https://go.dev/blog/go-brand/Go-Logo/PNG/Go-Logo_Blue.png -->

# Go

[Go](https://go.dev/) is a compiled, statically typed language created at
[Google](https://go.dev/solutions/google/) by Robert Griesemer, Rob Pike, and
Ken Thompson. Work began in 2007 and the project became public in 2009. It takes
ideas familiar from C, including small syntax and compiled binaries, then adds
garbage collection, structural
interfaces, and lightweight concurrency. Go is especially common in API and
RPC services, command-line tools, cloud infrastructure, and networking software.
The [2025 Go Developer Survey](https://go.dev/blog/survey2025) found that 82% of
respondents used it for their primary job, so its present-day niche is firmly
professional backend and infrastructure work rather than language curiosity.

This client is an educational, unofficial demonstration. It is not an official
Convex SDK and it is not intended for production use.

## Getting Started

Start with the [canonical basic example](examples/basics/main.go). It queries a
counter, opens a Live subscription, increments the counter, and checks that the
HTTP and Live results agree. From the repository root, run:

```sh
./run verify-example go
```

That command builds and runs the example in Docker, so you do not need to
install Go on the host.

## Interesting Parts

### `range` over a channel is the render loop

Channels are Go's signature idea, descended from Tony Hoare's 1978
"Communicating Sequential Processes". In this client one goroutine owns the
WebSocket, and each Live subscription hands you a receive-only channel of
updates. Ranging over it blocks until Convex pushes the next value — the
initial snapshot and every later change arrive the same way.

```go
type roomState struct {
	Count float64 `json:"count"` // the backtick struct tag names the JSON field
}

for update := range subscription.Updates() {
	if update.Err != nil {
		break
	}
	var state roomState
	json.Unmarshal(update.Value, &state)
	fmt.Println(state.Count) // TypeScript: every rerender from useQuery(api.demo.state, { room })
}
```

Where React turns each new value into a render, Go turns it into one more trip
around the loop.

### Cleanup is declared next to the thing it cleans up

Go has no destructors and no `finally`. Instead, `defer` schedules a call to
run when the surrounding function returns, whichever exit it takes, so a
resource and its release sit on neighbouring lines.

```go
client, err := convex.New(os.Getenv("CONVEX_URL"))
// ... check err ...
defer client.Close(ctx) // shuts the shared WebSocket on every way out of main

subscription, err := client.Subscribe(ctx, "demo:state", map[string]any{"room": room})
// ... check err ...
defer subscription.Close() // TypeScript: the cleanup function returned from useEffect
```

### Errors are values with types worth asking about

Go returns errors instead of throwing them; "errors are values" is a Rob Pike
essay title and a community proverb. This client gives each failure mode its
own type — `FunctionError`, `ProtocolError`, `TransportError` — so `errors.As`
can pick out the one your code can actually respond to.

```go
_, err := client.Mutation(ctx, "demo:increment", args)

var fnErr *convex.FunctionError
if errors.As(err, &fnErr) {
	// The Convex function itself said no; its server log lines came along too.
	fmt.Println(fnErr.Message, fnErr.LogLines)
	// TypeScript: catch (e) { if (e instanceof ConvexError) ... }
}
```

### Options are plain functions

Go has no keyword arguments or constructor overloads, so its community settled
on the "functional options" idiom: a constructor accepts variadic values, each
a function that adjusts the client. Configuration reads aloud, and adding a
new knob later never breaks an existing caller.

```go
client, err := convex.New(
	deploymentURL,
	convex.WithBearerToken(token), // TypeScript: client.setAuth(fetchToken) — HTTP calls only here
	convex.WithHTTPClient(&http.Client{Timeout: 5 * time.Second}),
)
```

## Status

| Capability | Status |
| --- | --- |
| Queries, mutations, and actions over HTTP | Verified by shared local and hosted conformance |
| Bearer-token authentication for HTTP calls | Implemented and covered by Go-local tests |
| Initial and updated Live query values | Verified by shared local and hosted conformance |
| Unsubscribe, reconnect, timeouts, and clean shutdown | Implemented and covered by Go-local tests |
| Canonical basic example executed in Docker | Verified against self-hosted and hosted deployments |
| Authentication for Live subscriptions | Not yet |
| Full tagged Convex value types | Not yet |

The implementation provenance is **native**. HTTP and Live are the two earned
capabilities recorded in the manifest.

## Example

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

	convex "github.com/mikecann/the-convex-100-language-challenge/go/client"
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

This block is generated from `examples/basics/main.go`. The README, evidence
site, and Docker image all use that exact source.

## Implementation Notes

- The public client is ordinary Go. It uses the standard `net/http` and
  `encoding/json` packages for Convex's documented HTTP endpoints, plus the
  pinned `github.com/coder/websocket` dependency for Live transport. All
  Convex-specific request, subscription, and reconnect behaviour is implemented
  in Go rather than delegated to another Convex client or runtime.
- HTTP calls take a `context.Context`, validate that arguments encode as a named
  JSON object, and return raw JSON alongside function log lines. Function,
  protocol, and transport failures have distinct Go error types, so callers can
  inspect them with `errors.As`.
- One goroutine owns Live connections, subscriptions, query-set changes, and
  reconnects. Each subscription exposes a receive-only channel buffered to 16
  updates. If its reader falls behind, the client drops the oldest buffered
  state and retains the newest rather than blocking the WebSocket owner.
- Live targets the pinned internal `convex-rs` 0.10.4 profile at commit
  `6f1df8a8ba1665084ec001e307ca841ca17074d7` through the unversioned `/api/sync`
  endpoint. That is a tested compatibility target, not a stable third-party
  protocol promise. The [protocol notes](../docs/protocol-profiles.md) define
  the boundary.
- The test-only conformance adapter is compiled with the `convexadapter` build
  tag. Its `debugDisconnect` hook proves reconnect behaviour without appearing
  in the educational client API. Adapter output has separate 16-record and
  8 MiB limits so a stopped controller cannot create unbounded memory growth.
- `./run test go` performs formatting checks, race-enabled unit tests, and
  compilation inside the pinned Go 1.25.6 Docker image. `./run verify go` and
  `./run verify-hosted go` are the separate shared conformance layers that
  produced the capability evidence recorded above.

## Known Issues

1. Live subscriptions do not support authentication, token rotation, or token
   refresh. Bearer tokens apply only to HTTP calls.
2. Values use JSON's safe subset as `json.RawMessage`. Tagged Convex values such
   as Int64, bytes, and special floating-point values have no Go-native mapping.
3. Mutations and actions use HTTP only. Live mutation ordering, replay,
   journals, optimistic updates, and action non-replay guarantees are deferred.
4. `TransitionChunk` assembly and the npm-versioned sync profile are not
   implemented. Receiving a chunk is treated as protocol drift and causes a
   reconnect.
