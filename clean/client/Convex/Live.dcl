definition module Convex.Live

// Convex's pinned `/api/sync` Live profile (convex-rs-0.10.4-unversioned-sync):
// the Connect/ModifyQuerySet/Transition WebSocket state machine, built on
// Convex.WebSocket. A single call stack owns the connection at all times —
// there is no second thread or fiber reading or writing it, and every
// function here is an ordinary pure-ish transform threading `LiveManager`
// and `*World` explicitly — so the "one worker, exclusive ownership" rule
// holds structurally rather than by convention, matching this project's
// other native clients (see `hare/client/live.ha`, which this module
// mirrors closely). `liveStep` is a demand-driven step function, not a
// background thread with its own queue: at most one already-decoded event
// is held in `lmPending` between calls, so nothing here can grow
// unboundedly while a caller is slow to drain it.

from StdMaybe import :: Maybe
from Convex.Result import :: Result
from Convex.Deadline import :: Deadline
from Convex.Wire import :: JSON
from Convex.HTTP import :: Endpoint

:: SyncEventKind = SeUpdated | SeFailed

:: SyncEvent =
	{ seSubscriptionId :: !String
	, seKind :: !SyncEventKind
	, seValue :: !Maybe JSON
	, seErrorName :: !String
	, seErrorMessage :: !String
	, seErrorData :: !Maybe JSON
	, seLogs :: !Maybe JSON
	}

:: LiveManager

// Creates a manager with no active subscriptions and no connection yet;
// the first `liveSubscribe` brings up the socket.
liveManagerNew :: !Endpoint !(Maybe String) -> LiveManager

// Registers (or replaces) one subscription under `subscriptionId`. A prior
// subscription under the same ID is retired first — its Remove is sent, if
// connected — so an unsubscribe acknowledgement can never be crossed by a
// stale update from the query it replaced. Connects if this is the first
// subscription; a connect failure here is a real error. Adding a query
// while already connected sends best-effort (a send failure closes the
// socket rather than failing this call — the next `liveStep` reconnects).
liveSubscribe :: !String !String !JSON !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)

// Retiring a subscription always succeeds locally even if telling the
// server fails (which just closes the socket instead; a fresh connect
// replays the correct remaining Add set).
liveUnsubscribe :: !String !LiveManager !Deadline !*World -> (!Result LiveManager, !*World)

// The adapter-only `debugDisconnect` command: tears down the socket
// immediately, leaving active subscriptions registered so the next
// successful connect replays their Add. Not part of the educational
// client API.
liveDebugDisconnect :: !LiveManager !*World -> (!Result LiveManager, !*World)

// Advances the Live connection by at most one step: reconnecting if there
// are active subscriptions but no socket, or waiting up to
// `pollTimeoutMs` for the next frame and handling it. Returns the next
// already-decoded event if one is queued, or `Nothing` if this step
// produced nothing to report within the timeout — a normal outcome, not
// an error. Connection-level failures (a stalled peer, a protocol
// violation) are not returned as a hard error to the caller: they close
// the socket and are published as a `FunctionError`-shaped event per
// active subscription instead, exactly like a real function failure, so a
// caller looping on this function never needs a second failure channel.
liveStep :: !Int !LiveManager !*World -> (!Maybe SyncEvent, !LiveManager, !*World)

// Closes the connection, if any, without touching `lmActive`/`lmPending`
// bookkeeping — for final client shutdown, not for a mid-session
// reconnect (that's `liveDebugDisconnect`/the internal close-then-retry
// paths inside `liveStep`).
liveStop :: !LiveManager !*World -> *World

liveConnectionCount :: !LiveManager -> Int
liveLastCloseReason :: !LiveManager -> String
// The most recently observed Live timestamp, base64-encoded exactly as the
// wire protocol represents it (for a future `maxObservedTimestamp` resume
// on reconnect) — `Nothing` before any Transition has ever been seen.
liveMaxObservedTimestampBase64 :: !LiveManager -> Maybe String
