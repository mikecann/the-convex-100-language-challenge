package tests

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	convex "github.com/mikecann/100-convex-clients/go"
)

func TestDocumentedHTTPQuery(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/query" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("Authorization = %q", got)
		}
		var body struct {
			Path   string         `json:"path"`
			Args   map[string]any `json:"args"`
			Format string         `json:"format"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body.Path != "demo:state" || body.Format != "json" || body.Args["room"] != "room-1" {
			t.Errorf("unexpected body: %+v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"success","value":{"count":1},"logLines":["hello"]}`))
	}))
	defer server.Close()

	client, err := convex.New(server.URL, convex.WithBearerToken("test-token"))
	if err != nil {
		t.Fatal(err)
	}
	result, err := client.Query(context.Background(), "demo:state", map[string]any{"room": "room-1"})
	if err != nil {
		t.Fatal(err)
	}
	if string(result.Value) != `{"count":1}` || len(result.LogLines) != 1 {
		t.Fatalf("result = %+v", result)
	}
}

func TestHTTPFunctionErrorAtStatus560(t *testing.T) {
	t.Parallel()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(560)
		_, _ = w.Write([]byte(`{"status":"error","errorMessage":"nope","errorData":{"code":"NOPE"},"logLines":["failed"]}`))
	}))
	defer server.Close()

	client, err := convex.New(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Mutation(context.Background(), "demo:increment", map[string]any{})
	var functionErr *convex.FunctionError
	if !errors.As(err, &functionErr) {
		t.Fatalf("expected FunctionError, got %T: %v", err, err)
	}
	if functionErr.Message != "nope" || string(functionErr.Data) != `{"code":"NOPE"}` || len(functionErr.LogLines) != 1 {
		t.Fatalf("FunctionError = %+v", functionErr)
	}
}

func TestArgumentsMustBeObject(t *testing.T) {
	t.Parallel()
	client, err := convex.New("https://example.convex.cloud")
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.Action(context.Background(), "demo:greet", []string{"go"})
	if err == nil {
		t.Fatal("expected argument validation error")
	}
}

func TestBearerTokenCanBeReplacedAndCleared(t *testing.T) {
	t.Parallel()
	received := make(chan string, 3)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received <- r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"success","value":null}`))
	}))
	defer server.Close()

	client, err := convex.New(server.URL, convex.WithBearerToken("first-token"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Query(context.Background(), "demo:state", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if err := client.SetAuth("replacement-token"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Query(context.Background(), "demo:state", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if err := client.SetAuth(""); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Query(context.Background(), "demo:state", map[string]any{}); err != nil {
		t.Fatal(err)
	}

	for index, expected := range []string{"Bearer first-token", "Bearer replacement-token", ""} {
		if actual := <-received; actual != expected {
			t.Fatalf("request %d Authorization = %q, want %q", index+1, actual, expected)
		}
	}
}
