package convex

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestInvalidFramesDoNotResetReconnectBackoff(t *testing.T) {
	reconnectDelays := make(chan time.Duration, 8)
	var connections uint32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.CloseNow()
		ctx := r.Context()
		var connect wireConnect
		if err := wsjson.Read(ctx, conn, &connect); err != nil {
			return
		}
		var add wireModifyQuerySet
		if err := wsjson.Read(ctx, conn, &add); err != nil {
			return
		}
		current := atomic.AddUint32(&connections, 1)
		if current == 1 {
			_ = conn.Write(ctx, websocket.MessageText, []byte(`{"type":`))
			return
		}
		if current == 2 {
			invalidTransition := wireTransition{
				Type:         "Transition",
				StartVersion: zeroStateVersion(),
				EndVersion: wireStateVersion{
					QuerySet: 1,
					Identity: 0,
					TS:       "AQAAAAAAAAA=",
				},
				Modifications: []wireStateModification{{Type: "UnknownModification"}},
			}
			if err := wsjson.Write(ctx, conn, invalidTransition); err != nil {
				t.Error(err)
			}
			return
		}
		if current == 3 {
			queryID := add.Modifications[0].QueryID
			transition := wireTransition{
				Type:         "Transition",
				StartVersion: zeroStateVersion(),
				EndVersion: wireStateVersion{
					QuerySet: 1,
					Identity: 0,
					TS:       "AQAAAAAAAAA=",
				},
				Modifications: []wireStateModification{{
					Type:    "QueryUpdated",
					QueryID: queryID,
					Value:   []byte(`{"count":0}`),
				}},
			}
			if err := wsjson.Write(ctx, conn, transition); err != nil {
				t.Error(err)
				return
			}
			_ = conn.Write(ctx, websocket.MessageText, []byte(`{"type":`))
			return
		}
		<-ctx.Done()
	}))
	defer server.Close()

	manager, err := newLiveManagerWithHooks(server.URL, "go-test", &liveManagerHooks{
		reconnectScheduled: func(delay time.Duration) {
			select {
			case reconnectDelays <- delay:
			default:
			}
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer manager.close(context.Background())
	if _, err := manager.subscribe(context.Background(), "demo:state", []byte(`{"room":"backoff"}`)); err != nil {
		t.Fatal(err)
	}

	want := []time.Duration{
		0,
		initialReconnectBackoff,
		2 * initialReconnectBackoff,
		initialReconnectBackoff,
	}
	for index, expected := range want {
		select {
		case actual := <-reconnectDelays:
			if actual != expected {
				t.Fatalf("reconnect delay %d = %s, want %s", index, actual, expected)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("timed out waiting for reconnect delay %d", index)
		}
	}
}
