//go:build convexadapter

package convex_test

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	convex "github.com/mikecann/100-convex-clients/go/client"
)

func TestReconnectSuppressesOnlyFirstUnchangedRehydration(t *testing.T) {
	t.Parallel()
	rehydrated := make(chan struct{})
	sendRepeatedValue := make(chan struct{})
	var connections uint32
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
			return
		}
		var add testWireMessage
		if err := wsjson.Read(ctx, conn, &add); err != nil {
			return
		}
		current := atomic.AddUint32(&connections, 1)
		queryID := add.Modifications[0].QueryID
		endTimestamp := "AQAAAAAAAAA="
		if current == 2 {
			endTimestamp = "AgAAAAAAAAA="
		}
		if err := sendTransition(ctx, conn, 0, 1, "AAAAAAAAAAA=", endTimestamp, queryID, 0); err != nil {
			t.Error(err)
			return
		}
		if current == 1 {
			<-ctx.Done()
			return
		}
		close(rehydrated)
		<-sendRepeatedValue
		message := map[string]any{
			"type": "Transition",
			"startVersion": map[string]any{
				"querySet": 1,
				"identity": 0,
				"ts":       endTimestamp,
			},
			"endVersion": map[string]any{
				"querySet": 1,
				"identity": 0,
				"ts":       "AwAAAAAAAAA=",
			},
			"modifications": []any{map[string]any{
				"type":     "QueryUpdated",
				"queryId":  queryID,
				"value":    map[string]any{"count": 0},
				"logLines": []string{"fresh"},
			}},
		}
		if err := wsjson.Write(ctx, conn, message); err != nil {
			t.Error(err)
		}
	}))
	defer server.Close()

	client, err := convex.New(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background())
	sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "same-value"})
	if err != nil {
		t.Fatal(err)
	}
	assertLiveCount(t, sub, 0)
	if err := client.DebugDisconnectForAdapter(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-rehydrated:
	case <-time.After(3 * time.Second):
		t.Fatal("client did not reconnect")
	}
	select {
	case update := <-sub.Updates():
		t.Fatalf("first unchanged rehydration was not suppressed: %+v", update)
	case <-time.After(250 * time.Millisecond):
	}
	close(sendRepeatedValue)
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
		if value.Count != 0 || len(update.LogLines) != 1 || update.LogLines[0] != "fresh" {
			t.Fatalf("later same-value update = %+v, logs = %v", value, update.LogLines)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("later same-value transition was suppressed")
	}
}

func TestDebugDisconnectAcknowledgesAfterReconnectIsScheduled(t *testing.T) {
	t.Parallel()
	connected := make(chan uint32, 6)
	serverUpdates := make(chan int, 5)
	var connections uint32
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
		current := atomic.AddUint32(&connections, 1)
		if connect.ConnectionCount != current-1 {
			t.Errorf("connectionCount = %d, want %d", connect.ConnectionCount, current-1)
		}
		if add.Type != "ModifyQuerySet" || len(add.Modifications) != 1 ||
			add.Modifications[0].Type != "Add" {
			t.Errorf("connection %d did not resend exactly one Add: %+v", current, add)
			return
		}
		queryID := add.Modifications[0].QueryID
		rehydrationTimestamp := testTimestamp(uint64(current*2 - 1))
		rehydratedCount := 0
		if current > 1 {
			rehydratedCount = int(current - 2)
		}
		if err := sendTransition(
			ctx,
			conn,
			0,
			1,
			"AAAAAAAAAAA=",
			rehydrationTimestamp,
			queryID,
			rehydratedCount,
		); err != nil {
			t.Error(err)
			return
		}
		connected <- current
		if current > 1 {
			value := <-serverUpdates
			if err := sendTransition(
				ctx,
				conn,
				1,
				1,
				rehydrationTimestamp,
				testTimestamp(uint64(current*2)),
				queryID,
				value,
			); err != nil {
				t.Error(err)
				return
			}
		}
		<-ctx.Done()
	}))
	defer server.Close()

	client, err := convex.New(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close(context.Background())
	sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "debug"})
	if err != nil {
		t.Fatal(err)
	}
	assertLiveCount(t, sub, 0)
	if first := <-connected; first != 1 {
		t.Fatalf("initial connection = %d, want 1", first)
	}

	for reconnect := 1; reconnect <= 5; reconnect++ {
		if err := client.DebugDisconnectForAdapter(); err != nil {
			t.Fatal(err)
		}
		select {
		case current := <-connected:
			if current != uint32(reconnect+1) {
				t.Fatalf("connection = %d, want %d", current, reconnect+1)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("client did not complete reconnect %d", reconnect)
		}
		select {
		case update := <-sub.Updates():
			t.Fatalf("reconnect %d rehydration was not suppressed: %+v", reconnect, update)
		case <-time.After(100 * time.Millisecond):
		}
		serverUpdates <- reconnect
		assertLiveCount(t, sub, reconnect)
	}
}

func testTimestamp(value uint64) string {
	var encoded [8]byte
	binary.LittleEndian.PutUint64(encoded[:], value)
	return base64.StdEncoding.EncodeToString(encoded[:])
}
