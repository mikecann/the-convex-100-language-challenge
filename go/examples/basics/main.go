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
