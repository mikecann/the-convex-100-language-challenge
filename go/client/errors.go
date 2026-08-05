package convex

import (
	"encoding/json"
	"errors"
	"fmt"
)

// ErrClosed is returned when an operation starts after the client has closed.
var ErrClosed = errors.New("convex client is closed")

// Result is a successful Convex function result. Value stays as JSON so callers
// can decode it into an application-specific Go type without losing log lines.
type Result struct {
	Value    json.RawMessage
	LogLines []string
}

// FunctionError is an error returned by a Convex query, mutation, or action.
// Data contains the structured application error payload when Convex supplied
// one. It is nil for ordinary developer or server errors.
type FunctionError struct {
	Operation string
	Message   string
	Data      json.RawMessage
	LogLines  []string
}

func (e *FunctionError) Error() string {
	if e.Operation == "" {
		return e.Message
	}
	return fmt.Sprintf("convex %s failed: %s", e.Operation, e.Message)
}

// ProtocolError means a peer response did not match the pinned client
// contract. It is deliberately distinct from function and transport errors.
type ProtocolError struct {
	Message string
}

func (e *ProtocolError) Error() string {
	return "convex protocol error: " + e.Message
}

// TransportError wraps HTTP and WebSocket failures.
type TransportError struct {
	Operation string
	Err       error
}

func (e *TransportError) Error() string {
	if e.Operation == "" {
		return "convex transport error: " + e.Err.Error()
	}
	return fmt.Sprintf("convex %s transport error: %v", e.Operation, e.Err)
}

func (e *TransportError) Unwrap() error { return e.Err }
