-- | The Convex client a PureScript program uses.
-- |
-- | A client owns two things: the documented HTTP API, which is one POST per
-- | call, and exactly one Live owner for the reactive `/api/sync` connection.
-- | Creating the Live owner here rather than in `subscribe` is deliberate. A
-- | client has one query set, so it must not be able to grow a second socket
-- | by subscribing twice.
module Convex
  ( Client
  , CallKind(..)
  , CallResult
  , new
  , newWithRelayGate
  , setAuth
  , call
  , subscribe
  , unsubscribe
  , close
  , debugDisconnect
  , decodeResponse
  , clientHeader
  ) where

import Convex.Prelude
import Convex.Bytes (Bytes)
import Convex.Error (ConvexError)
import Convex.Error as Error
import Convex.Http (Header, Url)
import Convex.Http as Http
import Convex.Json (Json(..))
import Convex.Json as Json
import Convex.Live (Live)
import Convex.Live as Live
import Convex.Sys (Pid)

-- | Identifies this client to the deployment. Convex logs it, which makes a
-- | hosted verification run traceable back to this language.
clientHeader :: String
clientHeader = "purescript-0.1.0"

-- | Every HTTP call gets the same generous ceiling. Convex functions in this
-- | demonstration return in milliseconds; the bound exists so a stalled
-- | network surfaces as a `TransportError` rather than hanging an example.
httpTimeout :: Int
httpTimeout = 30000

-- | Longest bearer token this client will attach. A token is a header value,
-- | so it is length-checked and rejected outright if it contains a line break.
maxTokenBytes :: Int
maxTokenBytes = 65536

type Client =
  { origin :: String
  , url :: Url
  , token :: Maybe String
  , live :: Live
  }

-- | Which Convex entry point a call targets.
data CallKind
  = Query
  | Mutation
  | Action

-- | A successful call: the decoded return value and any log lines the function
-- | produced.
type CallResult =
  { value :: Json
  , logs :: List String
  }

-- | Connect a client to a deployment URL such as `https://example.convex.cloud`.
-- | No socket is opened yet; the Live owner connects the first time something
-- | is subscribed.
new :: String -> Effect (Either ConvexError Client)
new url = start url Nothing

-- | Test-only entry point that installs a relay pause point.
-- |
-- | The deterministic Live tests use it to hold an event after the relay has
-- | dequeued it. `new` never supplies a gate, so an ordinary client has no
-- | pause point to trip over.
newWithRelayGate :: String -> Pid -> Effect (Either ConvexError Client)
newWithRelayGate url gate = start url (Just gate)

start :: String -> Maybe Pid -> Effect (Either ConvexError Client)
start url gate = case Http.parseUrl url of
  Left reason -> pure (Left (Error.protocolError reason))
  Right parsed -> do
    live <- Live.start parsed true gate
    pure
      ( Right
          { origin: url
          , url: parsed
          , token: Nothing
          , live: live
          }
      )

-- | Attach a bearer token to later HTTP calls, or clear it with an empty
-- | string. The client value is immutable, so this returns a new client that
-- | shares the same Live owner.
setAuth :: Client -> String -> Either ConvexError Client
setAuth client token =
  if not (validHeaderValue token) then
    Left (Error.protocolError "authentication token contains a line break")
  else if stringByteLength token > maxTokenBytes then
    Left (Error.protocolError "authentication token exceeds 65536 bytes")
  else if token == "" then Right (client { token = Nothing })
  else Right (client { token = Just token })

-- | Call a Convex function over HTTP.
call
  :: Client
  -> CallKind
  -> String
  -> Json
  -> Effect (Either ConvexError CallResult)
call client kind path args = case validatePath path of
  Left problem -> pure (Left problem)
  Right _ -> do
    let
      body = Json.toBytes
        ( JsonObject
            ( Cons (Tuple "path" (JsonString path))
                ( Cons (Tuple "args" args)
                    (listSingleton (Tuple "format" (JsonString "json")))
                )
            )
        )
    outcome <- Http.request client.url "POST" ("/api/" <> endpoint kind)
      (headers client)
      body
      httpTimeout
      true
    case outcome of
      Left reason -> pure (Left (Error.transportError reason))
      Right response -> pure (decodeResponse response.status response.body)

endpoint :: CallKind -> String
endpoint kind = case kind of
  Query -> "query"
  Mutation -> "mutation"
  Action -> "action"

headers :: Client -> List Header
headers client =
  let
    base = Cons (Tuple "content-type" "application/json")
      ( Cons (Tuple "accept" "application/json")
          (listSingleton (Tuple "convex-client" clientHeader))
      )
  in
    case client.token of
      Nothing -> base
      Just token -> Cons (Tuple "authorization" ("Bearer " <> token)) base

-- | Decode the Convex response envelope.
-- |
-- | Convex always answers a well-formed call with `status`, so anything else
-- | is protocol drift and is reported as such instead of being coerced into a
-- | value. This is exported so the language-local codec test can exercise the
-- | exact decoder the client uses.
decodeResponse :: Int -> Bytes -> Either ConvexError CallResult
decodeResponse status body = case Json.parseBytes body of
  Left _ -> Left invalidResponse
  Right envelope -> case Json.stringField envelope "status", Json.logLines envelope of
    Just "success", Just logs ->
      if status < 200 || status >= 300 then
        Left
          ( Error.protocolError
              "non-success HTTP status carried a success envelope"
          )
      else case Json.field envelope "value" of
        Just value -> Right { value: value, logs: logs }
        Nothing -> Left invalidResponse
    Just "error", Just logs -> case Json.stringField envelope "errorMessage" of
      Nothing -> Left invalidResponse
      Just message -> Left
        ( Error.functionError message
            -- An absent `errorData` and an explicit null are different Convex
            -- outcomes, and the adapter has to preserve both.
            ( if Json.hasField envelope "errorData" then
                Json.field envelope "errorData"
              else Nothing
            )
            logs
        )
    _, _ -> Left invalidResponse

invalidResponse :: ConvexError
invalidResponse = Error.protocolError "invalid Convex HTTP response"

validHeaderValue :: String -> Boolean
validHeaderValue value =
  not (stringContains value "\r") && not (stringContains value "\n")

validatePath :: String -> Either ConvexError Unit
validatePath path = case stringSplitOnce path ":" of
  Just (Tuple modulePart functionPart) ->
    if
      modulePart /= "" && functionPart /= ""
        && not (stringContains functionPart ":")
        && validHeaderValue path
        && stringByteLength path <= 4096 then Right unit
    else Left pathProblem
  Nothing -> Left pathProblem

pathProblem :: ConvexError
pathProblem = Error.protocolError
  "Convex function path must be module:function within 4096 bytes"

-- | Subscribe to a query. Events arrive in `sink`'s event mailbox until the
-- | subscription is removed, including failures, so a subscriber sees a query
-- | error without losing its place.
subscribe
  :: Client -> String -> Json -> Pid -> Effect (Either ConvexError String)
subscribe client path args sink = case validatePath path of
  Left problem -> pure (Left problem)
  Right _ -> do
    accepted <- Live.subscribe client.live path args sink
    case accepted of
      Just subscriptionId -> pure (Right subscriptionId)
      Nothing -> pure
        ( Left
            (Error.transportError "Live owner did not accept the subscription")
        )

-- | Remove a subscription. Once this returns, nothing further can be delivered
-- | for it, including an event a relay had already dequeued.
unsubscribe :: Client -> String -> Effect (Either ConvexError Unit)
unsubscribe client subscriptionId = do
  acknowledged <- Live.unsubscribe client.live subscriptionId
  pure (confirm acknowledged "Live owner did not acknowledge the unsubscribe")

-- | Release the Live owner, its connection, and every relay.
close :: Client -> Effect (Either ConvexError Unit)
close client = do
  acknowledged <- Live.close client.live
  pure (confirm acknowledged "Live owner did not acknowledge the close")

-- | Adapter-only: force a reconnect. Not part of the educational API.
debugDisconnect :: Client -> Effect (Either ConvexError Unit)
debugDisconnect client = do
  acknowledged <- Live.debugDisconnect client.live
  pure (confirm acknowledged "Live owner did not acknowledge the disconnect")

confirm :: Boolean -> String -> Either ConvexError Unit
confirm acknowledged message =
  if acknowledged then Right unit else Left (Error.transportError message)
