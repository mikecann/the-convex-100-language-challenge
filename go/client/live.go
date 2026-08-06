package convex

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

const (
	initialReconnectBackoff = 100 * time.Millisecond
	maximumReconnectBackoff = 15 * time.Second
	serverInactivityLimit   = 30 * time.Second
	serverInactivityCheck   = 5 * time.Second
	writeTimeout            = 5 * time.Second
	websocketReadLimit      = 2 << 20
)

// Update is a new value or query failure for a Live subscription.
type Update struct {
	Value    json.RawMessage
	Err      error
	LogLines []string
}

// Subscription receives reactive query updates. Close is idempotent.
type Subscription struct {
	manager   *liveManager
	queryID   uint32
	updates   <-chan Update
	closeOnce sync.Once
	closeErr  error
}

// Updates returns a channel closed when the subscription or client closes.
func (s *Subscription) Updates() <-chan Update { return s.updates }

// Close stops the subscription.
func (s *Subscription) Close() error {
	s.closeOnce.Do(func() {
		s.closeErr = s.manager.unsubscribe(s.queryID)
	})
	return s.closeErr
}

// Subscribe starts a reactive query through the pinned convex-rs 0.10.4
// unversioned /api/sync profile.
func (c *Client) Subscribe(ctx context.Context, path string, args any) (*Subscription, error) {
	if path == "" {
		return nil, fmt.Errorf("Convex function path is required")
	}
	encodedArgs, err := marshalArgs(args)
	if err != nil {
		return nil, err
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, ErrClosed
	}
	if c.live == nil {
		c.live, err = newLiveManager(c.deploymentURL, c.clientVersion)
		if err != nil {
			c.mu.Unlock()
			return nil, err
		}
	}
	manager := c.live
	c.mu.Unlock()
	return manager.subscribe(ctx, path, encodedArgs)
}

// Close shuts down Live networking and prevents future operations.
func (c *Client) Close(ctx context.Context) error {
	c.mu.Lock()
	c.closed = true
	manager := c.live
	c.mu.Unlock()
	if manager == nil {
		return nil
	}
	return manager.close(ctx)
}

type liveManager struct {
	wsURL         string
	clientVersion string
	commands      chan any
	closeSignal   chan struct{}
	closeOnce     sync.Once
	done          chan struct{}
}

type liveSubscription struct {
	queryID uint32
	path    string
	args    json.RawMessage
	updates chan Update
}

type deliveredUpdate struct {
	value   json.RawMessage
	success bool
}

type subscribeCommand struct {
	ctx  context.Context
	path string
	args json.RawMessage
	resp chan subscribeResponse
}

type subscribeResponse struct {
	sub *Subscription
	err error
}

type unsubscribeCommand struct {
	queryID uint32
	resp    chan error
}

type debugDisconnectCommand struct {
	resp chan error
}

type socketEvent struct {
	generation uint64
	raw        json.RawMessage
	err        error
}

func newLiveManager(deploymentURL, clientVersion string) (*liveManager, error) {
	u, err := url.Parse(deploymentURL)
	if err != nil {
		return nil, fmt.Errorf("parse Convex deployment URL for Live: %w", err)
	}
	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	default:
		return nil, fmt.Errorf("Convex deployment URL must use http or https")
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/api/sync"
	u.RawQuery = ""
	u.Fragment = ""
	m := &liveManager{
		wsURL:         u.String(),
		clientVersion: clientVersion,
		commands:      make(chan any),
		closeSignal:   make(chan struct{}),
		done:          make(chan struct{}),
	}
	go m.run()
	return m, nil
}

func (m *liveManager) subscribe(ctx context.Context, path string, args json.RawMessage) (*Subscription, error) {
	resp := make(chan subscribeResponse, 1)
	cmd := subscribeCommand{ctx: ctx, path: path, args: cloneRaw(args), resp: resp}
	select {
	case m.commands <- cmd:
	case <-m.done:
		return nil, ErrClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	select {
	case result := <-resp:
		return result.sub, result.err
	case <-m.done:
		return nil, ErrClosed
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (m *liveManager) unsubscribe(queryID uint32) error {
	resp := make(chan error, 1)
	select {
	case m.commands <- unsubscribeCommand{queryID: queryID, resp: resp}:
	case <-m.done:
		return nil
	}
	select {
	case err := <-resp:
		return err
	case <-m.done:
		return nil
	}
}

func (m *liveManager) close(ctx context.Context) error {
	// Initiating shutdown must not depend on the caller's context. The context
	// only bounds how long this caller waits for the manager to finish.
	m.closeOnce.Do(func() { close(m.closeSignal) })
	select {
	case <-m.done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *liveManager) debugDisconnect() error {
	resp := make(chan error, 1)
	select {
	case m.commands <- debugDisconnectCommand{resp: resp}:
	case <-m.done:
		return ErrClosed
	}
	select {
	case err := <-resp:
		return err
	case <-m.done:
		return ErrClosed
	}
}

func (m *liveManager) run() {
	defer close(m.done)
	rootCtx, cancel := context.WithCancel(context.Background())
	defer cancel()

	active := make(map[uint32]*liveSubscription)
	remoteResults := make(map[uint32]Update)
	incoming := make(chan socketEvent, 32)
	nextQueryID := uint32(0)
	querySetVersion := uint32(0)
	remoteVersion := zeroStateVersion()
	maxObservedTimestamp := ""
	lastDelivered := make(map[uint32]deliveredUpdate)
	connectionCount := uint32(0)
	lastCloseReason := "InitialConnect"
	nextBackoff := initialReconnectBackoff
	lastServerResponse := time.Time{}
	generation := uint64(0)
	var conn *websocket.Conn

	var reconnectTimer *time.Timer
	var reconnect <-chan time.Time
	scheduleReconnect := func(delay time.Duration) {
		if reconnectTimer != nil {
			if !reconnectTimer.Stop() {
				select {
				case <-reconnectTimer.C:
				default:
				}
			}
		}
		reconnectTimer = time.NewTimer(delay)
		reconnect = reconnectTimer.C
	}
	stopReconnect := func() {
		if reconnectTimer != nil {
			reconnectTimer.Stop()
		}
		reconnect = nil
	}

	closeConnection := func(reason string, schedule bool) {
		if conn != nil {
			_ = conn.CloseNow()
			conn = nil
			connectionCount++
		}
		lastCloseReason = reason
		querySetVersion = 0
		remoteVersion = zeroStateVersion()
		remoteResults = make(map[uint32]Update)
		if schedule && len(active) > 0 {
			scheduleReconnect(nextBackoff)
			nextBackoff *= 2
			if nextBackoff > maximumReconnectBackoff {
				nextBackoff = maximumReconnectBackoff
			}
		}
	}

	writeMessage := func(value any) error {
		if conn == nil {
			return errors.New("WebSocket is not connected")
		}
		ctx, writeCancel := context.WithTimeout(rootCtx, writeTimeout)
		defer writeCancel()
		if err := wsjson.Write(ctx, conn, value); err != nil {
			return &TransportError{Operation: "live write", Err: err}
		}
		return nil
	}

	startReader := func(ws *websocket.Conn, currentGeneration uint64) {
		go func() {
			for {
				var raw json.RawMessage
				err := wsjson.Read(rootCtx, ws, &raw)
				event := socketEvent{generation: currentGeneration, raw: cloneRaw(raw), err: err}
				select {
				case incoming <- event:
				case <-rootCtx.Done():
					return
				}
				if err != nil {
					return
				}
			}
		}()
	}

	connect := func() error {
		dialCtx, dialCancel := context.WithTimeout(rootCtx, 10*time.Second)
		defer dialCancel()
		headers := make(http.Header)
		headers.Set("Convex-Client", m.clientVersion)
		ws, _, err := websocket.Dial(dialCtx, m.wsURL, &websocket.DialOptions{HTTPHeader: headers})
		if err != nil {
			return &TransportError{Operation: "live dial", Err: err}
		}
		ws.SetReadLimit(websocketReadLimit)
		conn = ws
		generation++
		remoteVersion = zeroStateVersion()
		remoteResults = make(map[uint32]Update)
		querySetVersion = 0
		lastServerResponse = time.Now()

		connectMessage := wireConnect{
			Type:                 "Connect",
			SessionID:            newSessionID(),
			ConnectionCount:      connectionCount,
			LastCloseReason:      lastCloseReason,
			MaxObservedTimestamp: maxObservedTimestamp,
			ClientTS:             0,
		}
		if err := writeMessage(connectMessage); err != nil {
			_ = ws.CloseNow()
			conn = nil
			return err
		}

		ids := make([]int, 0, len(active))
		for id := range active {
			ids = append(ids, int(id))
		}
		sort.Ints(ids)
		modifications := make([]wireQueryModification, 0, len(ids))
		for _, numericID := range ids {
			sub := active[uint32(numericID)]
			modifications = append(modifications, wireQueryModification{
				Type:    "Add",
				QueryID: sub.queryID,
				UDFPath: sub.path,
				Args:    []json.RawMessage{cloneRaw(sub.args)},
			})
		}
		if len(modifications) > 0 {
			message := wireModifyQuerySet{
				Type:          "ModifyQuerySet",
				BaseVersion:   0,
				NewVersion:    1,
				Modifications: modifications,
			}
			if err := writeMessage(message); err != nil {
				_ = ws.CloseNow()
				conn = nil
				return err
			}
			querySetVersion = 1
		}
		startReader(ws, generation)
		return nil
	}

	deliver := func(sub *liveSubscription, update Update) {
		update.Value = cloneRaw(update.Value)
		select {
		case sub.updates <- update:
		default:
			// Reactive queries represent current state, so a slow subscriber gets
			// the newest value instead of blocking the protocol manager.
			select {
			case <-sub.updates:
			default:
			}
			select {
			case sub.updates <- update:
			default:
			}
		}
	}

	publishProtocolError := func(err error) {
		for _, sub := range active {
			deliver(sub, Update{Err: err})
		}
	}

	handleTransition := func(raw json.RawMessage) error {
		var transition wireTransition
		if err := json.Unmarshal(raw, &transition); err != nil {
			return &ProtocolError{Message: "decode Transition: " + err.Error()}
		}
		if transition.StartVersion != remoteVersion {
			return &ProtocolError{Message: fmt.Sprintf(
				"Transition start version %+v does not match local version %+v",
				transition.StartVersion,
				remoteVersion,
			)}
		}

		changed := make(map[uint32]Update)
		for _, modification := range transition.Modifications {
			switch modification.Type {
			case "QueryUpdated":
				update := Update{
					Value:    cloneRaw(modification.Value),
					LogLines: append([]string(nil), modification.LogLines...),
				}
				remoteResults[modification.QueryID] = update
				if previous, ok := lastDelivered[modification.QueryID]; ok && previous.success &&
					bytes.Equal(previous.value, update.Value) {
					continue
				}
				changed[modification.QueryID] = update
			case "QueryFailed":
				queryError := &FunctionError{
					Operation: "query",
					Message:   modification.ErrorMessage,
					Data:      cloneRaw(modification.ErrorData),
					LogLines:  append([]string(nil), modification.LogLines...),
				}
				update := Update{Err: queryError, LogLines: queryError.LogLines}
				remoteResults[modification.QueryID] = update
				changed[modification.QueryID] = update
			case "QueryRemoved":
				delete(remoteResults, modification.QueryID)
				delete(lastDelivered, modification.QueryID)
			default:
				return &ProtocolError{Message: "unknown Transition modification " + modification.Type}
			}
		}

		// Commit the complete transition before notifying any subscriber.
		remoteVersion = transition.EndVersion
		if _, err := decodeTimestamp(transition.EndVersion.TS); err != nil {
			return &ProtocolError{Message: "invalid Transition end timestamp: " + err.Error()}
		}
		if maxObservedTimestamp == "" {
			maxObservedTimestamp = transition.EndVersion.TS
		} else {
			comparison, err := compareTimestamps(transition.EndVersion.TS, maxObservedTimestamp)
			if err != nil {
				return &ProtocolError{Message: "invalid Transition end timestamp: " + err.Error()}
			}
			if comparison > 0 {
				maxObservedTimestamp = transition.EndVersion.TS
			}
		}
		ids := make([]int, 0, len(changed))
		for id := range changed {
			ids = append(ids, int(id))
		}
		sort.Ints(ids)
		for _, numericID := range ids {
			id := uint32(numericID)
			if sub, ok := active[id]; ok {
				update := changed[id]
				deliver(sub, update)
				lastDelivered[id] = deliveredUpdate{
					value:   cloneRaw(update.Value),
					success: update.Err == nil,
				}
			}
		}
		return nil
	}

	inactivityTicker := time.NewTicker(serverInactivityCheck)
	defer inactivityTicker.Stop()

	for {
		select {
		case <-m.closeSignal:
			stopReconnect()
			cancel()
			if conn != nil {
				_ = conn.Close(websocket.StatusNormalClosure, "client closed")
				conn = nil
			}
			for id, sub := range active {
				close(sub.updates)
				delete(active, id)
			}
			return

		case command := <-m.commands:
			switch cmd := command.(type) {
			case subscribeCommand:
				if err := cmd.ctx.Err(); err != nil {
					cmd.resp <- subscribeResponse{err: err}
					continue
				}
				queryID := nextQueryID
				nextQueryID++
				updates := make(chan Update, 16)
				state := &liveSubscription{
					queryID: queryID,
					path:    cmd.path,
					args:    cloneRaw(cmd.args),
					updates: updates,
				}
				active[queryID] = state
				subscription := &Subscription{
					manager: m,
					queryID: queryID,
					updates: updates,
				}
				cmd.resp <- subscribeResponse{sub: subscription}

				if conn == nil {
					scheduleReconnect(0)
					continue
				}
				message := wireModifyQuerySet{
					Type:        "ModifyQuerySet",
					BaseVersion: querySetVersion,
					NewVersion:  querySetVersion + 1,
					Modifications: []wireQueryModification{{
						Type:    "Add",
						QueryID: queryID,
						UDFPath: cmd.path,
						Args:    []json.RawMessage{cloneRaw(cmd.args)},
					}},
				}
				if err := writeMessage(message); err != nil {
					closeConnection(err.Error(), true)
					continue
				}
				querySetVersion++

			case unsubscribeCommand:
				sub, ok := active[cmd.queryID]
				if !ok {
					cmd.resp <- nil
					continue
				}
				delete(active, cmd.queryID)
				delete(remoteResults, cmd.queryID)
				close(sub.updates)
				if conn != nil {
					message := wireModifyQuerySet{
						Type:        "ModifyQuerySet",
						BaseVersion: querySetVersion,
						NewVersion:  querySetVersion + 1,
						Modifications: []wireQueryModification{{
							Type:    "Remove",
							QueryID: cmd.queryID,
						}},
					}
					if err := writeMessage(message); err != nil {
						closeConnection(err.Error(), true)
					} else {
						querySetVersion++
					}
				}
				if len(active) == 0 {
					stopReconnect()
				}
				cmd.resp <- nil

			case debugDisconnectCommand:
				if conn == nil {
					cmd.resp <- errors.New("Live WebSocket is not connected")
					continue
				}
				// Retire the socket and schedule reconnect on the owner before
				// acknowledging. This makes the adapter barrier deterministic and
				// prevents a stale reader event from racing the acknowledgement.
				closeConnection("DebugDisconnect", true)
				cmd.resp <- nil

			}

		case <-reconnect:
			reconnect = nil
			if conn != nil || len(active) == 0 {
				continue
			}
			if err := connect(); err != nil {
				lastCloseReason = err.Error()
				connectionCount++
				scheduleReconnect(nextBackoff)
				nextBackoff *= 2
				if nextBackoff > maximumReconnectBackoff {
					nextBackoff = maximumReconnectBackoff
				}
			}

		case event := <-incoming:
			if event.generation != generation || conn == nil {
				continue
			}
			if event.err != nil {
				closeConnection(event.err.Error(), true)
				continue
			}
			lastServerResponse = time.Now()
			nextBackoff = initialReconnectBackoff
			var envelope wireEnvelope
			if err := json.Unmarshal(event.raw, &envelope); err != nil {
				protocolErr := &ProtocolError{Message: "decode server message: " + err.Error()}
				publishProtocolError(protocolErr)
				closeConnection(protocolErr.Error(), true)
				continue
			}
			switch envelope.Type {
			case "Transition":
				if err := handleTransition(event.raw); err != nil {
					publishProtocolError(err)
					closeConnection(err.Error(), true)
				}
			case "Ping", "MutationResponse", "ActionResponse":
				// The pilot does not send WebSocket mutations or actions.
			case "FatalError", "AuthError":
				var serverErr wireServerError
				if err := json.Unmarshal(event.raw, &serverErr); err != nil {
					serverErr.Error = err.Error()
				}
				protocolErr := &ProtocolError{Message: envelope.Type + ": " + serverErr.Error}
				publishProtocolError(protocolErr)
				closeConnection(protocolErr.Error(), true)
			case "TransitionChunk":
				protocolErr := &ProtocolError{Message: "TransitionChunk assembly is not implemented by the Go pilot"}
				publishProtocolError(protocolErr)
				closeConnection(protocolErr.Error(), true)
			default:
				protocolErr := &ProtocolError{Message: "unknown server message " + envelope.Type}
				publishProtocolError(protocolErr)
				closeConnection(protocolErr.Error(), true)
			}

		case <-inactivityTicker.C:
			if conn != nil && time.Since(lastServerResponse) > serverInactivityLimit {
				closeConnection("InactiveServer", true)
			}
		}
	}
}

func newSessionID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		panic("crypto/rand failed while creating Convex session ID: " + err.Error())
	}
	raw[6] = (raw[6] & 0x0f) | 0x40
	raw[8] = (raw[8] & 0x3f) | 0x80
	encoded := make([]byte, 36)
	hex.Encode(encoded[0:8], raw[0:4])
	encoded[8] = '-'
	hex.Encode(encoded[9:13], raw[4:6])
	encoded[13] = '-'
	hex.Encode(encoded[14:18], raw[6:8])
	encoded[18] = '-'
	hex.Encode(encoded[19:23], raw[8:10])
	encoded[23] = '-'
	hex.Encode(encoded[24:36], raw[10:16])
	return string(encoded)
}
