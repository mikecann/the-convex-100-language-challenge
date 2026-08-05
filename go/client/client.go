package convex

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	defaultClientVersion = "go-0.1.0"
	maxResponseBytes     = 2 << 20
)

// Option customizes a Client.
type Option func(*Client)

// WithHTTPClient replaces the HTTP transport. It is useful for applications
// with a shared transport policy and for tests.
func WithHTTPClient(client *http.Client) Option {
	return func(c *Client) {
		if client != nil {
			c.httpClient = client
		}
	}
}

// WithBearerToken configures the user JWT sent to the documented Functions
// HTTP API. Live authentication is intentionally deferred from the pilot.
func WithBearerToken(token string) Option {
	return func(c *Client) { c.authToken = token }
}

// WithClientVersion sets the value of the Convex-Client request header.
func WithClientVersion(version string) Option {
	return func(c *Client) {
		if version != "" {
			c.clientVersion = version
		}
	}
}

// Client is a native Go client for the documented Convex HTTP API and the
// explicitly pinned convex-rs 0.10.4 Live protocol profile.
type Client struct {
	deploymentURL string
	httpClient    *http.Client
	clientVersion string

	mu        sync.RWMutex
	authToken string
	closed    bool
	live      *liveManager
}

// New constructs a client for a Convex deployment URL.
func New(deploymentURL string, options ...Option) (*Client, error) {
	u, err := url.Parse(deploymentURL)
	if err != nil {
		return nil, fmt.Errorf("parse Convex deployment URL: %w", err)
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("Convex deployment URL must use http or https")
	}
	if u.Host == "" {
		return nil, fmt.Errorf("Convex deployment URL must include a host")
	}
	if u.User != nil {
		return nil, fmt.Errorf("Convex deployment URL must not include user information")
	}
	u.RawQuery = ""
	u.Fragment = ""
	u.Path = strings.TrimRight(u.Path, "/")

	c := &Client{
		deploymentURL: strings.TrimRight(u.String(), "/"),
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
		clientVersion: defaultClientVersion,
	}
	for _, option := range options {
		option(c)
	}
	return c, nil
}

// SetAuth updates the bearer token used by subsequent HTTP calls. Passing an
// empty string clears authentication. Live auth is not part of this pilot.
func (c *Client) SetAuth(token string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return ErrClosed
	}
	c.authToken = token
	return nil
}

// Query calls a public Convex query through the documented HTTP API.
func (c *Client) Query(ctx context.Context, path string, args any) (Result, error) {
	return c.call(ctx, "query", path, args)
}

// Mutation calls a public Convex mutation through the documented HTTP API.
func (c *Client) Mutation(ctx context.Context, path string, args any) (Result, error) {
	return c.call(ctx, "mutation", path, args)
}

// Action calls a public Convex action through the documented HTTP API.
func (c *Client) Action(ctx context.Context, path string, args any) (Result, error) {
	return c.call(ctx, "action", path, args)
}

type functionRequest struct {
	Path   string          `json:"path"`
	Args   json.RawMessage `json:"args"`
	Format string          `json:"format"`
}

type functionResponse struct {
	Status       string          `json:"status"`
	Value        json.RawMessage `json:"value"`
	ErrorMessage string          `json:"errorMessage"`
	ErrorData    json.RawMessage `json:"errorData"`
	LogLines     []string        `json:"logLines"`
}

func (c *Client) call(ctx context.Context, operation, path string, args any) (Result, error) {
	if path == "" {
		return Result{}, fmt.Errorf("Convex function path is required")
	}
	encodedArgs, err := marshalArgs(args)
	if err != nil {
		return Result{}, err
	}

	c.mu.RLock()
	if c.closed {
		c.mu.RUnlock()
		return Result{}, ErrClosed
	}
	token := c.authToken
	httpClient := c.httpClient
	clientVersion := c.clientVersion
	endpoint := c.deploymentURL + "/api/" + operation
	c.mu.RUnlock()

	body, err := json.Marshal(functionRequest{
		Path:   path,
		Args:   encodedArgs,
		Format: "json",
	})
	if err != nil {
		return Result{}, fmt.Errorf("encode Convex %s request: %w", operation, err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return Result{}, fmt.Errorf("create Convex %s request: %w", operation, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Convex-Client", clientVersion)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return Result{}, &TransportError{Operation: operation, Err: err}
	}
	defer resp.Body.Close()
	responseBody, err := readLimited(resp.Body, maxResponseBytes)
	if err != nil {
		return Result{}, &TransportError{Operation: operation, Err: err}
	}

	var decoded functionResponse
	if err := json.Unmarshal(responseBody, &decoded); err != nil {
		return Result{}, &TransportError{
			Operation: operation,
			Err:       fmt.Errorf("HTTP %d returned a non-Convex response: %w", resp.StatusCode, err),
		}
	}
	switch decoded.Status {
	case "success":
		if decoded.Value == nil {
			return Result{}, &ProtocolError{Message: "success response omitted value"}
		}
		return Result{Value: cloneRaw(decoded.Value), LogLines: decoded.LogLines}, nil
	case "error":
		return Result{}, &FunctionError{
			Operation: operation,
			Message:   decoded.ErrorMessage,
			Data:      cloneRaw(decoded.ErrorData),
			LogLines:  decoded.LogLines,
		}
	default:
		return Result{}, &ProtocolError{
			Message: fmt.Sprintf("HTTP %d response has unknown status %q", resp.StatusCode, decoded.Status),
		}
	}
}

func marshalArgs(args any) (json.RawMessage, error) {
	if args == nil {
		return json.RawMessage(`{}`), nil
	}
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, fmt.Errorf("encode Convex arguments: %w", err)
	}
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, fmt.Errorf("Convex arguments must encode as a named JSON object")
	}
	return cloneRaw(trimmed), nil
}

func readLimited(reader io.Reader, limit int64) ([]byte, error) {
	limited := io.LimitReader(reader, limit+1)
	body, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("response exceeds %d bytes", limit)
	}
	return body, nil
}

func cloneRaw(raw json.RawMessage) json.RawMessage {
	if raw == nil {
		return nil
	}
	return append(json.RawMessage(nil), raw...)
}
