package tests

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	convex "github.com/mikecann/100-convex-clients/go"
)

type testWireMessage struct {
	Type            string `json:"type"`
	ConnectionCount uint32 `json:"connectionCount"`
	BaseVersion     uint32 `json:"baseVersion"`
	NewVersion      uint32 `json:"newVersion"`
	Modifications   []struct {
		Type    string `json:"type"`
		QueryID uint32 `json:"queryId"`
		UDFPath string `json:"udfPath"`
	} `json:"modifications"`
}

func TestLiveInitialUpdateUnsubscribeAndClose(t *testing.T) {
	t.Parallel()
	serverUpdates := make(chan int, 2)
	removeSeen := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/sync" {
			http.NotFound(w, r)
			return
		}
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		var connect testWireMessage
		if err := wsjson.Read(ctx, conn, &connect); err != nil {
			t.Error(err)
			return
		}
		var add testWireMessage
		if err := wsjson.Read(ctx, conn, &add); err != nil {
			t.Error(err)
			return
		}
		queryID := add.Modifications[0].QueryID
		if add.Type != "ModifyQuerySet" || add.Modifications[0].UDFPath != "demo:state" {
			t.Errorf("unexpected add: %+v", add)
		}
		if err := sendTransition(ctx, conn, 0, 1, "AAAAAAAAAAA=", "AQAAAAAAAAA=", queryID, 0); err != nil {
			t.Error(err)
			return
		}
		value := <-serverUpdates
		if err := sendTransition(ctx, conn, 1, 1, "AQAAAAAAAAA=", "AgAAAAAAAAA=", queryID, value); err != nil {
			t.Error(err)
			return
		}
		var remove testWireMessage
		if err := wsjson.Read(ctx, conn, &remove); err != nil {
			t.Error(err)
			return
		}
		if remove.Modifications[0].Type != "Remove" {
			t.Errorf("unexpected remove: %+v", remove)
		}
		close(removeSeen)
		<-ctx.Done()
	}))
	defer server.Close()

	client, err := convex.New(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "test"})
	if err != nil {
		t.Fatal(err)
	}
	assertLiveCount(t, sub, 0)
	serverUpdates <- 1
	assertLiveCount(t, sub, 1)
	if err := sub.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-removeSeen:
	case <-time.After(2 * time.Second):
		t.Fatal("server did not receive Remove")
	}
	if err := client.Close(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case _, ok := <-sub.Updates():
		if ok {
			t.Fatal("subscription channel remained open")
		}
	case <-time.After(time.Second):
		t.Fatal("subscription channel did not close")
	}
}

func TestLiveReconnectRestoresSubscription(t *testing.T) {
	t.Parallel()
	var connectionMu sync.Mutex
	connections := 0
	secondConnected := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		var connect testWireMessage
		if err := wsjson.Read(ctx, conn, &connect); err != nil {
			t.Error(err)
			return
		}
		var add testWireMessage
		if err := wsjson.Read(ctx, conn, &add); err != nil {
			t.Error(err)
			return
		}
		connectionMu.Lock()
		connections++
		current := connections
		connectionMu.Unlock()
		if connect.ConnectionCount != uint32(current-1) {
			t.Errorf("connectionCount = %d on connection %d", connect.ConnectionCount, current)
		}
		queryID := add.Modifications[0].QueryID
		if current == 1 {
			if err := sendTransition(ctx, conn, 0, 1, "AAAAAAAAAAA=", "AQAAAAAAAAA=", queryID, 1); err != nil {
				t.Error(err)
			}
			_ = conn.Close(websocket.StatusInternalError, "test disconnect")
			return
		}
		if err := sendTransition(ctx, conn, 0, 1, "AAAAAAAAAAA=", "AgAAAAAAAAA=", queryID, 2); err != nil {
			t.Error(err)
			return
		}
		close(secondConnected)
		<-ctx.Done()
	}))
	defer server.Close()

	client, err := convex.New(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background())
	sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "reconnect"})
	if err != nil {
		t.Fatal(err)
	}
	assertLiveCount(t, sub, 1)
	assertLiveCount(t, sub, 2)
	select {
	case <-secondConnected:
	case <-time.After(3 * time.Second):
		t.Fatal("client did not reconnect")
	}
}

func TestCancelledCloseStillInitiatesShutdown(t *testing.T) {
	t.Parallel()
	serverClosed := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		var connect testWireMessage
		if err := wsjson.Read(ctx, conn, &connect); err != nil {
			t.Error(err)
			return
		}
		var add testWireMessage
		if err := wsjson.Read(ctx, conn, &add); err != nil {
			t.Error(err)
			return
		}
		if err := sendTransition(
			ctx,
			conn,
			0,
			1,
			"AAAAAAAAAAA=",
			"AQAAAAAAAAA=",
			add.Modifications[0].QueryID,
			0,
		); err != nil {
			t.Error(err)
			return
		}
		var ignored any
		_ = wsjson.Read(ctx, conn, &ignored)
		close(serverClosed)
	}))
	defer server.Close()

	client, err := convex.New(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "close"})
	if err != nil {
		t.Fatal(err)
	}
	assertLiveCount(t, sub, 0)

	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	_ = client.Close(cancelled)
	select {
	case <-serverClosed:
	case <-time.After(2 * time.Second):
		t.Fatal("cancelled Close did not initiate WebSocket shutdown")
	}
	select {
	case _, ok := <-sub.Updates():
		if ok {
			t.Fatal("subscription remained open after cancelled Close")
		}
	case <-time.After(time.Second):
		t.Fatal("subscription did not close after cancelled Close")
	}
}

func sendTransition(
	ctx context.Context,
	conn *websocket.Conn,
	startQuerySet uint32,
	endQuerySet uint32,
	startTS string,
	endTS string,
	queryID uint32,
	count int,
) error {
	message := map[string]any{
		"type": "Transition",
		"startVersion": map[string]any{
			"querySet": startQuerySet,
			"identity": 0,
			"ts":       startTS,
		},
		"endVersion": map[string]any{
			"querySet": endQuerySet,
			"identity": 0,
			"ts":       endTS,
		},
		"modifications": []any{map[string]any{
			"type":     "QueryUpdated",
			"queryId":  queryID,
			"value":    map[string]any{"count": count},
			"logLines": []string{},
			"journal":  nil,
		}},
	}
	return wsjson.Write(ctx, conn, message)
}

func assertLiveCount(t *testing.T, sub *convex.Subscription, expected int) {
	t.Helper()
	select {
	case update := <-sub.Updates():
		if update.Err != nil {
			t.Fatal(update.Err)
		}
		var value struct {
			Count int `json:"count"`
		}
		if err := json.Unmarshal(update.Value, &value); err != nil {
			t.Fatal(err)
		}
		if value.Count != expected {
			t.Fatalf("count = %d, want %d", value.Count, expected)
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for count %d", expected)
	}
}
