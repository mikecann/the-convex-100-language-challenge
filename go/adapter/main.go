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
	"sync"

	convex "github.com/mikecann/100-convex-clients/go"
)

const adapterProtocolVersion = 1

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
	Data    json.RawMessage `json:"data"`
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

type output struct {
	mu     sync.Mutex
	writer io.Writer
}

func (o *output) write(value event) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if err := json.NewEncoder(o.writer).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, "encode adapter event:", err)
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
	out := &output{writer: writer}
	var client *convex.Client
	var clientMu sync.Mutex
	subscriptions := make(map[string]*convex.Subscription)
	var subscriptionsMu sync.Mutex

	ensureClient := func() (*convex.Client, error) {
		clientMu.Lock()
		defer clientMu.Unlock()
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

	writeFailure := func(id string, subscriptionID string, err error) {
		name := "Error"
		data := json.RawMessage(`null`)
		var functionErr *convex.FunctionError
		var protocolErr *convex.ProtocolError
		var transportErr *convex.TransportError
		switch {
		case errors.As(err, &functionErr):
			name = "FunctionError"
			if functionErr.Data != nil {
				data = functionErr.Data
			}
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
		if subscriptionID != "" {
			failure.ID = ""
			failure.Type = "subscription"
		}
		if functionErr != nil {
			failure.Logs = functionErr.LogLines
		}
		out.write(failure)
	}

	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 64*1024), 2<<20)
	for scanner.Scan() {
		var cmd command
		if err := json.Unmarshal(scanner.Bytes(), &cmd); err != nil {
			writeFailure("", "", fmt.Errorf("decode command: %w", err))
			continue
		}
		if cmd.Args == nil {
			cmd.Args = json.RawMessage(`{}`)
		}

		switch cmd.Op {
		case "hello":
			if cmd.ProtocolVersion != adapterProtocolVersion {
				writeFailure(cmd.ID, "", fmt.Errorf(
					"unsupported adapter protocol version %d", cmd.ProtocolVersion,
				))
				continue
			}
			out.write(event{
				ProtocolVersion: adapterProtocolVersion,
				ID:              cmd.ID,
				Type:            "ready",
				Language:        "go",
				Implementation:  "native-go-" + runtime.Version(),
				Runtime:         runtime.Version(),
			})

		case "query", "mutation", "action":
			activeClient, err := ensureClient()
			if err != nil {
				writeFailure(cmd.ID, "", err)
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
				writeFailure(cmd.ID, "", err)
				continue
			}
			out.write(event{
				ID:    cmd.ID,
				Type:  "result",
				Value: result.Value,
				Logs:  result.LogLines,
			})

		case "setAuth":
			activeClient, err := ensureClient()
			if err == nil {
				err = activeClient.SetAuth(cmd.Token)
			}
			if err != nil {
				writeFailure(cmd.ID, "", err)
				continue
			}
			out.write(event{ID: cmd.ID, Type: "ack"})

		case "subscribe":
			if cmd.SubscriptionID == "" {
				writeFailure(cmd.ID, "", errors.New("subscriptionId is required"))
				continue
			}
			activeClient, err := ensureClient()
			if err != nil {
				writeFailure(cmd.ID, "", err)
				continue
			}
			subscription, err := activeClient.Subscribe(context.Background(), cmd.Path, cmd.Args)
			if err != nil {
				writeFailure(cmd.ID, "", err)
				continue
			}
			subscriptionsMu.Lock()
			if previous := subscriptions[cmd.SubscriptionID]; previous != nil {
				_ = previous.Close()
			}
			subscriptions[cmd.SubscriptionID] = subscription
			subscriptionsMu.Unlock()
			out.write(event{
				ID:   cmd.ID,
				Type: "ack",
			})
			go func(subscriptionID string, sub *convex.Subscription) {
				for update := range sub.Updates() {
					if update.Err != nil {
						writeFailure("", subscriptionID, update.Err)
						continue
					}
					out.write(event{
						Type:           "subscription",
						SubscriptionID: subscriptionID,
						Value:          update.Value,
						Logs:           update.LogLines,
					})
				}
			}(cmd.SubscriptionID, subscription)

		case "unsubscribe":
			subscriptionsMu.Lock()
			subscription := subscriptions[cmd.SubscriptionID]
			delete(subscriptions, cmd.SubscriptionID)
			subscriptionsMu.Unlock()
			if subscription != nil {
				if err := subscription.Close(); err != nil {
					writeFailure(cmd.ID, "", err)
					continue
				}
			}
			out.write(event{
				ID:   cmd.ID,
				Type: "ack",
			})

		case "debugDisconnect":
			activeClient, err := ensureClient()
			if err == nil {
				err = activeClient.DebugDisconnectForAdapter()
			}
			if err != nil {
				writeFailure(cmd.ID, "", err)
				continue
			}
			out.write(event{
				ID:   cmd.ID,
				Type: "ack",
			})

		case "close":
			subscriptionsMu.Lock()
			for id, subscription := range subscriptions {
				_ = subscription.Close()
				delete(subscriptions, id)
			}
			subscriptionsMu.Unlock()
			clientMu.Lock()
			if client != nil {
				_ = client.Close(context.Background())
			}
			clientMu.Unlock()
			out.write(event{ID: cmd.ID, Type: "closed"})
			return

		default:
			writeFailure(cmd.ID, "", fmt.Errorf("unknown operation %q", cmd.Op))
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintln(os.Stderr, "read adapter command:", err)
	}
}
