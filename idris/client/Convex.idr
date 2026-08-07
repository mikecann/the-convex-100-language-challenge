||| The educational Convex client for Idris 2.
|||
||| One client owns both transports for a single deployment: the documented
||| JSON HTTP API and the pinned realtime sync socket. Deriving the WebSocket
||| endpoint from the same URL is deliberate, so an example or a test cannot
||| accidentally point queries and subscriptions at different deployments.
|||
||| The client is single-threaded and caller-driven. `nextUpdate` runs the sync
||| owner loop until an update is ready or its budget expires, which keeps
||| ownership of the socket in exactly one place without a background thread.
|||
||| The adapter-only disconnect hook lives in `Convex.Live` and is deliberately
||| not re-exported here: it is test fault injection, not client API.
module Convex

import public Convex.Error
import public Convex.Http
import public Convex.Json
import public Convex.Net
import public Convex.Update

import Convex.Build
import Convex.Codec
import Convex.Live
import Convex.Prim

import Data.IORef

||| A fresh idempotency key. Convex mutations in this demonstration take a
||| `runId`, and repeating one returns the existing state instead of counting
||| twice, so a retry after an ambiguous failure is safe.
export covering
newRunId : IO String
newRunId =
  do bytes <- randomByteList 16
     case bytes of
          Nothing => pure "idris-run-id-unavailable"
          Just values => pure ("idris-" ++ hexEncode values)

||| A handle to one reactive query.
public export
record Subscription where
  constructor MkSubscription
  subscriptionQueryId : Int

export
record Client where
  constructor MkClient
  http : HttpConfig
  live : Live
  token : IORef String

||| Record field projections live in an implicit namespace that stays
||| private regardless of the record's own `export` modifier. The
||| conformance adapter (a different module) needs the underlying `Live`
||| handle directly for fault injection and its owner loop, so this
||| explicit accessor exposes it.
export
clientLive : Client -> Live
clientLive = live

||| How long a whole HTTP call may take, from connect to final body byte.
httpBudgetMs : Int
httpBudgetMs = 15000

||| How long the sync socket may take to connect, handshake, and upgrade.
liveConnectBudgetMs : Int
liveConnectBudgetMs = 10000

||| How long a single WebSocket frame may take once it has started arriving.
liveFrameBudgetMs : Int
liveFrameBudgetMs = 15000

||| Create a client for one deployment. `caFile` is normally empty, which uses
||| the image's system trust store; tests pass a fixture bundle instead.
export covering
newClientWith : (deploymentUrl : String) -> (caFile : String)
             -> IO (Either String Client)
newClientWith deploymentUrl caFile =
  do initialise
     case parseEndpoint deploymentUrl of
          Left problem => pure (Left problem)
          Right target => assemble target
  where
    syncEndpoint : Endpoint -> Endpoint
    syncEndpoint target =
      -- `prefix` is a reserved word in Idris2 (prefix operator fixity
      -- declarations), so the path prefix is bound under a longer name.
      let base = path target
          pathPrefix = if base == "/" then "" else base in
      MkEndpoint (secure target) (host target) (port target) (pathPrefix ++ "/api/sync")

    covering
    assemble : Endpoint -> IO (Either String Client)
    assemble target =
      do let settings = MkLiveConfig (syncEndpoint target) caFile clientVersion
                                     liveConnectBudgetMs liveFrameBudgetMs
                                     64 (4 * 1024 * 1024) 100 8000
         created <- newLive settings
         case created of
              Left problem => pure (Left problem)
              Right manager =>
                do authorization <- newIORef ""
                   pure (Right (MkClient
                                 (MkHttpConfig target caFile clientVersion httpBudgetMs)
                                 manager authorization))

||| Create a client using the image's system trust store.
export covering
newClient : (deploymentUrl : String) -> IO (Either String Client)
newClient deploymentUrl = newClientWith deploymentUrl ""

||| Set, replace, or clear the bearer token. An empty token clears it, and the
||| next call then sends no `Authorization` header at all.
export
setAuth : Client -> String -> IO ()
setAuth client value = writeIORef (token client) value

export covering
query : Client -> String -> Json -> IO (Either ConvexError CallResult)
query client path args =
  do bearer <- readIORef (token client)
     callConvex (http client) bearer "query" path args

export covering
mutation : Client -> String -> Json -> IO (Either ConvexError CallResult)
mutation client path args =
  do bearer <- readIORef (token client)
     callConvex (http client) bearer "mutation" path args

export covering
action : Client -> String -> Json -> IO (Either ConvexError CallResult)
action client path args =
  do bearer <- readIORef (token client)
     callConvex (http client) bearer "action" path args

||| Start a reactive query. The first update arrives through `nextUpdate`.
export covering
subscribe : Client -> String -> Json -> IO (Either ConvexError Subscription)
subscribe client path args =
  do started <- subscribeLive (live client) path args
     pure (map MkSubscription started)

||| Wait for this subscription's next update, running the sync owner loop while
||| it waits. Returns `Nothing` when the budget expires with nothing to deliver.
export covering
nextUpdate : Client -> Subscription -> (budgetMs : Int) -> IO (Maybe LiveUpdate)
nextUpdate client handle budgetMs =
  awaitUpdate (live client) (subscriptionQueryId handle) budgetMs

export covering
unsubscribe : Client -> Subscription -> IO (Either ConvexError ())
unsubscribe client handle = unsubscribeLive (live client) (subscriptionQueryId handle)

||| Close the sync socket and drop every subscription. HTTP calls open and
||| close their own connections, so nothing else is left behind.
export covering
closeClient : Client -> IO ()
closeClient client = closeLive (live client)
