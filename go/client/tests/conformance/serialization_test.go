//go:build convexadapter

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	convex "github.com/mikecann/100-convex-clients/go/client"
)

func TestAdapterSerializationUsesExactNDJSONShapes(t *testing.T) {
	t.Parallel()
	functionError := &convex.FunctionError{
		Operation: "query",
		Message:   "denied",
		Data:      json.RawMessage(`{"code":"DENIED"}`),
		LogLines:  []string{"backend"},
	}
	cases := []struct {
		name  string
		value event
		want  string
	}{
		{
			name: "successful result omits absent logs",
			value: event{
				ID:    "query-1",
				Type:  "result",
				Value: json.RawMessage(`{"count":1}`),
			},
			want: `{"id":"query-1","type":"result","value":{"count":1}}`,
		},
		{
			name:  "function error includes data and logs",
			value: failureEvent("call-1", "", functionError),
			want:  `{"id":"call-1","type":"error","logs":["backend"],"error":{"name":"FunctionError","message":"convex query failed: denied","data":{"code":"DENIED"}}}`,
		},
		{
			name:  "function error omits absent data",
			value: failureEvent("call-2", "", &convex.FunctionError{Operation: "query", Message: "denied"}),
			want:  `{"id":"call-2","type":"error","error":{"name":"FunctionError","message":"convex query failed: denied"}}`,
		},
		{
			name:  "protocol error omits absent data",
			value: failureEvent("protocol-1", "", &convex.ProtocolError{Message: "malformed"}),
			want:  `{"id":"protocol-1","type":"error","error":{"name":"ProtocolError","message":"convex protocol error: malformed"}}`,
		},
		{
			name:  "transport error omits absent data",
			value: failureEvent("transport-1", "", &convex.TransportError{Operation: "query", Err: errors.New("connection reset")}),
			want:  `{"id":"transport-1","type":"error","error":{"name":"TransportError","message":"convex query transport error: connection reset"}}`,
		},
		{
			name:  "subscription error omits request id",
			value: failureEvent("", "sub-1", functionError),
			want:  `{"type":"subscription","subscriptionId":"sub-1","logs":["backend"],"error":{"name":"FunctionError","message":"convex query failed: denied","data":{"code":"DENIED"}}}`,
		},
		{
			name:  "close omits all optional fields",
			value: event{ID: "close-1", Type: "closed"},
			want:  `{"id":"close-1","type":"closed"}`,
		},
	}

	var output bytes.Buffer
	out := newOutput(&output)
	for _, test := range cases {
		if err := out.write(test.value); err != nil {
			t.Fatalf("%s: %v", test.name, err)
		}
	}
	if !out.close(time.Second) {
		t.Fatal("adapter output did not close")
	}

	want := make([]string, 0, len(cases))
	for _, test := range cases {
		want = append(want, test.want)
	}
	if got := strings.TrimSuffix(output.String(), "\n"); got != strings.Join(want, "\n") {
		t.Fatalf("NDJSON mismatch\n got: %s\nwant: %s", got, strings.Join(want, "\n"))
	}
	for _, line := range strings.Split(strings.TrimSuffix(output.String(), "\n"), "\n") {
		var decoded any
		if err := json.Unmarshal([]byte(line), &decoded); err != nil {
			t.Fatalf("invalid JSON line %q: %v", line, err)
		}
		if containsNull(decoded) {
			t.Fatalf("optional field was serialized as null: %s", line)
		}
	}
}

func containsNull(value any) bool {
	switch value := value.(type) {
	case nil:
		return true
	case []any:
		for _, item := range value {
			if containsNull(item) {
				return true
			}
		}
	case map[string]any:
		for _, item := range value {
			if containsNull(item) {
				return true
			}
		}
	}
	return false
}
