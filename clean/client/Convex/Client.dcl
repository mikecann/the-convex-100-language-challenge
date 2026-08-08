definition module Convex.Client

// The public native Clean client for Convex. HTTP query/mutation/action
// calls (Convex.HTTP) and the pinned `/api/sync` Live WebSocket profile
// (Convex.Live) are implemented directly in this client — OpenSSL is
// reached only for the TLS record layer's own C ABI (Convex.TLS), and no
// other Convex client, runtime, or command-line tool is ever shelled out
// to. This module is the one place a user of this client needs to import:
// it wires the endpoint, auth token, and a lazily-created Live manager
// together, matching this project's other native clients' top-level
// client module (see `hare/client/convex.ha`).

from StdMaybe import :: Maybe
from Convex.Result import :: Result
from Convex.Wire import :: JSON
from Convex.HTTP import :: CallResult
from Convex.Live import :: SyncEvent

:: Client

// Creates a client for one Convex deployment URL. The URL's scheme selects
// plain or TLS transport for both HTTP calls and any later Live
// subscription.
clientInit :: !String !*World -> (!Result Client, !*World)

// Every call after this one carries `Authorization: Bearer <token>`. Live
// authentication is not implemented yet (see the README's limitations);
// this only affects `clientCall`.
clientSetAuth :: !String !Client -> Client

clientClose :: !Client !*World -> *World

// Calls one Convex query, mutation, or action over the documented JSON
// HTTP API. `args` must be a JSON object; ownership stays with the caller.
// Bounded by a fixed, generous deadline (10 seconds), matching this
// project's other native clients' HTTP call.
clientCall :: !String !String !JSON !Client !*World -> (!Result CallResult, !*World)

// Registers (or replaces) one Live subscription under `subscriptionId`.
// Brings up the Live connection on the first subscription.
clientSubscribe :: !String !String !JSON !Client !*World -> (!Result Client, !*World)

clientUnsubscribe :: !String !Client !*World -> (!Result Client, !*World)

// The adapter-only `debugDisconnect` command; not part of the educational
// client API.
clientDebugDisconnect :: !Client !*World -> (!Result Client, !*World)

// Advances the Live connection by at most one step. See `Convex.Live`'s
// `liveStep` for the full contract; a `Client` with no active Live
// subscription yet always returns `Nothing` immediately.
clientStep :: !Int !Client !*World -> (!Maybe SyncEvent, !Client, !*World)

clientConnectionCount :: !Client -> Int
clientLastCloseReason :: !Client -> String
