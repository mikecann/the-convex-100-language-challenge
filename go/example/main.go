package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"time"

	convex "github.com/mikecann/100-convex-clients/go"
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

func printJSON(label string, raw json.RawMessage) {
	var indented any
	if err := json.Unmarshal(raw, &indented); err != nil {
		panic(err)
	}
	formatted, _ := json.MarshalIndent(indented, "", "  ")
	fmt.Printf("%s: %s\n", label, formatted)
}

func randomID() string {
	var value [8]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(value[:])
}
