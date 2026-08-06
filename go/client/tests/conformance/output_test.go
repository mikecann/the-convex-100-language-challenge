//go:build convexadapter

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	convex "github.com/mikecann/100-convex-clients/go/client"
)

type stoppedWriter struct {
	startedOnce sync.Once
	started     chan struct{}
	release     chan struct{}
}

func newStoppedWriter() *stoppedWriter {
	return &stoppedWriter{
		started: make(chan struct{}),
		release: make(chan struct{}),
	}
}

func (w *stoppedWriter) Write(value []byte) (int, error) {
	w.startedOnce.Do(func() { close(w.started) })
	<-w.release
	return len(value), nil
}

func TestOutputByteBudgetIncludesEncodedPayloadAndOverhead(t *testing.T) {
	writer := newStoppedWriter()
	out := newOutput(writer)
	nearMaximumValue := json.RawMessage(`"` + strings.Repeat("x", (2<<20)-4096) + `"`)
	value := event{
		Type:           "subscription",
		SubscriptionID: "large",
		Value:          nearMaximumValue,
	}
	if err := out.write(value); err != nil {
		t.Fatal(err)
	}
	select {
	case <-writer.started:
	case <-time.After(time.Second):
		t.Fatal("output writer did not block")
	}

	accepted := 1
	for {
		err := out.write(value)
		if errors.Is(err, errOutputBudget) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		accepted++
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	wantCost := len(encoded) + 1 + adapterOutputRecordOverhead
	stats := out.stats()
	if stats.records != accepted {
		t.Fatalf("records = %d, want %d", stats.records, accepted)
	}
	if stats.bytes != accepted*wantCost {
		t.Fatalf("bytes = %d, want %d", stats.bytes, accepted*wantCost)
	}
	if stats.bytes > adapterOutputMaxBytes || adapterOutputMaxBytes >= 128<<20 {
		t.Fatalf("unsafe output budget: queued=%d max=%d", stats.bytes, adapterOutputMaxBytes)
	}
	if out.close(25 * time.Millisecond) {
		t.Fatal("blocked writer unexpectedly flushed")
	}
	close(writer.release)
	if !out.close(time.Second) {
		t.Fatal("output did not finish after writer resumed")
	}
}

func TestOutputCountBudgetBoundsSmallRecords(t *testing.T) {
	writer := newStoppedWriter()
	out := newOutput(writer)
	value := event{ID: "small", Type: "ack"}
	if err := out.write(value); err != nil {
		t.Fatal(err)
	}
	<-writer.started
	for index := 1; index < adapterOutputMaxRecords; index++ {
		if err := out.write(value); err != nil {
			t.Fatalf("record %d: %v", index, err)
		}
	}
	if err := out.write(value); !errors.Is(err, errOutputBudget) {
		t.Fatalf("overflow error = %v, want %v", err, errOutputBudget)
	}
	if stats := out.stats(); stats.records != adapterOutputMaxRecords {
		t.Fatalf("records = %d, want %d", stats.records, adapterOutputMaxRecords)
	}
	out.close(10 * time.Millisecond)
	close(writer.release)
	if !out.close(time.Second) {
		t.Fatal("output did not finish after writer resumed")
	}
}

func TestAdapterCloseIsBoundedWhenOutputReaderStops(t *testing.T) {
	writer := newStoppedWriter()
	commands := strings.NewReader(
		"{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n" +
			"{\"id\":\"close\",\"op\":\"close\"}\n",
	)
	done := make(chan struct{})
	go func() {
		runAdapter(commands, writer)
		close(done)
	}()
	select {
	case <-writer.started:
	case <-time.After(time.Second):
		t.Fatal("adapter did not reach stopped writer")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("stopped output reader stranded adapter close")
	}
	close(writer.release)
}

func TestPausedRelayCannotCrossUnsubscribeAcknowledgement(t *testing.T) {
	assertPausedRelayBarrier(t, false)
}

func TestPausedRelayCannotCrossReplacementAcknowledgement(t *testing.T) {
	assertPausedRelayBarrier(t, true)
}

func assertPausedRelayBarrier(t *testing.T, replace bool) {
	t.Helper()
	var buffer bytes.Buffer
	out := newOutput(&buffer)
	const subscriptionID = "shared-id"
	const oldGeneration = 1
	if err := out.activateRelay(subscriptionID, oldGeneration); err != nil {
		t.Fatal(err)
	}
	paused := make(chan struct{})
	release := make(chan struct{})
	var pauseOnce sync.Once
	hooks := &adapterHooks{afterRelayDequeue: func(_ string, generation uint64) {
		if generation != oldGeneration {
			return
		}
		pauseOnce.Do(func() { close(paused) })
		<-release
	}}
	oldUpdates := make(chan convex.Update, 1)
	oldDone := make(chan struct{})
	go func() {
		relaySubscription(subscriptionID, oldGeneration, oldUpdates, out, hooks)
		close(oldDone)
	}()
	oldUpdates <- convex.Update{Value: json.RawMessage(`{"source":"old"}`)}
	<-paused

	if err := out.invalidateRelay(subscriptionID, oldGeneration); err != nil {
		t.Fatal(err)
	}
	ackID := "unsubscribe"
	if replace {
		const newGeneration = 2
		if err := out.activateRelay(subscriptionID, newGeneration); err != nil {
			t.Fatal(err)
		}
		ackID = "replace"
		if err := out.write(event{ID: ackID, Type: "ack"}); err != nil {
			t.Fatal(err)
		}
		newUpdates := make(chan convex.Update, 1)
		newDone := make(chan struct{})
		go func() {
			relaySubscription(subscriptionID, newGeneration, newUpdates, out, nil)
			close(newDone)
		}()
		newUpdates <- convex.Update{Value: json.RawMessage(`{"source":"new"}`)}
		close(newUpdates)
		<-newDone
	} else if err := out.write(event{ID: ackID, Type: "ack"}); err != nil {
		t.Fatal(err)
	}

	close(release)
	close(oldUpdates)
	<-oldDone
	if !out.close(time.Second) {
		t.Fatal("output did not flush")
	}
	assertNoOldRelayAfterAck(t, buffer.Bytes(), ackID, replace)
}

func assertNoOldRelayAfterAck(t *testing.T, outputBytes []byte, ackID string, expectNew bool) {
	t.Helper()
	decoder := json.NewDecoder(bytes.NewReader(outputBytes))
	ackSeen := false
	newSeen := false
	for {
		var value struct {
			ID    string         `json:"id"`
			Type  string         `json:"type"`
			Value map[string]any `json:"value"`
		}
		if err := decoder.Decode(&value); errors.Is(err, io.EOF) {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		if value.ID == ackID && value.Type == "ack" {
			ackSeen = true
			continue
		}
		if !ackSeen {
			continue
		}
		switch value.Value["source"] {
		case "old":
			t.Fatal("stale relay event crossed acknowledgement")
		case "new":
			newSeen = true
		}
	}
	if !ackSeen {
		t.Fatal("acknowledgement was not emitted")
	}
	if newSeen != expectNew {
		t.Fatalf("new relay observed = %t, want %t", newSeen, expectNew)
	}
}
