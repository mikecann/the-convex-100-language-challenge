// The public educational client: configuration, the three HTTP operations,
// Live subscriptions, and shutdown. Everything below delegates to a module
// that owns exactly one concern, so a reader can follow one thing at a time.

type options = {
  // Sent as the `Convex-Client` header on both transports so a deployment's
  // logs can tell this experiment apart from an official SDK.
  clientVersion: string,
  // An opaque bearer token. Empty means "no identity".
  authToken: string,
  transport: ConvexLive.transport,
}

let version = "rescript-0.1.0"

let defaultOptions = {
  clientVersion: version,
  authToken: "",
  transport: ConvexLive.websocketTransport,
}

let containsHeaderBreak = value =>
  Js.String2.includes(value, "\r") || Js.String2.includes(value, "\n")

let validateHeaders = (clientVersion, authToken) => {
  if containsHeaderBreak(clientVersion) || containsHeaderBreak(authToken) {
    ConvexError.raiseError(ConvexError.usage("client headers must not contain line breaks"))
  } else if ConvexNode.utf8ByteLength(clientVersion) > 1024 {
    ConvexError.raiseError(ConvexError.usage("client version header is too large"))
  } else if ConvexNode.utf8ByteLength(authToken) > 64 * 1024 {
    ConvexError.raiseError(ConvexError.usage("auth token is too large"))
  }
}

type t = {
  deploymentUrl: string,
  clientVersion: string,
  mutable authToken: string,
  mutable closed: bool,
  // Live networking is started by the first subscription, so an HTTP-only
  // program never opens a WebSocket.
  mutable live: option<ConvexLive.manager>,
  transport: ConvexLive.transport,
}

// `options` and `t` share field names (`clientVersion`, `transport`), and
// without an explicit annotation the compiler resolves each unqualified
// field access to whichever record type was declared most recently --
// silently inferring this parameter as `t` instead of `options`.
let makeWithOptions = (deploymentUrl: string, options: options): t => {
  validateHeaders(options.clientVersion, options.authToken)
  switch ConvexProtocol.normalizeDeploymentUrl(deploymentUrl) {
  | Error(message) => ConvexError.raiseError(ConvexError.usage(message))
  | Ok(normalized) => {
      deploymentUrl: normalized,
      clientVersion: options.clientVersion,
      authToken: options.authToken,
      closed: false,
      live: None,
      transport: options.transport,
    }
  }
}

let make = deploymentUrl => makeWithOptions(deploymentUrl, defaultOptions)

let deploymentUrl = client => client.deploymentUrl

// Replaces the bearer token for later calls. Passing "" clears it, which is
// how the conformance suite exercises absent, invalid, replaced, and cleared
// tokens against the deployment.
let setAuth = (client, token) =>
  if client.closed {
    ConvexError.raiseError(ConvexError.closed())
  } else {
    validateHeaders(client.clientVersion, token)
    client.authToken = token
  }

let call = (client, operation, path, args) =>
  if client.closed {
    ConvexError.raiseError(ConvexError.closed())
  } else {
    ConvexHttp.call(
      ~deploymentUrl=client.deploymentUrl,
      ~clientVersion=client.clientVersion,
      ~authToken=client.authToken,
      ~operation,
      ~path,
      ~args,
    )
  }

let query = (client, path, args) => call(client, ConvexHttp.Query, path, args)
let mutation = (client, path, args) => call(client, ConvexHttp.Mutation, path, args)
let action = (client, path, args) => call(client, ConvexHttp.Action, path, args)

let liveManager = client =>
  switch client.live {
  | Some(manager) => manager
  | None => {
      let manager = ConvexLive.make(
        ~deploymentUrl=client.deploymentUrl,
        ~clientVersion=client.clientVersion,
        ~transport=client.transport,
      )
      client.live = Some(manager)
      manager
    }
  }

// Starts a reactive query. Read values with `ConvexLive.next` and stop with
// `ConvexLive.closeSubscription`.
let subscribe = (client, path, args) =>
  if client.closed {
    ConvexError.raiseError(ConvexError.closed())
  } else {
    ConvexLive.subscribe(liveManager(client), path, args)
  }

let close = async client =>
  if !client.closed {
    client.closed = true
    switch client.live {
    | Some(manager) => await ConvexLive.close(manager)
    | None => ()
    }
  }
