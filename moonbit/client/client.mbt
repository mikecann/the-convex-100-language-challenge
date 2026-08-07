// The client object every Convex operation hangs off.
//
// One `Client` owns one deployment URL, at most one bearer token, and at most
// one Live WebSocket. HTTP calls are independent request/response round trips;
// Live subscriptions are multiplexed over the single socket that the Live
// worker in `live.mbt` owns exclusively.

///|
/// Identifies this client to the deployment in the `Convex-Client` header.
/// Convex uses it for server-side diagnostics only, but sending a truthful
/// value keeps the demonstration honest about what produced the traffic.
pub const CLIENT_VERSION : String = "moonbit-0.1.0"

///|
/// Largest HTTP response body this client will accept, in bytes. Convex
/// function results are small; a body larger than this is either drift or a
/// hostile peer, and reading it would let a remote server dictate our memory
/// use.
pub const HTTP_MAX_RESPONSE_BYTES : Int = 2097152

///|
/// Absolute deadline for one HTTP call, covering DNS, TCP, TLS, the request and
/// the whole response body.
const HTTP_TIMEOUT_MS : Int = 30000

///|
/// Read granularity for streaming a response or a Live message. Bodies are
/// consumed in chunks of this size so that the size check happens before the
/// bytes are retained, not after.
const READ_CHUNK_BYTES : Int = 16384

///|
/// One successful Convex function call: the returned value plus any log lines
/// the deployment produced while running it.
pub(all) struct CallResult {
  value : Json
  logs : Array[String]
}

///|
/// A handle on one Convex deployment.
///
/// Create it with `with_client`, which also starts and stops the Live worker.
/// The struct itself is deliberately small: the interesting state lives in the
/// `LiveManager`, and everything that touches the WebSocket goes through it.
pub struct Client {
  /// Normalised `http://host[:port]` or `https://host[:port]` with no path and
  /// no trailing slash. The Live socket upgrades from this same origin, so
  /// there is no second URL to keep in step.
  origin : String
  mut token : String?
  mut closed : Bool
  live : LiveManager
}

///|
/// Reject anything that is not a bare absolute http/https origin before the
/// first byte is sent.
///
/// This string is used twice: `@http.Client` takes it as the origin for every
/// function call, and the Live socket upgrades from the same value. Anything
/// beyond scheme and authority is therefore not merely redundant, it is a
/// silent redirection - a path would send calls to the wrong endpoint, a query
/// or fragment would be dropped by one transport and not the other, and
/// `user:password@host` would put a credential this client never sends in a
/// place it cannot honour. All of them are refused rather than trimmed away,
/// because trimming turns a caller's mistake into traffic they did not ask for.
fn normalise_origin(url : String) -> String raise ConvexError {
  let mut trimmed = url
  while trimmed.has_suffix("/") {
    trimmed = trimmed.substring(start=0, end=trimmed.length() - 1)
  }
  guard trimmed.has_prefix("http://") || trimmed.has_prefix("https://") else {
    raise protocol_error("Convex deployment URL must use http:// or https://")
  }
  let scheme_end = if trimmed.has_prefix("https://") { 8 } else { 7 }
  let authority = trimmed.substring(start=scheme_end)
  guard authority.length() > 0 else {
    raise protocol_error("Convex deployment URL must name a host")
  }
  // A backslash is rejected alongside the forward slash because several URL
  // parsers treat the two as interchangeable, so accepting one would leave the
  // path check depending on whose parser saw the string next.
  guard !authority.contains("/") && !authority.contains("\\") else {
    raise protocol_error(
      "Convex deployment URL must be an origin without a path",
    )
  }
  guard !authority.contains("?") else {
    raise protocol_error(
      "Convex deployment URL must be an origin without a query string",
    )
  }
  guard !authority.contains("#") else {
    raise protocol_error(
      "Convex deployment URL must be an origin without a fragment",
    )
  }
  // Convex authenticates function calls with a bearer token supplied through
  // `set_auth`. A URL credential would be discarded here, so accepting one
  // would look like authentication that never happened.
  guard !authority.contains("@") else {
    raise protocol_error(
      "Convex deployment URL must not carry userinfo; use set_auth instead",
    )
  }
  guard !authority.contains(" ") else {
    raise protocol_error("Convex deployment URL host must not contain spaces")
  }
  trimmed
}

///|
/// Run `body` with a connected client and shut it down afterwards.
///
/// The Live worker is a background task inside this function's task group, so
/// it cannot outlive the body: structured concurrency guarantees that when
/// `with_client` returns, no task is still holding a socket. `close` runs on
/// both the success and the failure path so a failing example still retires its
/// WebSocket instead of leaking it into the group's cancellation.
///
/// `body` is allowed to fail and so is this function: `normalise_origin` refuses
/// a URL that is not an origin before any task is started, and a failure raised
/// inside `body` is re-raised to the caller after the client has been closed.
pub async fn[X] with_client(url : String, body : async (Client) -> X) -> X {
  let origin = normalise_origin(url)
  let client = Client::{
    origin,
    token: None,
    closed: false,
    live: LiveManager::new(),
  }
  @async.with_task_group(group => {
    client.live.client = Some(client)
    // `no_wait` lets the group finish as soon as `body` is done: the worker
    // loops forever by design and would otherwise keep the group alive.
    group.spawn_bg(() => client.live.run(), no_wait=true)
    let result = body(client) catch {
      error => {
        client.close()
        raise error
      }
    }
    client.close()
    result
  })
}

///|
/// Attach a bearer token to every later HTTP call, or clear it with `None`.
///
/// Convex validates the token when the function runs, so a bad token surfaces
/// as a failed call rather than an error here. Passing an empty string clears
/// the token, which is what the shared conformance suite uses to prove that a
/// replaced credential really is forgotten.
pub fn Client::set_auth(self : Client, token : String?) -> Unit {
  self.token = match token {
    Some(value) => if value.length() == 0 { None } else { Some(value) }
    None => None
  }
}

///|
/// Run a Convex query over HTTP and wait for its result.
pub async fn Client::query(
  self : Client,
  path : String,
  args : Json,
) -> CallResult {
  self.call("query", path, args)
}

///|
/// Run a Convex mutation over HTTP.
///
/// Convex mutations are transactional but not automatically idempotent, so the
/// shared demo takes a caller supplied `runId` in `args` and refuses to apply
/// the same one twice. The canonical example passes a fresh UUID.
pub async fn Client::mutation(
  self : Client,
  path : String,
  args : Json,
) -> CallResult {
  self.call("mutation", path, args)
}

///|
/// Run a Convex action over HTTP. Actions may call out to the network, so they
/// are not transactional and must not be retried blindly.
pub async fn Client::action(
  self : Client,
  path : String,
  args : Json,
) -> CallResult {
  self.call("action", path, args)
}

///|
/// Start a Live subscription for `path`/`args`.
///
/// The call hands an `Add` command to the Live worker and waits for the worker
/// to acknowledge it, so a returned `Subscription` is always one the worker has
/// taken ownership of. Values arrive through `Subscription::next`.
pub async fn Client::subscribe(
  self : Client,
  path : String,
  args : Json,
) -> Subscription {
  guard !self.closed else { raise closed_error("client is closed") }
  guard args is Object(_) else {
    raise protocol_error("Live query arguments must be a JSON object")
  }
  self.live.add(path, args)
}

///|
/// Retire a Live subscription.
///
/// This returns only after the worker has invalidated the subscription, so a
/// caller that unsubscribes and then observes no further updates is observing a
/// guarantee rather than a race.
pub async fn Client::unsubscribe(
  self : Client,
  subscription : Subscription,
) -> Unit {
  self.live.remove(subscription)
}

///|
/// Close the client: retire every subscription, close the Live socket, and
/// refuse later work.
///
/// Bounded on both sides. The worker's own writes are capped by
/// `LIVE_WRITE_TIMEOUT_MS` and the caller's wait is capped by
/// `LIVE_COMMAND_TIMEOUT_MS`, so neither a silent peer nor a wedged worker can
/// make shutdown hang.
pub async fn Client::close(self : Client) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  self.live.shutdown()
}
