/-
The public client: Convex's documented JSON HTTP endpoints, plus the Live
engine, behind one handle.

HTTP is deliberately envelope-first. Convex reports a function failure inside a
JSON body that may arrive with a non-2xx status, so the envelope is inspected
before the status code and a body that is not an envelope is reported as
protocol drift together with the status it came with.
-/

import Convex.Http
import Convex.Live

namespace Convex

open Lean (Json)

structure CallResult where
  value : Json
  logs : Array String
  deriving Inhabited

/-- A handle to one active reactive query. -/
structure Subscription where
  id : Nat
  deriving Inhabited, BEq

structure ClientOptions where
  clientVersion : String := "lean-0.1.0"
  authToken : Option String := none
  tls : TlsOptions := {}
  httpTimeoutMs : UInt64 := 30000
  httpLimits : Http.Limits := {}
  deriving Inhabited

structure Client where
  baseUrl : String
  options : ClientOptions
  auth : IO.Ref (Option String)
  live : Live
  closed : IO.Ref Bool

namespace Client

def syncPath : String := "/api/sync"

def new (url : String) (options : ClientOptions := {}) : ConvexM Client := do
  let syncEndpoint ← liftExcept "Convex deployment URL" (parseEndpoint url syncPath)
  -- Fail fast on a URL that only the HTTP path would have rejected later.
  let _ ← liftExcept "Convex deployment URL" (parseEndpoint url "/api/query")
  let auth ← IO.mkRef options.authToken
  let live ← Live.new {
    endpoint := syncEndpoint
    tls := options.tls
    clientVersion := options.clientVersion }
  let closed ← IO.mkRef false
  pure { baseUrl := url, options, auth, live, closed }

def setAuth (client : Client) (token : String) : ConvexM Unit := do
  client.auth.set (if token.isEmpty then none else some token)

def clearAuth (client : Client) : ConvexM Unit := do
  client.auth.set none

private def bodySnippet (body : ByteArray) : String :=
  let capped := body.extract 0 (min 256 body.size)
  match Bytes.utf8Decode capped with
  | .ok text => text
  | .error _ => Bytes.toHex capped

/-- Turn one Convex HTTP envelope into a result or a structured failure. -/
private def interpret (status : Nat) (body : ByteArray) (limits : JsonLimits) :
    ConvexM CallResult := do
  match parseJsonBytes body limits with
  | .error problem =>
      throw (ConvexError.protocol
        s!"HTTP {status} response was not JSON: {problem}: {bodySnippet body}")
  | .ok value =>
      if !jsonIsObj value then
        throw (ConvexError.protocol s!"HTTP {status} response was not a JSON object")
      match jsonObjVal? value "status" >>= jsonStr? with
      | some "success" => do
          let logs ← liftExcept "response logLines" (jsonStringArray value "logLines")
          match jsonObjVal? value "value" with
          | none => throw (ConvexError.protocol "Convex success response omitted value")
          | some payload => pure { value := payload, logs }
      | some "error" => do
          let logs ← liftExcept "response logLines" (jsonStringArray value "logLines")
          match jsonObjVal? value "errorMessage" >>= jsonStr? with
          | none =>
              throw (ConvexError.protocol "Convex error response omitted a string errorMessage")
          | some message =>
              throw (ConvexError.function message (jsonObjVal? value "errorData") logs)
      | _ =>
          throw (ConvexError.protocol
            s!"HTTP {status} response was not a Convex envelope: {bodySnippet body}")

private def call (client : Client) (operation : String) (path : String) (args : Json) :
    ConvexM CallResult := do
  if ← client.closed.get then
    throw (ConvexError.closed "Convex client is closed")
  let endpoint ← liftExcept "Convex deployment URL"
    (parseEndpoint client.baseUrl s!"/api/{operation}")
  let body := renderJsonBytes
    (jsonObject
      [ ("path", Json.str path)
      , ("args", args)
      , ("format", Json.str "json") ])
  let mut headers : Array (String × String) := #[
    ("Content-Type", "application/json"),
    ("Accept", "application/json"),
    ("Convex-Client", client.options.clientVersion)]
  match ← client.auth.get with
  | none => pure ()
  | some token => headers := headers.push ("Authorization", s!"Bearer {token}")
  let deadline := (← Live.nowMs) + client.options.httpTimeoutMs
  let response ← Http.request endpoint client.options.tls "POST" headers body deadline
    client.options.httpLimits
  interpret response.status response.body { maxBytes := client.options.httpLimits.maxBodyBytes }

def query (client : Client) (path : String) (args : Json) : ConvexM CallResult :=
  call client "query" path args

def mutation (client : Client) (path : String) (args : Json) : ConvexM CallResult :=
  call client "mutation" path args

def action (client : Client) (path : String) (args : Json) : ConvexM CallResult :=
  call client "action" path args

def subscribe (client : Client) (path : String) (args : Json) : ConvexM Subscription := do
  if ← client.closed.get then
    throw (ConvexError.closed "Convex client is closed")
  let id ← Live.add client.live path args
  pure { id }

def unsubscribe (client : Client) (subscription : Subscription) : ConvexM Unit :=
  Live.remove client.live subscription.id

/-- Progress the Live loop without waiting. Callers that own their own poll --
the conformance adapter, which also watches its controller connection -- drive
the client with this plus `liveDescriptor` and `waitBudgetMs`. -/
def pump (client : Client) : ConvexM Unit := Live.pump client.live

def liveDescriptor (client : Client) : ConvexM (Option UInt32) := Live.fd client.live

def waitBudgetMs (client : Client) (limit : Nat) : ConvexM Nat :=
  Live.waitBudgetMs client.live limit

def takeUpdate (client : Client) (subscription : Subscription) : ConvexM (Option Update) :=
  Live.take client.live subscription.id

/-- Wait for the next reactive update, driving the loop while waiting.
`none` means the timeout elapsed with nothing delivered. -/
def nextUpdate (client : Client) (subscription : Subscription) (timeoutMs : Nat) :
    ConvexM (Option Update) := do
  let deadline := (← Live.nowMs) + UInt64.ofNat timeoutMs
  let mut result : Option Update := none
  let mut waiting := true
  while waiting do
    Live.pump client.live
    match ← Live.take client.live subscription.id with
    | some update =>
        result := some update
        waiting := false
    | none =>
        let now ← Live.nowMs
        if now ≥ deadline then
          waiting := false
        else
          let budget ← Live.waitBudgetMs client.live (min 250 (deadline - now).toNat)
          let descriptor ← Live.fd client.live
          let _ ← ConvexM.attempt "waiting for a Live update"
            (Ffi.poll (descriptor.getD Ffi.noDescriptor) Ffi.wantRead
              Ffi.noDescriptor Ffi.wantNothing Ffi.noDescriptor Ffi.wantNothing
              (UInt32.ofNat (max budget 1)))
  pure result

/-- Adapter-only hook, documented in `manifest.yaml`. It is not part of the
educational API surface the README teaches. -/
def debugDisconnect (client : Client) : ConvexM Nat := Live.debugDisconnect client.live

def close (client : Client) : ConvexM Unit := do
  if ← client.closed.get then
    return ()
  client.closed.set true
  Live.close client.live

end Client

end Convex
