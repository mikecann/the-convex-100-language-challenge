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

// roomState is the part of the Convex query result used by this example.
type roomState struct {
	Count float64 `json:"count"`
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
	initialValue := nextUpdate(subscription)
	var initialState roomState
	decodeJSON("initial Live value", initialValue, &initialState)
	expectCount("initial Live value", initialState.Count, state.Count)
	printJSON("live initial", initialValue)

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
	expectedCount := state.Count + 1
	expectCount("mutation", increment.State.Count, expectedCount)
	printJSON("mutation", mutation.Value)

	// Receive the changed room through Live without issuing another HTTP query.
	updatedValue := nextUpdate(subscription)
	var updatedState roomState
	decodeJSON("updated Live value", updatedValue, &updatedState)
	expectCount("updated Live value", updatedState.Count, expectedCount)
	printJSON("live update", updatedValue)

	// Reaching this line proves the query, mutation, and Live subscription all
	// agreed on the same change.
	fmt.Printf("verified count: %.0f -> %.0f\n", state.Count, updatedState.Count)
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
func expectCount(operation string, actual float64, expected float64) {
	if actual != expected {
		panic(fmt.Sprintf("%s count was %.0f, expected %.0f", operation, actual, expected))
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
