//go:build convexadapter

package convex_test

import (
	"context"
	"crypto/sha1"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	convex "github.com/mikecann/100-convex-clients/go/client"
)

const websocketAcceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

func TestPartialFrameStallBoundsCloseAndReconnect(t *testing.T) {
	t.Run("close", func(t *testing.T) {
		partialSent := make(chan struct{})
		peerClosed := make(chan struct{})
		errorsSeen := make(chan error, 1)
		server := newStalledFrameServer(t, func(connection net.Conn, connectionNumber int) {
			if connectionNumber != 1 {
				return
			}
			if err := writePartialTransition(connection); err != nil {
				errorsSeen <- err
				return
			}
			close(partialSent)
			waitForPeerClose(connection, peerClosed, errorsSeen)
		})
		defer server.Close()

		client, err := convex.New(server.URL)
		if err != nil {
			t.Fatal(err)
		}
		sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "partial-close"})
		if err != nil {
			t.Fatal(err)
		}
		waitForSignal(t, partialSent, time.Second, "partial frame")
		assertNoLiveUpdate(t, sub, 100*time.Millisecond)

		closeContext, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		started := time.Now()
		if err := client.Close(closeContext); err != nil {
			t.Fatalf("Close returned an error: %v", err)
		}
		if elapsed := time.Since(started); elapsed >= time.Second {
			t.Fatalf("Close exceeded explicit one-second deadline: %s", elapsed)
		}
		waitForSignal(t, peerClosed, time.Second, "stalled peer close")
		assertNoTestServerError(t, errorsSeen)
	})

	t.Run("reconnect", func(t *testing.T) {
		partialSent := make(chan struct{})
		peerClosed := make(chan struct{})
		secondFrameSent := make(chan struct{})
		secondPeerClosed := make(chan struct{})
		errorsSeen := make(chan error, 1)
		server := newStalledFrameServer(t, func(connection net.Conn, connectionNumber int) {
			switch connectionNumber {
			case 1:
				if err := writePartialTransition(connection); err != nil {
					errorsSeen <- err
					return
				}
				close(partialSent)
				waitForPeerClose(connection, peerClosed, errorsSeen)
			case 2:
				if err := writeRawServerFrame(connection, true, 0x1, completeTransition(1)); err != nil {
					errorsSeen <- err
					return
				}
				close(secondFrameSent)
				waitForPeerClose(connection, secondPeerClosed, errorsSeen)
			}
		})
		defer server.Close()

		client, err := convex.New(server.URL)
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close(context.Background())
		sub, err := client.Subscribe(context.Background(), "demo:state", map[string]any{"room": "partial-reconnect"})
		if err != nil {
			t.Fatal(err)
		}
		waitForSignal(t, partialSent, time.Second, "partial frame")
		assertNoLiveUpdate(t, sub, 100*time.Millisecond)

		disconnectDone := make(chan error, 1)
		go func() { disconnectDone <- client.DebugDisconnectForAdapter() }()
		select {
		case err := <-disconnectDone:
			if err != nil {
				t.Fatalf("debugDisconnect returned an error: %v", err)
			}
		case <-time.After(time.Second):
			t.Fatal("debugDisconnect exceeded explicit one-second deadline")
		}
		waitForSignal(t, peerClosed, time.Second, "stalled peer close after disconnect")
		waitForSignal(t, secondFrameSent, 3*time.Second, "reconnect frame")
		assertLiveCount(t, sub, 1)
		assertNoLiveUpdate(t, sub, 100*time.Millisecond)
		closeContext, cancel := context.WithTimeout(context.Background(), time.Second)
		if err := client.Close(closeContext); err != nil {
			cancel()
			t.Fatalf("reconnected client Close returned an error: %v", err)
		}
		cancel()
		waitForSignal(t, secondPeerClosed, time.Second, "reconnected peer close")
		assertNoTestServerError(t, errorsSeen)
	})
}

func newStalledFrameServer(t *testing.T, handle func(net.Conn, int)) *httptest.Server {
	t.Helper()
	var connections atomic.Int32
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		connection, err := acceptRawWebSocket(w, r)
		if err != nil {
			t.Error(err)
			return
		}
		current := int(connections.Add(1))
		go func() {
			defer connection.Close()
			handle(connection, current)
		}()
	}))
}

func acceptRawWebSocket(w http.ResponseWriter, r *http.Request) (net.Conn, error) {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		return nil, fmt.Errorf("test server does not support WebSocket hijacking")
	}
	connection, buffered, err := hijacker.Hijack()
	if err != nil {
		return nil, err
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		connection.Close()
		return nil, fmt.Errorf("client omitted Sec-WebSocket-Key")
	}
	accept := sha1.Sum([]byte(key + websocketAcceptGUID))
	acceptValue := base64.StdEncoding.EncodeToString(accept[:])
	if _, err := fmt.Fprintf(
		buffered,
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		acceptValue,
	); err != nil {
		connection.Close()
		return nil, err
	}
	if err := buffered.Flush(); err != nil {
		connection.Close()
		return nil, err
	}
	return connection, nil
}

func writePartialTransition(connection net.Conn) error {
	payload := completeTransition(0)
	partialLength := len(payload) / 2
	if err := writeRawServerFrame(connection, true, 0x9, []byte("keepalive")); err != nil {
		return err
	}
	// The header declares the complete JSON payload, but the peer sends only
	// its prefix. The parser must retain those consumed bytes until the socket
	// is closed rather than restarting at a false frame boundary.
	return writePartialRawServerFrame(connection, true, 0x1, payload, partialLength)
}

func writeRawServerFrame(connection net.Conn, final bool, opcode byte, payload []byte) error {
	if err := writeNetAll(connection, rawServerFrameHeader(final, opcode, len(payload))); err != nil {
		return err
	}
	return writeNetAll(connection, payload)
}

func writePartialRawServerFrame(
	connection net.Conn,
	final bool,
	opcode byte,
	payload []byte,
	partialLength int,
) error {
	if err := writeNetAll(connection, rawServerFrameHeader(final, opcode, len(payload))); err != nil {
		return err
	}
	return writeNetAll(connection, payload[:partialLength])
}

func rawServerFrameHeader(final bool, opcode byte, payloadLength int) []byte {
	first := opcode & 0x0f
	if final {
		first |= 0x80
	}
	header := []byte{first}
	switch length := payloadLength; {
	case length < 126:
		header = append(header, byte(length))
	case length <= 65535:
		header = append(header, 126, byte(length>>8), byte(length))
	default:
		header = append(header, 127,
			byte(uint64(length)>>56), byte(uint64(length)>>48),
			byte(uint64(length)>>40), byte(uint64(length)>>32),
			byte(uint64(length)>>24), byte(uint64(length)>>16),
			byte(uint64(length)>>8), byte(uint64(length)),
		)
	}
	return header
}

func writeNetAll(connection net.Conn, value []byte) error {
	for len(value) > 0 {
		written, err := connection.Write(value)
		if err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		value = value[written:]
	}
	return nil
}

func completeTransition(count int) []byte {
	return []byte(fmt.Sprintf(
		`{"type":"Transition","startVersion":{"querySet":0,"identity":0,"ts":"AAAAAAAAAAA="},"endVersion":{"querySet":1,"identity":0,"ts":"AQAAAAAAAAA="},"modifications":[{"type":"QueryUpdated","queryId":0,"value":{"count":%d},"logLines":[]}]}`,
		count,
	))
}

func waitForPeerClose(connection net.Conn, closed chan<- struct{}, errorsSeen chan<- error) {
	if err := connection.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		errorsSeen <- err
		return
	}
	buffer := make([]byte, 4096)
	for {
		if _, err := connection.Read(buffer); err != nil {
			var timeoutError net.Error
			if errors.As(err, &timeoutError) && timeoutError.Timeout() {
				errorsSeen <- fmt.Errorf("peer close deadline exceeded: %w", err)
				return
			}
			if closed != nil {
				close(closed)
			}
			return
		}
	}
}

func waitForSignal(t *testing.T, signal <-chan struct{}, timeout time.Duration, name string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(timeout):
		t.Fatalf("timed out waiting for %s", name)
	}
}

func assertNoLiveUpdate(t *testing.T, sub *convex.Subscription, timeout time.Duration) {
	t.Helper()
	select {
	case update := <-sub.Updates():
		t.Fatalf("stalled partial frame produced an update: %+v", update)
	case <-time.After(timeout):
	}
}

func assertNoTestServerError(t *testing.T, errorsSeen <-chan error) {
	t.Helper()
	select {
	case err := <-errorsSeen:
		t.Fatal(err)
	default:
	}
}
