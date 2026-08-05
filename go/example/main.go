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
	deploymentURL := os.Getenv("CONVEX_URL")
	if deploymentURL == "" {
		fmt.Fprintln(os.Stderr, "CONVEX_URL is required")
		os.Exit(2)
	}
	client, err := convex.New(deploymentURL)
	if err != nil {
		panic(err)
	}
	defer client.Close(context.Background())

	room := "go-example"
	if len(os.Args) > 1 {
		room = os.Args[1]
	}
	subscription, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": room})
	if err != nil {
		panic(err)
	}
	defer subscription.Close()

	result, err := client.Mutation(context.Background(), "demo:increment", map[string]any{
		"room":     room,
		"language": "go",
		"runId":    randomID(),
	})
	if err != nil {
		panic(err)
	}
	printJSON("mutation", result.Value)

	select {
	case update := <-subscription.Updates():
		if update.Err != nil {
			panic(update.Err)
		}
		printJSON("live", update.Value)
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
