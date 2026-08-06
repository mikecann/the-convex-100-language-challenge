//go:build convexadapter

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"
)

const (
	// The shared adapter limit is 128 MiB. Keeping encoded output below 8 MiB,
	// including explicit per-record overhead, leaves room for Live buffers, JSON
	// encoding workspaces, the Go runtime, and the static executable.
	adapterOutputMaxRecords     = 16
	adapterOutputMaxBytes       = 8 << 20
	adapterOutputRecordOverhead = 1024
	adapterOutputCloseTimeout   = 250 * time.Millisecond
)

var (
	errOutputBudget = errors.New("adapter output budget exhausted")
	errOutputClosed = errors.New("adapter output is closed")
)

type outputItemKind uint8

const (
	outputEvent outputItemKind = iota
	outputActivateRelay
	outputInvalidateRelay
)

type outputItem struct {
	kind           outputItemKind
	encoded        []byte
	subscriptionID string
	generation     uint64
	cost           int
}

type outputStats struct {
	records int
	bytes   int
}

// output owns every write to the adapter stream. Producers only enqueue
// bounded, already encoded records, so a stopped controller cannot block the
// command loop or let queued output grow without limit.
type output struct {
	writer io.Writer
	queue  chan outputItem
	stop   chan struct{}
	done   chan struct{}

	mu        sync.Mutex
	accepting bool
	records   int
	bytes     int
	failure   error
	closeOnce sync.Once
}

func newOutput(writer io.Writer) *output {
	o := &output{
		writer:    writer,
		queue:     make(chan outputItem, adapterOutputMaxRecords),
		stop:      make(chan struct{}),
		done:      make(chan struct{}),
		accepting: true,
	}
	go o.run()
	return o
}

func (o *output) write(value event) error {
	return o.enqueueEvent(value, "", 0)
}

func (o *output) writeRelay(value event, subscriptionID string, generation uint64) error {
	return o.enqueueEvent(value, subscriptionID, generation)
}

func (o *output) activateRelay(subscriptionID string, generation uint64) error {
	return o.enqueueControl(outputActivateRelay, subscriptionID, generation)
}

func (o *output) invalidateRelay(subscriptionID string, generation uint64) error {
	return o.enqueueControl(outputInvalidateRelay, subscriptionID, generation)
}

func (o *output) enqueueEvent(value event, subscriptionID string, generation uint64) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if err := o.enqueueErrorLocked(); err != nil {
		return err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return fmt.Errorf("encode adapter event: %w", err)
	}
	encoded = append(encoded, '\n')
	return o.enqueueLocked(outputItem{
		kind:           outputEvent,
		encoded:        encoded,
		subscriptionID: subscriptionID,
		generation:     generation,
		cost:           len(encoded) + adapterOutputRecordOverhead,
	})
}

func (o *output) enqueueControl(
	kind outputItemKind,
	subscriptionID string,
	generation uint64,
) error {
	o.mu.Lock()
	defer o.mu.Unlock()
	if err := o.enqueueErrorLocked(); err != nil {
		return err
	}
	return o.enqueueLocked(outputItem{
		kind:           kind,
		subscriptionID: subscriptionID,
		generation:     generation,
		cost:           adapterOutputRecordOverhead,
	})
}

func (o *output) enqueueErrorLocked() error {
	if !o.accepting {
		return errOutputClosed
	}
	if o.failure != nil {
		return o.failure
	}
	return nil
}

func (o *output) enqueueLocked(item outputItem) error {
	if o.records+1 > adapterOutputMaxRecords || o.bytes+item.cost > adapterOutputMaxBytes {
		return errOutputBudget
	}
	o.records++
	o.bytes += item.cost
	// records cannot exceed the channel capacity, including the record currently
	// owned by the writer, because accounting is released only after processing.
	o.queue <- item
	return nil
}

func (o *output) run() {
	defer close(o.done)
	activeRelays := make(map[string]uint64)
	for {
		select {
		case item := <-o.queue:
			o.process(item, activeRelays)
		case <-o.stop:
			// No producer can enqueue after stop is closed. Drain records already
			// accepted so a cooperative writer still receives the terminal event.
			for {
				select {
				case item := <-o.queue:
					o.process(item, activeRelays)
				default:
					return
				}
			}
		}
	}
}

func (o *output) process(item outputItem, activeRelays map[string]uint64) {
	defer o.release(item.cost)
	switch item.kind {
	case outputActivateRelay:
		activeRelays[item.subscriptionID] = item.generation
		return
	case outputInvalidateRelay:
		if activeRelays[item.subscriptionID] == item.generation {
			delete(activeRelays, item.subscriptionID)
		}
		return
	case outputEvent:
		if item.generation != 0 && activeRelays[item.subscriptionID] != item.generation {
			return
		}
	}

	o.mu.Lock()
	failed := o.failure != nil
	o.mu.Unlock()
	if failed {
		return
	}
	if err := writeAll(o.writer, item.encoded); err != nil {
		o.mu.Lock()
		if o.failure == nil {
			o.failure = fmt.Errorf("write adapter event: %w", err)
			fmt.Fprintln(os.Stderr, o.failure)
		}
		o.mu.Unlock()
	}
}

func writeAll(writer io.Writer, value []byte) error {
	for len(value) > 0 {
		written, err := writer.Write(value)
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

func (o *output) release(cost int) {
	o.mu.Lock()
	o.records--
	o.bytes -= cost
	o.mu.Unlock()
}

func (o *output) stats() outputStats {
	o.mu.Lock()
	defer o.mu.Unlock()
	return outputStats{records: o.records, bytes: o.bytes}
}

// close stops accepting records immediately and waits only for the supplied
// bound. A blocked stdout or TCP peer can delay the output worker, but it can
// never strand adapter shutdown.
func (o *output) close(timeout time.Duration) bool {
	o.closeOnce.Do(func() {
		o.mu.Lock()
		o.accepting = false
		o.mu.Unlock()
		close(o.stop)
	})
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-o.done:
		return true
	case <-timer.C:
		return false
	}
}
