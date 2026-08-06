//go:build convexadapter

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"runtime"
	"time"

	convex "github.com/mikecann/100-convex-clients/go/client"
)

const adapterProtocolVersion = 1

const adapterClientCloseTimeout = time.Second

type command struct {
	ID              string          `json:"id"`
	Op              string          `json:"op"`
	ProtocolVersion int             `json:"protocolVersion"`
	Path            string          `json:"path"`
	Args            json.RawMessage `json:"args"`
	SubscriptionID  string          `json:"subscriptionId"`
	Token           string          `json:"token"`
}

type adapterError struct {
	Name    string          `json:"name"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

type event struct {
	ProtocolVersion int             `json:"protocolVersion,omitempty"`
	ID              string          `json:"id,omitempty"`
	Type            string          `json:"type"`
	SubscriptionID  string          `json:"subscriptionId,omitempty"`
	Language        string          `json:"language,omitempty"`
	Implementation  string          `json:"implementation,omitempty"`
	Runtime         string          `json:"runtime,omitempty"`
	Value           json.RawMessage `json:"value,omitempty"`
	Logs            []string        `json:"logs,omitempty"`
	Error           *adapterError   `json:"error,omitempty"`
}

type adapterHooks struct {
	afterRelayDequeue func(subscriptionID string, generation uint64)
}

type adapterSubscription struct {
	subscription *convex.Subscription
	generation   uint64
}

func failureEvent(id string, subscriptionID string, err error) event {
	name := "Error"
	var data json.RawMessage
	var functionErr *convex.FunctionError
	var protocolErr *convex.ProtocolError
	var transportErr *convex.TransportError
	switch {
	case errors.As(err, &functionErr):
		name = "FunctionError"
		data = functionErr.Data
	case errors.As(err, &protocolErr):
		name = "ProtocolError"
	case errors.As(err, &transportErr):
		name = "TransportError"
	}

	failure := event{
		ID:             id,
		Type:           "error",
		SubscriptionID: subscriptionID,
		Error: &adapterError{
			Name:    name,
			Message: err.Error(),
			Data:    data,
		},
	}
	return finishFailureEvent(failure, subscriptionID, functionErr)
}

func finishFailureEvent(failure event, subscriptionID string, functionErr *convex.FunctionError) event {
	if subscriptionID != "" {
		failure.ID = ""
		failure.Type = "subscription"
	}
	if functionErr != nil {
		failure.Logs = functionErr.LogLines
	}
	return failure
}

func relaySubscription(
	subscriptionID string,
	generation uint64,
	updates <-chan convex.Update,
	out *output,
	hooks *adapterHooks,
) {
	for update := range updates {
		if hooks != nil && hooks.afterRelayDequeue != nil {
			hooks.afterRelayDequeue(subscriptionID, generation)
		}
		var value event
		if update.Err != nil {
			value = failureEvent("", subscriptionID, update.Err)
		} else {
			value = event{
				Type:           "subscription",
				SubscriptionID: subscriptionID,
				Value:          update.Value,
				Logs:           update.LogLines,
			}
		}
		if err := out.writeRelay(value, subscriptionID, generation); err != nil {
			return
		}
	}
}

func main() {
	listenAddress := os.Getenv("ADAPTER_LISTEN")
	if listenAddress == "" {
		runAdapter(os.Stdin, os.Stdout)
		return
	}

	listener, err := net.Listen("tcp", listenAddress)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen for conformance controller:", err)
		os.Exit(1)
	}
	defer listener.Close()
	fmt.Fprintln(os.Stderr, "adapter listening on", listenAddress)
	connection, err := listener.Accept()
	if err != nil {
		fmt.Fprintln(os.Stderr, "accept conformance controller:", err)
		os.Exit(1)
	}
	defer connection.Close()
	runAdapter(connection, connection)
}

func runAdapter(reader io.Reader, writer io.Writer) {
	runAdapterWithHooks(reader, writer, nil)
}

func runAdapterWithHooks(reader io.Reader, writer io.Writer, hooks *adapterHooks) {
	out := newOutput(writer)
	defer out.close(adapterOutputCloseTimeout)
	var client *convex.Client
	defer func() {
		if client == nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), adapterClientCloseTimeout)
		defer cancel()
		_ = client.Close(ctx)
	}()
	subscriptions := make(map[string]adapterSubscription)
	nextRelayGeneration := uint64(0)

	ensureClient := func() (*convex.Client, error) {
		if client != nil {
			return client, nil
		}
		deploymentURL := os.Getenv("CONVEX_URL")
		if deploymentURL == "" {
			return nil, errors.New("CONVEX_URL is required")
		}
		options := []convex.Option{convex.WithClientVersion("go-0.1.0")}
		if token := os.Getenv("CONVEX_AUTH_TOKEN"); token != "" {
			options = append(options, convex.WithBearerToken(token))
		}
		created, err := convex.New(deploymentURL, options...)
		if err != nil {
			return nil, err
		}
		client = created
		return client, nil
	}

	writeFailure := func(id string, subscriptionID string, err error) error {
		return out.write(failureEvent(id, subscriptionID, err))
	}

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 2<<20)
	for scanner.Scan() {
		var cmd command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			if writeErr := writeFailure("", "", fmt.Errorf("decode command: %w", err)); writeErr != nil {
				return
			}
			continue
		}
		if cmd.Args == nil {
			cmd.Args = json.RawMessage(`{}`)
		}

		switch cmd.Op {
		case "hello":
			if cmd.ProtocolVersion != adapterProtocolVersion {
				if err := writeFailure(cmd.ID, "", fmt.Errorf(
					"unsupported adapter protocol version %d", cmd.ProtocolVersion,
				)); err != nil {
					return
				}
				continue
			}
			if err := out.write(event{
				ProtocolVersion: adapterProtocolVersion,
				ID:              cmd.ID,
				Type:            "ready",
				Language:        "go",
				Implementation:  "native-go-" + runtime.Version(),
				Runtime:         runtime.Version(),
			}); err != nil {
				return
			}

		case "query", "mutation", "action":
			activeClient, err := ensureClient()
			if err != nil {
				if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
					return
				}
				continue
			}
			var result convex.Result
			switch cmd.Op {
			case "query":
				result, err = activeClient.Query(context.Background(), cmd.Path, cmd.Args)
			case "mutation":
				result, err = activeClient.Mutation(context.Background(), cmd.Path, cmd.Args)
			case "action":
				result, err = activeClient.Action(context.Background(), cmd.Path, cmd.Args)
			}
			if err != nil {
				if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
					return
				}
				continue
			}
			if err := out.write(event{
				ID:    cmd.ID,
				Type:  "result",
				Value: result.Value,
				Logs:  result.LogLines,
			}); err != nil {
				return
			}

		case "setAuth":
			activeClient, err := ensureClient()
			if err == nil {
				err = activeClient.SetAuth(cmd.Token)
			}
			if err != nil {
				if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
					return
				}
				continue
			}
			if err := out.write(event{ID: cmd.ID, Type: "ack"}); err != nil {
				return
			}

		case "subscribe":
			if cmd.SubscriptionID == "" {
				if err := writeFailure(cmd.ID, "", errors.New("subscriptionId is required")); err != nil {
					return
				}
				continue
			}
			activeClient, err := ensureClient()
			if err != nil {
				if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
					return
				}
				continue
			}
			subscription, err := activeClient.Subscribe(context.Background(), cmd.Path, cmd.Args)
			if err != nil {
				if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
					return
				}
				continue
			}
			if previous, ok := subscriptions[cmd.SubscriptionID]; ok {
				if err := out.invalidateRelay(cmd.SubscriptionID, previous.generation); err != nil {
					_ = subscription.Close()
					return
				}
				_ = previous.subscription.Close()
			}
			nextRelayGeneration++
			generation := nextRelayGeneration
			if err := out.activateRelay(cmd.SubscriptionID, generation); err != nil {
				_ = subscription.Close()
				return
			}
			subscriptions[cmd.SubscriptionID] = adapterSubscription{
				subscription: subscription,
				generation:   generation,
			}
			if err := out.write(event{
				ID:   cmd.ID,
				Type: "ack",
			}); err != nil {
				return
			}
			go relaySubscription(cmd.SubscriptionID, generation, subscription.Updates(), out, hooks)

		case "unsubscribe":
			state, ok := subscriptions[cmd.SubscriptionID]
			delete(subscriptions, cmd.SubscriptionID)
			if ok {
				if err := out.invalidateRelay(cmd.SubscriptionID, state.generation); err != nil {
					return
				}
				if err := state.subscription.Close(); err != nil {
					if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
						return
					}
					continue
				}
			}
			if err := out.write(event{
				ID:   cmd.ID,
				Type: "ack",
			}); err != nil {
				return
			}

		case "debugDisconnect":
			activeClient, err := ensureClient()
			if err == nil {
				err = activeClient.DebugDisconnectForAdapter()
			}
			if err != nil {
				if writeErr := writeFailure(cmd.ID, "", err); writeErr != nil {
					return
				}
				continue
			}
			if err := out.write(event{
				ID:   cmd.ID,
				Type: "ack",
			}); err != nil {
				return
			}

		case "close":
			for id, state := range subscriptions {
				if err := out.invalidateRelay(id, state.generation); err != nil {
					return
				}
				delete(subscriptions, id)
			}
			if client != nil {
				ctx, cancel := context.WithTimeout(context.Background(), adapterClientCloseTimeout)
				_ = client.Close(ctx)
				cancel()
			}
			if err := out.write(event{ID: cmd.ID, Type: "closed"}); err != nil {
				return
			}
			return

		default:
			if err := writeFailure(cmd.ID, "", fmt.Errorf("unknown operation %q", cmd.Op)); err != nil {
				return
			}
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintln(os.Stderr, "read adapter command:", err)
	}
}
