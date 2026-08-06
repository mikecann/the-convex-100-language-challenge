//go:build convexadapter

package convex_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	convex "github.com/mikecann/100-convex-clients/go/client"
)

func TestDebugDisconnectAcknowledgesAfterReconnectIsScheduled(t *testing.T) {
	t.Parallel()
	secondConnected := make(chan struct{})
	allowSecondUpdate := make(chan struct{})
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
		queryID := add.Modifications[0].QueryID
		endTimestamp := "AQAAAAAAAAA="
		if current == 2 {
			endTimestamp = "AgAAAAAAAAA="
		}
		if err := sendTransition(ctx, conn, 0, 1, "AAAAAAAAAAA=", endTimestamp, queryID, 0); err != nil {
			t.Error(err)
			return
		}
		if current == 2 {
			close(secondConnected)
			<-allowSecondUpdate
			if err := sendTransition(ctx, conn, 1, 2, endTimestamp, "AwAAAAAAAAA=", queryID, 1); err != nil {
				t.Error(err)
			}
			return
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

	if err := client.DebugDisconnectForAdapter(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-secondConnected:
	case <-time.After(3 * time.Second):
		t.Fatal("client did not reconnect")
	}
	select {
	case update := <-sub.Updates():
		t.Fatalf("reconnect rehydration was not suppressed: %+v", update)
	case <-time.After(250 * time.Millisecond):
	}
	close(allowSecondUpdate)
	assertLiveCount(t, sub, 1)
}
